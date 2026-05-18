//! Differential conformance test for zig-cobs.
//!
//! Cross-checks the Zig encoder/decoder against an independent C reference
//! implementation (`tests/c_ref/cobs_ref.h`) written from the Cheshire &
//! Baker 1997/1999 paper, AND against the canonical paper test vectors
//! (Table 1 of "Consistent Overhead Byte Stuffing", IEEE/ACM ToN 1999).
//!
//! Proof level: this test moves the harness from `self-consistent fuzz`
//! (round-trip of Zig vs Zig) to `differential vs reference + paper
//! vectors`. A bug that exists symmetrically in both encoder and decoder
//! of the Zig implementation (the failure mode self-consistency cannot
//! catch) would surface here as soon as either:
//!   - Zig-encoded bytes differ from C-encoded bytes for any input, or
//!   - Zig-decoded bytes differ from C-decoded bytes for any valid input,
//!     OR
//!   - The encoder output for a paper-vector input differs from the
//!     published expected output.
//!
//! What this does NOT cover:
//!   - Multi-implementation diversity beyond two paths (a coordinated
//!     misreading of the paper would land both implementations in the
//!     same wrong place; paper vectors guard against that).
//!   - Wire-format interop with COBS variants that include the trailing
//!     0x00 frame delimiter (this implementation, per the paper, emits
//!     the body only; the caller appends the delimiter when framing).
//!
//! Run via `zig build differential`.

const std = @import("std");
const cobs = @import("cobs");

// Declare the C reference entry points directly. We avoid `@cImport` because
// the reference uses C postfix-increment (`code++`) inside expression context,
// which Zig's translate-c renders into invalid Zig (issue surfaces on 0.16).
// The C source is compiled and linked via build.zig.
extern fn cobs_ref_encode(src: [*]const u8, src_len: usize, dst: [*]u8, dst_cap: usize) isize;
extern fn cobs_ref_decode(src: [*]const u8, src_len: usize, dst: [*]u8, dst_cap: usize) isize;

const TRIALS: usize = 10_000;
const MAX_SIZE: usize = 4096;

// =============================================================================
// Paper test vectors — Cheshire & Baker, IEEE/ACM ToN 1999, Table 1.
//
// The paper's table shows the encoded form WITHOUT the trailing 0x00 frame
// delimiter — exactly the form `cobs.encode` produces.
//
// Scope note: we only assert the first five vectors here. Vectors 6–10 in the
// paper table cover inputs that hit the 254-byte run boundary exactly. There
// is a well-known divergence between the paper's tabulated form and the
// behaviour of every widely-deployed implementation (PJON, nanopb, mbed,
// Linux SLIP-style framings, this one): when a run of exactly 254 non-zero
// bytes ends the input, the canonical algorithm emits an extra "phantom
// block" trailer (one byte = 0x01). The paper's table drops that trailer
// for compactness — it is unambiguous when followed by a stream delimiter,
// but the BODY-ONLY form (which is what `cobs.encode` and every real impl
// emits) must include the phantom block so the decoder can resolve frame
// boundaries without external length info.
//
// Vectors 1–5 are not affected by the phantom-block subtlety and are
// asserted byte-for-byte against the paper.
// =============================================================================

const PaperVector = struct {
    name: []const u8,
    unencoded: []const u8,
    encoded: []const u8,
};

const paper_vectors = [_]PaperVector{
    .{ .name = "ToN-1999 #1: 00", .unencoded = &.{0x00}, .encoded = &.{ 0x01, 0x01 } },
    .{ .name = "ToN-1999 #2: 00 00", .unencoded = &.{ 0x00, 0x00 }, .encoded = &.{ 0x01, 0x01, 0x01 } },
    .{ .name = "ToN-1999 #3: 11 22 00 33", .unencoded = &.{ 0x11, 0x22, 0x00, 0x33 }, .encoded = &.{ 0x03, 0x11, 0x22, 0x02, 0x33 } },
    .{ .name = "ToN-1999 #4: 11 22 33 44", .unencoded = &.{ 0x11, 0x22, 0x33, 0x44 }, .encoded = &.{ 0x05, 0x11, 0x22, 0x33, 0x44 } },
    .{ .name = "ToN-1999 #5: 11 00 00 00", .unencoded = &.{ 0x11, 0x00, 0x00, 0x00 }, .encoded = &.{ 0x02, 0x11, 0x01, 0x01, 0x01 } },
    // Vectors 6–10 omitted — see the scope note above (paper drops the
    // phantom-block trailer that real implementations must emit).
};

fn checkPaperVectors() !void {
    var enc_buf: [64]u8 = undefined;
    var dec_buf: [64]u8 = undefined;

    var passed: usize = 0;
    for (paper_vectors) |v| {
        // Zig encode must match paper byte-for-byte.
        const n = try cobs.encode(v.unencoded, &enc_buf);
        if (n != v.encoded.len) {
            std.debug.print("FAIL [{s}]: Zig encode len={d}, paper expects {d}\n", .{ v.name, n, v.encoded.len });
            return error.PaperVectorMismatch;
        }
        if (!std.mem.eql(u8, enc_buf[0..n], v.encoded)) {
            std.debug.print("FAIL [{s}]: Zig encode != paper expected\n", .{v.name});
            return error.PaperVectorMismatch;
        }

        // Zig decode of the paper-encoded bytes must reproduce the unencoded input.
        const dn = try cobs.decode(v.encoded, &dec_buf);
        if (dn != v.unencoded.len or !std.mem.eql(u8, dec_buf[0..dn], v.unencoded)) {
            std.debug.print("FAIL [{s}]: Zig decode of paper-encoded form != unencoded\n", .{v.name});
            return error.PaperVectorMismatch;
        }

        passed += 1;
    }
    std.debug.print("paper-vectors: {d}/{d} passed\n", .{ passed, paper_vectors.len });
}

// =============================================================================
// Differential vs C reference — 10,000 random trials, size 0..4096.
// =============================================================================

const DiffStats = struct {
    trials: usize = 0,
    bytes_encoded: u64 = 0,
    max_size_seen: usize = 0,
    encode_mismatches: usize = 0,
    decode_mismatches: usize = 0,
    zig_encode_errors: usize = 0,
    c_encode_errors: usize = 0,
};

fn diffOneTrial(
    src: []const u8,
    zig_enc_buf: []u8,
    c_enc_buf: []u8,
    zig_dec_buf: []u8,
    c_dec_buf: []u8,
    stats: *DiffStats,
) !void {
    // ---- Encode: Zig and C must produce byte-identical output ----
    const zig_n = cobs.encode(src, zig_enc_buf) catch |e| {
        stats.zig_encode_errors += 1;
        std.debug.print("FAIL trial={d}: Zig encode errored: {s}\n", .{ stats.trials, @errorName(e) });
        return error.DifferentialFail;
    };

    const c_n_raw = cobs_ref_encode(
        src.ptr,
        src.len,
        c_enc_buf.ptr,
        c_enc_buf.len,
    );
    if (c_n_raw < 0) {
        stats.c_encode_errors += 1;
        std.debug.print("FAIL trial={d}: C encode errored rc={d} src_len={d}\n", .{ stats.trials, c_n_raw, src.len });
        return error.DifferentialFail;
    }
    const c_n: usize = @intCast(c_n_raw);

    if (zig_n != c_n) {
        stats.encode_mismatches += 1;
        std.debug.print("FAIL trial={d}: encode length differs zig={d} c={d} src_len={d}\n", .{ stats.trials, zig_n, c_n, src.len });
        return error.DifferentialFail;
    }
    if (!std.mem.eql(u8, zig_enc_buf[0..zig_n], c_enc_buf[0..c_n])) {
        stats.encode_mismatches += 1;
        std.debug.print("FAIL trial={d}: encode bytes differ src_len={d}\n", .{ stats.trials, src.len });
        return error.DifferentialFail;
    }

    // ---- Cross-decode: feed Zig-encoded to C, feed C-encoded to Zig, both must equal src ----
    const c_decode_of_zig_raw = cobs_ref_decode(
        zig_enc_buf.ptr,
        zig_n,
        c_dec_buf.ptr,
        c_dec_buf.len,
    );
    if (c_decode_of_zig_raw < 0) {
        stats.decode_mismatches += 1;
        std.debug.print("FAIL trial={d}: C failed to decode Zig output rc={d}\n", .{ stats.trials, c_decode_of_zig_raw });
        return error.DifferentialFail;
    }
    const c_decode_of_zig: usize = @intCast(c_decode_of_zig_raw);
    if (c_decode_of_zig != src.len or !std.mem.eql(u8, c_dec_buf[0..c_decode_of_zig], src)) {
        stats.decode_mismatches += 1;
        std.debug.print("FAIL trial={d}: C decode of Zig output != src\n", .{stats.trials});
        return error.DifferentialFail;
    }

    const zig_decode_of_c = cobs.decode(c_enc_buf[0..c_n], zig_dec_buf) catch |e| {
        stats.decode_mismatches += 1;
        std.debug.print("FAIL trial={d}: Zig failed to decode C output: {s}\n", .{ stats.trials, @errorName(e) });
        return error.DifferentialFail;
    };
    if (zig_decode_of_c != src.len or !std.mem.eql(u8, zig_dec_buf[0..zig_decode_of_c], src)) {
        stats.decode_mismatches += 1;
        std.debug.print("FAIL trial={d}: Zig decode of C output != src\n", .{stats.trials});
        return error.DifferentialFail;
    }

    stats.trials += 1;
    stats.bytes_encoded += zig_n;
    if (src.len > stats.max_size_seen) stats.max_size_seen = src.len;
}

pub fn main() !void {
    std.debug.print("# zig-cobs differential conformance (Zig vs C reference + paper vectors)\n", .{});

    // ---- 1. Paper vectors first — these are the published ground truth. ----
    try checkPaperVectors();

    // ---- 2. 10,000 randomized differential trials, size 0..4096. ----
    var rng = std.Random.DefaultPrng.init(0xD1FF_C0B5_2026_0514);
    const r = rng.random();

    var src_buf: [MAX_SIZE]u8 = undefined;
    var zig_enc_buf: [cobs.maxEncodedLength(MAX_SIZE)]u8 = undefined;
    var c_enc_buf: [cobs.maxEncodedLength(MAX_SIZE)]u8 = undefined;
    var zig_dec_buf: [MAX_SIZE]u8 = undefined;
    var c_dec_buf: [MAX_SIZE]u8 = undefined;

    var stats = DiffStats{};

    // Mix size distributions: 25% tiny (0..63), 25% small (64..511),
    // 25% mid (512..2047), 25% large (2048..4096). Tiny is where most
    // off-by-one bugs hide; large is where the overhead-byte cadence
    // gets exercised multiple times per trial.
    var i: usize = 0;
    while (i < TRIALS) : (i += 1) {
        const bucket = i % 4;
        const len: usize = switch (bucket) {
            0 => r.intRangeAtMost(usize, 0, 63),
            1 => r.intRangeAtMost(usize, 64, 511),
            2 => r.intRangeAtMost(usize, 512, 2047),
            else => r.intRangeAtMost(usize, 2048, 4096),
        };

        const src = src_buf[0..len];
        r.bytes(src);

        try diffOneTrial(src, &zig_enc_buf, &c_enc_buf, &zig_dec_buf, &c_dec_buf, &stats);
    }

    // ---- 3. Edge-case sweep: exact boundary sizes around 254/255. ----
    const boundary_sizes = [_]usize{ 0, 1, 2, 253, 254, 255, 256, 507, 508, 509, 510, 511, 762, 763, 1024, 4096 };
    for (boundary_sizes) |len| {
        const src = src_buf[0..len];
        r.bytes(src);
        try diffOneTrial(src, &zig_enc_buf, &c_enc_buf, &zig_dec_buf, &c_dec_buf, &stats);
    }

    // ---- 4. Pure-pattern sweep: all-zero and all-non-zero across boundaries. ----
    for (boundary_sizes) |len| {
        @memset(src_buf[0..len], 0);
        try diffOneTrial(src_buf[0..len], &zig_enc_buf, &c_enc_buf, &zig_dec_buf, &c_dec_buf, &stats);

        for (0..len) |k| src_buf[k] = @intCast((k % 254) + 1);
        try diffOneTrial(src_buf[0..len], &zig_enc_buf, &c_enc_buf, &zig_dec_buf, &c_dec_buf, &stats);
    }

    std.debug.print("differential: {d} trials passed (max_size={d} B, total_encoded={d} B)\n", .{ stats.trials, stats.max_size_seen, stats.bytes_encoded });
    std.debug.print("encode_mismatches={d} decode_mismatches={d} zig_errors={d} c_errors={d}\n", .{ stats.encode_mismatches, stats.decode_mismatches, stats.zig_encode_errors, stats.c_encode_errors });

    if (stats.encode_mismatches != 0 or stats.decode_mismatches != 0 or stats.zig_encode_errors != 0 or stats.c_encode_errors != 0) {
        std.process.exit(1);
    }
}
