//! Encode-throughput benchmark for zig-cobs.
//!
//! Measures `cobs.encode` throughput at four input sizes (16 B / 256 B / 1 KiB
//! / 64 KiB) using pseudo-random payloads. Each size runs a 1 000-iter warm-up
//! that is discarded, followed by a measurement loop scaled by size so total
//! measurement time is roughly one second per row.
//!
//! Timing strategy: `std.time.Timer` and `std.time.nanoTimestamp` were removed
//! in Zig 0.16's stdlib reshuffle. We call
//! `std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly — this is the same
//! pattern Zig 0.16 itself uses internally (see std/os/linux.zig). Resolution
//! is nanosecond; cost on x86_64 Linux is a single VDSO call (no syscall).
//!
//! Output is parseable: one line per row, fields are `key=value` whitespace-
//! separated. Numbers reported are `ns_per_op` (total / iters) and `MBps`
//! (bytes * 1000 / ns).

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
    var dst_buf: [cobs.maxEncodedLength(max_size)]u8 = undefined;

    // Deterministic pseudo-random payload (~99.6 % non-zero bytes on average,
    // so a representative mix of overhead-byte refresh vs straight-through
    // copy cost).
    var rng = std.Random.DefaultPrng.init(0xC0B5_BE17);
    rng.random().bytes(&src_buf);

    std.debug.print("# zig-cobs bench: encode (ReleaseFast, MONOTONIC ns)\n", .{});

    for (sizes) |s| {
        const src = src_buf[0..s.bytes];

        // Warm-up — discarded.
        var w: usize = 0;
        while (w < warmup_iters) : (w += 1) {
            const n = try cobs.encode(src, &dst_buf);
            std.mem.doNotOptimizeAway(n);
        }

        // Measurement.
        const t0 = nanos();
        var i: usize = 0;
        while (i < s.iters) : (i += 1) {
            const n = try cobs.encode(src, &dst_buf);
            std.mem.doNotOptimizeAway(n);
        }
        const total_ns = nanos() - t0;

        const ns_per_op = total_ns / s.iters;
        const total_bytes: u128 = @as(u128, s.bytes) * @as(u128, s.iters);
        const mbps: u128 = (total_bytes * 1000) / @max(@as(u128, total_ns), 1);

        std.debug.print(
            "bench=encode size={s} bytes={d} op=ENCODE iters={d} total_ns={d} ns_per_op={d} MBps={d}\n",
            .{ s.label, s.bytes, s.iters, total_ns, ns_per_op, mbps },
        );
    }
}
