//! Decode-throughput benchmark for zig-cobs.
//!
//! Measures `cobs.decode` throughput at four input sizes (16 B / 256 B / 1 KiB
//! / 64 KiB). Payloads are pre-encoded once with `cobs.encode` outside the
//! measurement window, then decoded in a tight loop.
//!
//! Throughput numbers reference *decoded payload bytes per second* (matching
//! the encode benchmark) so the two are directly comparable.
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

const Size = struct {
    label: []const u8,
    bytes: usize,
    iters: usize,
};

const sizes = [_]Size{
    .{ .label = "16B", .bytes = 16, .iters = 5_000_000 },
    .{ .label = "256B", .bytes = 256, .iters = 1_000_000 },
    .{ .label = "1KiB", .bytes = 1024, .iters = 500_000 },
    .{ .label = "64KiB", .bytes = 64 * 1024, .iters = 20_000 },
};

const warmup_iters: usize = 1_000;
const max_size: usize = 64 * 1024;

pub fn main() !void {
    var src_buf: [max_size]u8 = undefined;
    var enc_buf: [cobs.maxEncodedLength(max_size)]u8 = undefined;
    var dec_buf: [max_size]u8 = undefined;

    var rng = std.Random.DefaultPrng.init(0xC0B5_BE17);
    rng.random().bytes(&src_buf);

    std.debug.print("# zig-cobs bench: decode (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        const src = src_buf[0..s.bytes];

        // Pre-encode once — decode operates on this fixed input.
        const enc_len = try cobs.encode(src, &enc_buf);
        const encoded = enc_buf[0..enc_len];

        // Warm-up — discarded.
        var w: usize = 0;
        while (w < warmup_iters) : (w += 1) {
            const n = try cobs.decode(encoded, &dec_buf);
            std.mem.doNotOptimizeAway(n);
        }

        // Measurement.
        const t0 = nanos();
        var i: usize = 0;
        while (i < s.iters) : (i += 1) {
            const n = try cobs.decode(encoded, &dec_buf);
            std.mem.doNotOptimizeAway(n);
        }
        const total_ns = nanos() - t0;

        const ns_per_op = total_ns / s.iters;
        const total_bytes: u128 = @as(u128, s.bytes) * @as(u128, s.iters);
        const mbps: u128 = (total_bytes * 1000) / @max(@as(u128, total_ns), 1);

        std.debug.print(
            "bench=decode size={s} bytes={d} op=DECODE iters={d} total_ns={d} ns_per_op={d} MBps={d}\n",
            .{ s.label, s.bytes, s.iters, total_ns, ns_per_op, mbps },
        );
    }
}
