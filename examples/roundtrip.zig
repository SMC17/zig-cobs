//! Minimal zig-cobs example — encode a payload, frame it with a 0x00
//! delimiter, decode it, and print the result.
//!
//! Build: `zig build example-roundtrip`
//! Run:   `./zig-out/bin/example-roundtrip`

const std = @import("std");
const cobs = @import("cobs");

pub fn main() !void {
    // A payload containing zero bytes — exactly the case COBS exists for.
    const payload = "Hello\x00World\x00\x00COBS";

    // Size the destination buffer using the worst-case formula.
    var encoded: [cobs.maxEncodedLength(payload.len) + 1]u8 = undefined;
    const enc_len = try cobs.encode(payload, encoded[0..encoded.len - 1]);

    // Append the 0x00 frame delimiter (the encoded bytes are zero-free, so
    // the delimiter is unambiguous on the wire).
    encoded[enc_len] = 0;
    const frame = encoded[0 .. enc_len + 1];

    std.debug.print("payload    ({d:>3} bytes): ", .{payload.len});
    for (payload) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\nframe      ({d:>3} bytes): ", .{frame.len});
    for (frame) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\n", .{});

    // Verify the encoded portion contains no zero bytes.
    for (encoded[0..enc_len]) |b| std.debug.assert(b != 0);

    // Decode the encoded portion (strip the trailing 0x00 delimiter first).
    var decoded: [payload.len]u8 = undefined;
    const dec_len = try cobs.decode(encoded[0..enc_len], &decoded);

    std.debug.print("decoded    ({d:>3} bytes): {s}\n", .{ dec_len, decoded[0..dec_len] });

    std.debug.assert(std.mem.eql(u8, payload, decoded[0..dec_len]));
    std.debug.print("\nroundtrip OK\n", .{});
}
