// examples/quickstart.zig
//
// This file is the README "Quickstart" code block, vendored verbatim
// (lines 62..82 of README.md). It exists so the documentation claim is
// EXECUTABLE: `tools/doctest.sh` extracts the block from README and
// diffs against this file; drift between README and code FAILS the
// doc-test. The build wires this as `zig build example-quickstart`,
// which compiles + runs the program and asserts a non-zero exit
// signals a regression.
//
// If you edit the README Quickstart, you MUST update this file too.
// Conversely, if you change the API, you MUST update the README
// Quickstart. The doctest enforces the contract.

const std = @import("std");
const cobs = @import("cobs");

pub fn main() !void {
    const payload = "hello\x00world";

    // Size the output buffer using the worst-case formula.
    var encoded: [cobs.maxEncodedLength(payload.len)]u8 = undefined;
    const enc_len = try cobs.encode(payload, &encoded);

    // Encoded form contains no zero bytes; append a 0x00 delimiter when
    // transmitting over a stream.
    std.debug.print("encoded {} bytes\n", .{enc_len});

    var decoded: [payload.len]u8 = undefined;
    const dec_len = try cobs.decode(encoded[0..enc_len], &decoded);

    std.debug.assert(std.mem.eql(u8, payload, decoded[0..dec_len]));
}
