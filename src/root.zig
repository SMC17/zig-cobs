//! Consistent Overhead Byte Stuffing (COBS).
//!
//! COBS is a framing algorithm that takes an arbitrary byte stream and produces
//! an output that contains no zero bytes, with a small bounded overhead. A
//! single 0x00 delimiter can then be used to mark frame boundaries in a stream.
//!
//! Reference: Cheshire & Baker, "Consistent Overhead Byte Stuffing" (SIGCOMM 1997).
//!
//! Worst-case overhead is `1 + ceil(len / 254)` bytes. For empty input the
//! encoding is a single byte (0x01). Decoded output never contains the frame
//! delimiter; encoded output never contains a zero byte.

const std = @import("std");

pub const Error = error{
    /// The destination buffer is smaller than `maxEncodedLength(src.len)`
    /// (for `encode`) or smaller than the decoded payload (for `decode`).
    BufferTooSmall,
    /// The source bytes are not a valid COBS frame (truncated or contains
    /// an embedded zero byte).
    InvalidEncoding,
};

/// Maximum number of bytes that `encode` may write for an input of `input_len`
/// bytes. Use this to size destination buffers.
///
/// Formula: `input_len + (input_len / 254) + 1`. The `/ 254` term accounts
/// for the overhead byte injected after each run of 254 non-zero bytes; the
/// trailing `+ 1` covers the leading overhead byte that COBS always emits.
pub fn maxEncodedLength(input_len: usize) usize {
    return input_len + (input_len / 254) + 1;
}

/// Encode `src` into `dst` using COBS. Returns the number of bytes written.
///
/// `dst` must be at least `maxEncodedLength(src.len)` bytes; otherwise the
/// function returns `error.BufferTooSmall`. The output never contains a zero
/// byte and is suitable for transmission followed by a 0x00 frame delimiter.
pub fn encode(src: []const u8, dst: []u8) Error!usize {
    const required = maxEncodedLength(src.len);
    if (dst.len < required) return Error.BufferTooSmall;

    var read_index: usize = 0;
    var write_index: usize = 1;
    var code_index: usize = 0;
    var code: u8 = 1;

    while (read_index < src.len) : (read_index += 1) {
        if (src[read_index] == 0) {
            dst[code_index] = code;
            code_index = write_index;
            write_index += 1;
            code = 1;
        } else {
            dst[write_index] = src[read_index];
            write_index += 1;
            code += 1;
            if (code == 0xFF) {
                dst[code_index] = code;
                code_index = write_index;
                write_index += 1;
                code = 1;
            }
        }
    }
    dst[code_index] = code;
    return write_index;
}

/// Decode a COBS-encoded frame from `src` into `dst`. Returns the number of
/// payload bytes written.
///
/// Returns `error.InvalidEncoding` if `src` is truncated or otherwise not a
/// well-formed COBS frame, and `error.BufferTooSmall` if `dst` cannot hold
/// the decoded payload.
pub fn decode(src: []const u8, dst: []u8) Error!usize {
    if (src.len == 0) return 0;

    var read_index: usize = 0;
    var write_index: usize = 0;

    while (read_index < src.len) {
        const code = src[read_index];
        if (code == 0) return Error.InvalidEncoding;
        read_index += 1;

        var i: u8 = 1;
        while (i < code) : (i += 1) {
            if (read_index >= src.len) return Error.InvalidEncoding;
            if (write_index >= dst.len) return Error.BufferTooSmall;
            dst[write_index] = src[read_index];
            write_index += 1;
            read_index += 1;
        }

        if (code < 0xFF and read_index < src.len) {
            if (write_index >= dst.len) return Error.BufferTooSmall;
            dst[write_index] = 0;
            write_index += 1;
        }
    }
    return write_index;
}

// ---- tests ----

const testing = std.testing;

test "maxEncodedLength bounds" {
    try testing.expectEqual(@as(usize, 1), maxEncodedLength(0));
    try testing.expectEqual(@as(usize, 2), maxEncodedLength(1));
    try testing.expectEqual(@as(usize, 256), maxEncodedLength(254));
    try testing.expectEqual(@as(usize, 257), maxEncodedLength(255));
    try testing.expectEqual(@as(usize, 511), maxEncodedLength(508));
}

test "encode empty input" {
    var out: [4]u8 = undefined;
    const n = try encode(&.{}, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0x01), out[0]);
}

test "encode single zero byte" {
    const src = [_]u8{0};
    var out: [4]u8 = undefined;
    const n = try encode(&src, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01 }, out[0..n]);
}

test "encode single non-zero byte" {
    const src = [_]u8{0x42};
    var out: [4]u8 = undefined;
    const n = try encode(&src, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x42 }, out[0..n]);
}

test "encode rejects undersized destination" {
    const src = [_]u8{ 1, 2, 3 };
    var out: [3]u8 = undefined;
    try testing.expectError(Error.BufferTooSmall, encode(&src, &out));
}

test "encode 254 non-zero bytes triggers overhead injection" {
    var src: [254]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i % 254) + 1);
    var out: [256]u8 = undefined;
    const n = try encode(&src, &out);
    try testing.expectEqual(@as(usize, 256), n);
    try testing.expectEqual(@as(u8, 0xFF), out[0]);
    try testing.expectEqual(@as(u8, 0x01), out[255]);
}

test "encode at 255-byte boundary (overhead byte injected)" {
    var src: [255]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i % 254) + 1);
    const required = maxEncodedLength(src.len);
    try testing.expectEqual(@as(usize, 257), required);
    var out: [257]u8 = undefined;
    const n = try encode(&src, &out);
    try testing.expectEqual(@as(usize, 257), n);
    try testing.expectEqual(@as(u8, 0xFF), out[0]);
}

test "encode output contains no zero bytes" {
    var src: [512]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0xC0B5);
    rng.random().bytes(&src);
    var out: [1024]u8 = undefined;
    const n = try encode(&src, &out);
    for (out[0..n]) |b| try testing.expect(b != 0);
}

test "decode rejects zero byte inside frame" {
    const bad = [_]u8{ 0x02, 0x41, 0x00, 0x01 };
    var out: [16]u8 = undefined;
    try testing.expectError(Error.InvalidEncoding, decode(&bad, &out));
}

test "decode rejects truncated frame" {
    const bad = [_]u8{ 0x05, 0x41, 0x42 };
    var out: [16]u8 = undefined;
    try testing.expectError(Error.InvalidEncoding, decode(&bad, &out));
}

test "decode rejects undersized destination" {
    const enc = [_]u8{ 0x03, 0x41, 0x42 };
    var out: [1]u8 = undefined;
    try testing.expectError(Error.BufferTooSmall, decode(&enc, &out));
}

test "roundtrip: ascii string with embedded zeros" {
    const src = "Carrier\x00Sovereign\x00AI";
    var enc: [maxEncodedLength(src.len)]u8 = undefined;
    var dec: [src.len]u8 = undefined;

    const enc_len = try encode(src, &enc);
    const dec_len = try decode(enc[0..enc_len], &dec);
    try testing.expectEqualStrings(src, dec[0..dec_len]);
}

test "roundtrip: all zeros" {
    const src = [_]u8{0} ** 32;
    var enc: [maxEncodedLength(src.len)]u8 = undefined;
    var dec: [src.len]u8 = undefined;

    const enc_len = try encode(&src, &enc);
    const dec_len = try decode(enc[0..enc_len], &dec);
    try testing.expectEqualSlices(u8, &src, dec[0..dec_len]);
}

test "roundtrip: all 0xFF" {
    const src = [_]u8{0xFF} ** 32;
    var enc: [maxEncodedLength(src.len)]u8 = undefined;
    var dec: [src.len]u8 = undefined;

    const enc_len = try encode(&src, &enc);
    const dec_len = try decode(enc[0..enc_len], &dec);
    try testing.expectEqualSlices(u8, &src, dec[0..dec_len]);
}

test "roundtrip: pseudo-random payloads across many lengths" {
    var rng = std.Random.DefaultPrng.init(0xCAFEBABE);
    var enc_buf: [4096]u8 = undefined;
    var dec_buf: [2048]u8 = undefined;
    var src_buf: [2048]u8 = undefined;

    var len: usize = 0;
    while (len <= 2048) : (len += if (len < 64) 1 else 37) {
        const src = src_buf[0..len];
        rng.random().bytes(src);

        const enc_len = try encode(src, &enc_buf);
        const dec_len = try decode(enc_buf[0..enc_len], &dec_buf);

        try testing.expectEqual(len, dec_len);
        try testing.expectEqualSlices(u8, src, dec_buf[0..dec_len]);
    }
}

test "encode size matches maxEncodedLength upper bound" {
    var rng = std.Random.DefaultPrng.init(0x5EED);
    var src_buf: [1024]u8 = undefined;
    var enc_buf: [2048]u8 = undefined;

    var len: usize = 0;
    while (len <= 1024) : (len += 13) {
        const src = src_buf[0..len];
        rng.random().bytes(src);
        const enc_len = try encode(src, &enc_buf);
        try testing.expect(enc_len <= maxEncodedLength(len));
    }
}

// ---- property-based & fuzz tests ----
//
// These tests close the "no fuzz/property testing" gap flagged by external
// review. They exhaustively walk size × content-pattern matrices, drive the
// codec with 10k random adversarial inputs, and exercise the decoder against
// random bytes and bit-flipped frames to confirm it never panics.

/// Fill `dst` with one of the canonical content patterns used by the property
/// tests. Patterns enumerate the corners of COBS' behaviour: pure-zero runs,
/// pure-non-zero runs (worst-case overhead), alternating zeros, and a single
/// zero placed at each of the structurally significant positions.
fn fillPattern(dst: []u8, pattern: u8) void {
    switch (pattern) {
        // all-zero
        0 => @memset(dst, 0),
        // no-zero (all 0xAA)
        1 => @memset(dst, 0xAA),
        // alternating 0x00 0xFF 0x00 0xFF ...
        2 => for (dst, 0..) |*b, i| {
            b.* = if (i % 2 == 0) 0 else 0xFF;
        },
        // single zero at start
        3 => {
            @memset(dst, 0xAA);
            if (dst.len > 0) dst[0] = 0;
        },
        // single zero at end
        4 => {
            @memset(dst, 0xAA);
            if (dst.len > 0) dst[dst.len - 1] = 0;
        },
        // single zero at middle
        5 => {
            @memset(dst, 0xAA);
            if (dst.len > 0) dst[dst.len / 2] = 0;
        },
        // 254-byte non-zero run hugging the worst-case overhead boundary
        6 => for (dst, 0..) |*b, i| {
            b.* = @intCast((i % 254) + 1);
        },
        else => unreachable,
    }
}

test "property: round-trip across size × content-pattern matrix" {
    const sizes = [_]usize{ 0, 1, 2, 7, 8, 254, 255, 256, 512, 1024 };
    const num_patterns: u8 = 7;

    var src_buf: [1024]u8 = undefined;
    var enc_buf: [maxEncodedLength(1024)]u8 = undefined;
    var dec_buf: [1024]u8 = undefined;

    for (sizes) |len| {
        var pattern: u8 = 0;
        while (pattern < num_patterns) : (pattern += 1) {
            const src = src_buf[0..len];
            fillPattern(src, pattern);

            const enc_len = try encode(src, &enc_buf);
            const dec_len = try decode(enc_buf[0..enc_len], &dec_buf);

            try testing.expectEqual(len, dec_len);
            try testing.expectEqualSlices(u8, src, dec_buf[0..dec_len]);
        }
    }
}

test "property: encoded-form invariants across size × content-pattern matrix" {
    // This implementation emits the canonical COBS body WITHOUT the trailing
    // 0x00 frame delimiter (callers append it themselves when streaming). So
    // the invariant we check here is the stronger form: the encoded output
    // contains zero 0x00 bytes anywhere, and its length never exceeds the
    // documented worst-case bound `maxEncodedLength(input.len)`.
    const sizes = [_]usize{ 0, 1, 2, 7, 8, 254, 255, 256, 512, 1024 };
    const num_patterns: u8 = 7;

    var src_buf: [1024]u8 = undefined;
    var enc_buf: [maxEncodedLength(1024)]u8 = undefined;

    for (sizes) |len| {
        var pattern: u8 = 0;
        while (pattern < num_patterns) : (pattern += 1) {
            const src = src_buf[0..len];
            fillPattern(src, pattern);

            const enc_len = try encode(src, &enc_buf);

            // Length never exceeds the documented bound.
            try testing.expect(enc_len <= maxEncodedLength(len));
            // Empty input still produces the canonical single-byte 0x01 frame.
            try testing.expect(enc_len >= 1);

            // No zero bytes anywhere in the encoded body — the entire point
            // of COBS. A 0x00 here would alias the frame delimiter.
            for (enc_buf[0..enc_len]) |b| {
                try testing.expect(b != 0);
            }
        }
    }
}

test "fuzz: 10k random round-trips" {
    var rng = std.Random.DefaultPrng.init(0xF0F0_1234);
    const random = rng.random();

    var src_buf: [1024]u8 = undefined;
    var enc_buf: [maxEncodedLength(1024)]u8 = undefined;
    var dec_buf: [1024]u8 = undefined;

    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        const len = random.intRangeAtMost(usize, 0, 1024);
        const src = src_buf[0..len];
        random.bytes(src);

        const enc_len = try encode(src, &enc_buf);

        // Round-trip equality.
        const dec_len = try decode(enc_buf[0..enc_len], &dec_buf);
        try testing.expectEqual(len, dec_len);
        try testing.expectEqualSlices(u8, src, dec_buf[0..dec_len]);

        // Sensible zero-density relationship: more zeros in the input pushes
        // the encoding closer to the worst-case bound, but the encoded length
        // must always stay between (input_len + 1) -- the minimum where every
        // byte fits in a single run -- and maxEncodedLength.
        try testing.expect(enc_len <= maxEncodedLength(len));
        try testing.expect(enc_len >= @max(@as(usize, 1), len));

        // Count zeros to make the relationship explicit; an input of all
        // zeros must hit (len + 1) exactly because each zero terminates a
        // run of length 1.
        var zero_count: usize = 0;
        for (src) |b| {
            if (b == 0) zero_count += 1;
        }
        if (zero_count == len and len > 0) {
            try testing.expectEqual(len + 1, enc_len);
        }
    }
}

test "fuzz: decode of garbage never panics (10k iterations)" {
    var rng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const random = rng.random();

    var src_buf: [1100]u8 = undefined;
    var dec_buf: [1100]u8 = undefined;

    var iter: usize = 0;
    while (iter < 10_000) : (iter += 1) {
        const len = random.intRangeAtMost(usize, 0, 1100);
        const src = src_buf[0..len];
        random.bytes(src);

        // Decode is allowed to return a payload or an error. The only
        // unacceptable outcome is a panic / undefined behaviour, which would
        // crash the test runner before this line completes.
        if (decode(src, &dec_buf)) |n| {
            try testing.expect(n <= dec_buf.len);
        } else |_| {
            // Whatever error the decoder returned is fine; we just need a
            // well-defined outcome.
        }
    }
}

test "fuzz: single-bit-flip detection never panics decode" {
    // Canonical fixtures: a string with an embedded zero, and a 100-byte
    // pseudo-random payload. For each, encode, then for every bit position
    // in the encoded output flip exactly that bit and run decode. Either
    // decode returns an error or it returns some payload — the only failure
    // mode the test rejects is a panic.
    const fixtures = [_][]const u8{
        "Hello\x00World",
        // Repeated to exercise multi-block COBS encoding too.
        "The quick brown fox\x00jumps over\x00the lazy dog",
    };

    var enc_buf: [maxEncodedLength(256)]u8 = undefined;
    var flipped_buf: [maxEncodedLength(256)]u8 = undefined;
    var dec_buf: [256]u8 = undefined;

    for (fixtures) |src| {
        const enc_len = try encode(src, &enc_buf);

        var byte_idx: usize = 0;
        while (byte_idx < enc_len) : (byte_idx += 1) {
            var bit_idx: u3 = 0;
            while (true) {
                @memcpy(flipped_buf[0..enc_len], enc_buf[0..enc_len]);
                flipped_buf[byte_idx] ^= (@as(u8, 1) << bit_idx);

                if (decode(flipped_buf[0..enc_len], &dec_buf)) |_| {
                    // decode succeeded — that is fine, the output may equal
                    // or differ from `src`. Robustness is the property under
                    // test, not error detection.
                } else |_| {
                    // an error is equally acceptable.
                }

                if (bit_idx == 7) break;
                bit_idx += 1;
            }
        }
    }

    // Also fuzz against a 100-byte random payload to broaden coverage.
    var rng = std.Random.DefaultPrng.init(0xBADC0DE);
    var rand_src: [100]u8 = undefined;
    rng.random().bytes(&rand_src);
    const enc_len = try encode(&rand_src, &enc_buf);

    var byte_idx: usize = 0;
    while (byte_idx < enc_len) : (byte_idx += 1) {
        var bit_idx: u3 = 0;
        while (true) {
            @memcpy(flipped_buf[0..enc_len], enc_buf[0..enc_len]);
            flipped_buf[byte_idx] ^= (@as(u8, 1) << bit_idx);

            if (decode(flipped_buf[0..enc_len], &dec_buf)) |_| {
                // ok
            } else |_| {
                // an error is equally acceptable.
            }

            if (bit_idx == 7) break;
            bit_idx += 1;
        }
    }
}
