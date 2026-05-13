//! Worst-case-overhead benchmark for zig-cobs.
//!
//! COBS injects a fresh overhead byte after every 254 consecutive non-zero
//! bytes. The 254-byte all-non-zero input is the canonical input that hits
//! that boundary on every run — exactly the pattern that would expose any
//! cliff in the overhead-byte refresh path.
//!
//! We benchmark both encode and decode on this fixed 254-byte buffer. If the
//! numbers track the random-payload 256-byte row in `bench_encode` /
//! `bench_decode` then the overhead-byte path has no pathological behaviour.
//!
//! Timing: see `bench_encode.zig` for the `std.os.linux.clock_gettime`
//! rationale.

const std = @import("std");
const cobs = @import("cobs");

inline fn nanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

const worst_size: usize = 254;
const warmup_iters: usize = 1_000;
const iters: usize = 2_000_000;

pub fn main() !void {
    // The canonical worst-case content: 254 bytes, none zero. This forces COBS
    // to emit the 0xFF overhead byte that marks "the next 254 bytes are all
    // non-zero." Add 1 byte more (255 total) and you get a second overhead
    // byte injected at offset 255; benchmarking the 254 case isolates the
    // boundary itself.
    var src: [worst_size]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i % 254) + 1);

    var enc_buf: [cobs.maxEncodedLength(worst_size)]u8 = undefined;
    var dec_buf: [worst_size]u8 = undefined;

    std.debug.print("# zig-cobs bench: worst-case 254 non-zero (ReleaseFast, MONOTONIC ns)\n", .{});

    // ---- encode ----
    {
        var w: usize = 0;
        while (w < warmup_iters) : (w += 1) {
            const n = try cobs.encode(&src, &enc_buf);
            std.mem.doNotOptimizeAway(n);
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const n = try cobs.encode(&src, &enc_buf);
            std.mem.doNotOptimizeAway(n);
        }
        const total_ns = nanos() - t0;

        const ns_per_op = total_ns / iters;
        const total_bytes: u128 = @as(u128, worst_size) * @as(u128, iters);
        const mbps: u128 = (total_bytes * 1000) / @max(@as(u128, total_ns), 1);

        std.debug.print(
            "bench=worst_case_encode size=254B bytes={d} op=ENCODE iters={d} total_ns={d} ns_per_op={d} MBps={d}\n",
            .{ worst_size, iters, total_ns, ns_per_op, mbps },
        );
    }

    // ---- decode ----
    {
        const enc_len = try cobs.encode(&src, &enc_buf);
        const encoded = enc_buf[0..enc_len];

        var w: usize = 0;
        while (w < warmup_iters) : (w += 1) {
            const n = try cobs.decode(encoded, &dec_buf);
            std.mem.doNotOptimizeAway(n);
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const n = try cobs.decode(encoded, &dec_buf);
            std.mem.doNotOptimizeAway(n);
        }
        const total_ns = nanos() - t0;

        const ns_per_op = total_ns / iters;
        const total_bytes: u128 = @as(u128, worst_size) * @as(u128, iters);
        const mbps: u128 = (total_bytes * 1000) / @max(@as(u128, total_ns), 1);

        std.debug.print(
            "bench=worst_case_decode size=254B bytes={d} op=DECODE iters={d} total_ns={d} ns_per_op={d} MBps={d}\n",
            .{ worst_size, iters, total_ns, ns_per_op, mbps },
        );
    }
}
