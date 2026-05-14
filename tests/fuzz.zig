//! Fuzz harness for zig-cobs.
//!
//! Three properties we want to hold against arbitrary byte sequences:
//!
//!  1. **Round-trip invariance.** For every input `x`, decode(encode(x)) == x.
//!  2. **Encoded-output zero-freeness.** encode never produces a zero byte
//!     in its output — this is the whole point of COBS, and a violation
//!     means downstream frame-delimiter logic is broken.
//!  3. **Decoder soundness.** decode either succeeds with a valid payload
//!     OR returns Error.InvalidEncoding / BufferTooSmall. It MUST NOT panic,
//!     MUST NOT read past `src.len`, and MUST NOT write past `dst.len`. We
//!     verify the no-panic property by simply not crashing across N trials.
//!
//! Two fuzz modes:
//!
//!   - `zig build fuzz` — runs FUZZ_TRIAL_COUNT (default 100_000) round-trip
//!     trials against a deterministic PRNG, plus FUZZ_ADVERSARIAL_COUNT
//!     (default 5_000) decoder-only trials against random adversarial bytes
//!     (no encode step — we feed garbage straight into decode and assert it
//!     either succeeds or returns InvalidEncoding cleanly).
//!   - `zig test` directly on this file runs the same trials in a single
//!     test, useful for CI gating.
//!
//! Boundary sizes specifically exercised:
//!
//!   - 0 bytes (empty input)
//!   - 1 byte (smallest non-trivial)
//!   - 253, 254, 255 bytes (the overhead-byte injection boundary)
//!   - 254 * N bytes for N = 1, 2, 3 (multiple injections)
//!   - 4096 bytes (typical "large" message)

const std = @import("std");
const cobs = @import("cobs");

const FUZZ_TRIAL_COUNT: usize = 100_000;
const FUZZ_ADVERSARIAL_COUNT: usize = 5_000;
const MAX_INPUT_SIZE: usize = 4096;

/// Boundary sizes that are known to exercise codepaths the random PRNG would
/// hit only with low probability. Each is fuzz'd FUZZ_BOUNDARY_REPS times.
const BOUNDARY_SIZES = [_]usize{ 0, 1, 2, 253, 254, 255, 256, 508, 509, 510, 762, 4096 };
const FUZZ_BOUNDARY_REPS: usize = 1_000;

fn roundTrip(allocator: std.mem.Allocator, prng: *std.Random.Xoshiro256, input_size: usize) !void {
    const src = try allocator.alloc(u8, input_size);
    defer allocator.free(src);
    prng.fill(src);

    const encoded_cap = cobs.maxEncodedLength(input_size);
    const encoded = try allocator.alloc(u8, encoded_cap);
    defer allocator.free(encoded);

    const enc_n = try cobs.encode(src, encoded);

    // Property 2: encoded output contains no zero byte.
    for (encoded[0..enc_n]) |byte| {
        if (byte == 0) {
            std.debug.print("\nFUZZ FAIL: encode produced zero byte at output of {d}-byte input\n", .{input_size});
            return error.EncodedContainsZero;
        }
    }

    const decoded = try allocator.alloc(u8, input_size + 1); // +1 to also catch over-writes
    defer allocator.free(decoded);
    const dec_n = try cobs.decode(encoded[0..enc_n], decoded);

    // Property 1: round-trip invariance.
    if (dec_n != input_size) {
        std.debug.print("\nFUZZ FAIL: decode length {d} != input length {d}\n", .{ dec_n, input_size });
        return error.RoundTripLengthMismatch;
    }
    if (!std.mem.eql(u8, decoded[0..dec_n], src)) {
        std.debug.print("\nFUZZ FAIL: decode contents != input ({d} bytes)\n", .{input_size});
        return error.RoundTripContentsMismatch;
    }
}

fn adversarial(allocator: std.mem.Allocator, prng: *std.Random.Xoshiro256) !void {
    // Pick a random size and fill with random bytes. Don't encode — feed the
    // raw garbage to decode and verify it either succeeds or returns a
    // clean InvalidEncoding / BufferTooSmall.
    const random = prng.random();
    const size = random.intRangeAtMost(usize, 0, 512);
    const src = try allocator.alloc(u8, size);
    defer allocator.free(src);
    prng.fill(src);

    const dst = try allocator.alloc(u8, size + 1);
    defer allocator.free(dst);

    const result = cobs.decode(src, dst);
    if (result) |dec_n| {
        // Decoder succeeded on random bytes — that's fine and not unusual,
        // it just means the random bytes happened to be a valid frame. The
        // important property is that the call neither panic'd nor produced
        // an oversized write.
        if (dec_n > src.len) {
            std.debug.print("\nFUZZ FAIL: decode wrote {d} bytes from {d}-byte input (overflow)\n", .{ dec_n, src.len });
            return error.DecodeOverflow;
        }
    } else |err| switch (err) {
        cobs.Error.InvalidEncoding, cobs.Error.BufferTooSmall => {},
        // No other error variants exist; any unexpected error type would be
        // a contract violation. Adding an `else =>` arm would let it through.
    }
}

pub fn run_fuzz(seed: u64) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var prng = std.Random.Xoshiro256.init(seed);
    const random = prng.random();

    std.debug.print("zig-cobs fuzz harness — seed={d}\n", .{seed});

    // Boundary trials
    var boundary_done: usize = 0;
    for (BOUNDARY_SIZES) |size| {
        var rep: usize = 0;
        while (rep < FUZZ_BOUNDARY_REPS) : (rep += 1) {
            try roundTrip(allocator, &prng, size);
            boundary_done += 1;
        }
    }
    std.debug.print("  boundary trials: {d} pass\n", .{boundary_done});

    // Random-size round-trip trials
    var rt_done: usize = 0;
    while (rt_done < FUZZ_TRIAL_COUNT) : (rt_done += 1) {
        const size = random.intRangeAtMost(usize, 0, MAX_INPUT_SIZE);
        try roundTrip(allocator, &prng, size);
    }
    std.debug.print("  random round-trip trials: {d} pass\n", .{rt_done});

    // Adversarial-input decoder trials
    var adv_done: usize = 0;
    while (adv_done < FUZZ_ADVERSARIAL_COUNT) : (adv_done += 1) {
        try adversarial(allocator, &prng);
    }
    std.debug.print("  adversarial decoder trials: {d} pass (decoder did not panic / overflow on random bytes)\n", .{adv_done});

    const total = boundary_done + rt_done + adv_done;
    std.debug.print("\nzig-cobs fuzz: {d} trials, all properties hold\n", .{total});
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Seed from CLI arg if provided, else fall back to a deterministic
    // baseline. Print the seed so failures are reproducible.
    var seed: u64 = 0xC0B55EED;

    var args = init.args.iterate();
    _ = args.next(); // skip argv[0]
    if (args.next()) |arg| {
        seed = std.fmt.parseInt(u64, arg, 10) catch seed;
    }

    try run_fuzz(seed);
}

test "fuzz harness — small trial count" {
    // CI-friendly test: run a smaller trial count so `zig build test` stays
    // fast. The full harness with FUZZ_TRIAL_COUNT runs via `zig build fuzz`.
    var prng = std.Random.Xoshiro256.init(0xC0B55EED);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 100 trials at each boundary size + 1000 random + 200 adversarial.
    for (BOUNDARY_SIZES) |size| {
        var rep: usize = 0;
        while (rep < 100) : (rep += 1) try roundTrip(allocator, &prng, size);
    }
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const size = prng.random().intRangeAtMost(usize, 0, 4096);
        try roundTrip(allocator, &prng, size);
    }
    var j: usize = 0;
    while (j < 200) : (j += 1) try adversarial(allocator, &prng);
}
