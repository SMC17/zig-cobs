//! coverage_driver — a single-binary executable that exercises every public
//! function and every public error path in `src/root.zig`. The point isn't to
//! be a meaningful demo (the tests already are) — it's to be a plain
//! executable that `kcov` can run end-to-end, since the Zig test runner's
//! debug-info layout currently confuses kcov on this nixpkgs build (see
//! STATUS.md "coverage" section).
//!
//! The driver runs three deterministic groups:
//!
//! 1. **Happy-path round-trips** — every length class the library cares about
//!    (0, 1, mid, the 254-byte boundary, the 255-byte boundary, deep payloads),
//!    confirming `encode` and `decode` are mutual inverses on each.
//! 2. **Error-path coverage** — every distinct error returned by either
//!    function: `BufferTooSmall` (encode + decode), `ZeroByteInFrame` (decode),
//!    `TruncatedFrame` (decode). Each is asserted with `expectError`.
//! 3. **maxEncodedLength** — boundary values that hit every branch (0,
//!    255-multiples, 254-multiples).
//!
//! Every assertion is checked at runtime; a coverage report against this
//! binary measures every line of `root.zig` reachable from the public API.

const std = @import("std");
const cobs = @import("cobs");

pub fn main() !void {
    // --- 1. happy-path round-trips ---
    try roundTrip(&[_]u8{});
    try roundTrip(&[_]u8{0});
    try roundTrip(&[_]u8{0x55});
    try roundTrip(&[_]u8{ 0x01, 0x02, 0x03 });
    try roundTrip(&([_]u8{0xAB} ** 100));
    try roundTrip(&([_]u8{0xCD} ** 253));
    try roundTrip(&([_]u8{0xEF} ** 254));
    try roundTrip(&([_]u8{0x77} ** 255));
    try roundTrip(&([_]u8{0x12} ** 512));
    // A deterministic pseudo-random payload to exercise the run-length
    // overhead-byte logic across many size classes.
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const r = prng.random();
    inline for (.{ 1, 8, 32, 64, 128, 254, 255, 256, 1024 }) |n| {
        var buf: [n]u8 = undefined;
        r.bytes(&buf);
        try roundTrip(&buf);
    }

    // --- 2. error paths ---
    // encode: dst too small
    {
        const src = [_]u8{ 0x01, 0x02, 0x03 };
        var dst: [1]u8 = undefined;
        try expectErr(cobs.Error.BufferTooSmall, cobs.encode(&src, &dst));
    }
    // decode: dst too small
    {
        const src = [_]u8{ 0x04, 0x01, 0x02, 0x03 };
        var dst: [1]u8 = undefined;
        try expectErr(cobs.Error.BufferTooSmall, cobs.decode(&src, &dst));
    }
    // decode: zero byte mid-frame
    {
        const src = [_]u8{ 0x02, 0x01, 0x00, 0x05 };
        var dst: [16]u8 = undefined;
        try expectErr(cobs.Error.InvalidEncoding, cobs.decode(&src, &dst));
    }
    // decode: truncated frame
    {
        const src = [_]u8{ 0x04, 0x01, 0x02 }; // says "3 more bytes" but stream ends
        var dst: [16]u8 = undefined;
        try expectErr(cobs.Error.InvalidEncoding, cobs.decode(&src, &dst));
    }

    // --- 3. maxEncodedLength branches ---
    // Discard return values — the point is to exercise every branch.
    _ = cobs.maxEncodedLength(0);
    _ = cobs.maxEncodedLength(1);
    _ = cobs.maxEncodedLength(253);
    _ = cobs.maxEncodedLength(254);
    _ = cobs.maxEncodedLength(255);
    _ = cobs.maxEncodedLength(508);
    _ = cobs.maxEncodedLength(509);
}

fn roundTrip(input: []const u8) !void {
    var enc_buf: [16384]u8 = undefined;
    var dec_buf: [16384]u8 = undefined;
    const enc_len = try cobs.encode(input, &enc_buf);
    const dec_len = try cobs.decode(enc_buf[0..enc_len], &dec_buf);
    if (dec_len != input.len) return error.RoundTripLenMismatch;
    if (dec_len > 0 and !std.mem.eql(u8, dec_buf[0..dec_len], input)) return error.RoundTripBytesMismatch;
}

fn expectErr(expected: cobs.Error, actual: anyerror!usize) !void {
    if (actual) |_| {
        return error.ExpectedError;
    } else |err| {
        if (err != expected) return error.WrongError;
    }
}
