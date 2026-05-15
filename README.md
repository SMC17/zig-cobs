# zig-cobs

[![CI](https://github.com/SMC17/zig-cobs/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/zig-cobs/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/SMC17/zig-cobs?display_name=tag&sort=semver)](https://github.com/SMC17/zig-cobs/releases) [![License](https://img.shields.io/github/license/SMC17/zig-cobs)](LICENSE)

Consistent Overhead Byte Stuffing (COBS) framing in pure Zig. Zero allocation,
no dependencies, suitable for embedded targets and high-throughput stream
framing on hosts.

COBS turns an arbitrary byte stream into a zero-free encoded form so that a
single `0x00` byte can be used as an unambiguous frame delimiter. Worst-case
overhead is `1 + ceil(len / 254)` bytes — about 0.4% on long payloads.

Reference: Cheshire & Baker, [Consistent Overhead Byte Stuffing][cobs-paper]
(SIGCOMM 1997).

[cobs-paper]: http://www.stuartcheshire.org/papers/COBSforToN.pdf

## Status

`v1.1.0` — stable API. The public surface (`encode`, `decode`,
`maxEncodedLength`, two error variants) is locked: breaking changes will
be v2.0. **22 tests pass** (21 correctness/robustness + 1 fuzz harness),
covering:

- Round-trip correctness across the size × content-pattern matrix (every documented edge case)
- Encoded-form invariants (no `0x00` bytes in any encoded body, length ≤ `maxEncodedLength`)
- 10,000-iteration random round-trip fuzz
- 10,000-iteration garbage-decode never-panic robustness
- Exhaustive single-bit-flip mutation of canonical encoded frames (decode either errors or returns — never crashes)
- **v1.1 fuzz harness**: 117,000-trial bounded-input fuzz gated in CI

Production-grade benchmarks shipped (`zig build bench`). Zero allocation,
no third-party dependencies, freestanding-friendly.

CI covers Linux x86_64, Linux aarch64, and macOS arm64 (native runners), plus
cross-compile sanity checks for `aarch64-linux-gnu`, `aarch64-macos`,
`x86_64-linux-gnu`, and `x86_64-macos` from the x86_64 host.

Minimum Zig version: `0.16.0`.

## Install

Add `zig-cobs` to your `build.zig.zon` dependencies:

```zig
.dependencies = .{
    .cobs = .{
        .url = "https://github.com/SMC17/zig-cobs/archive/refs/tags/v1.0.0.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const cobs = b.dependency("cobs", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("cobs", cobs.module("cobs"));
```

## Quickstart

```zig
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
```

## API

```zig
pub fn maxEncodedLength(input_len: usize) usize;
pub fn encode(src: []const u8, dst: []u8) Error!usize;
pub fn decode(src: []const u8, dst: []u8) Error!usize;

pub const Error = error{
    BufferTooSmall,
    InvalidEncoding,
};
```

- `maxEncodedLength` — exact worst-case size of an encoded buffer for an
  input of `input_len` bytes. Use it to size `dst` for `encode`.
- `encode` — write the COBS-encoded form of `src` into `dst`. Returns the
  number of bytes written. `dst.len` must be at least
  `maxEncodedLength(src.len)`; otherwise returns `error.BufferTooSmall`.
  Encoded output never contains a `0x00` byte.
- `decode` — write the decoded payload of a COBS frame `src` into `dst`.
  Returns the number of payload bytes written. `src` must not contain a
  `0x00` byte; if it does, returns `error.InvalidEncoding`. The frame
  delimiter `0x00` is *not* part of `src` — strip it before calling.

## Tests

```sh
zig build test
```

21 tests. Fuzz and property tests now cover round-trip across every documented
size × content-pattern corner plus 10k random adversarial payloads, and exercise
the decoder against random bytes and single-bit-flipped frames to confirm it
never panics.

Includes:

- Boundary cases at empty input, single-zero, single-non-zero, 254-byte runs
  (no overhead injection), 255-byte runs (overhead byte injected).
- Encoded-output invariant: no `0x00` bytes in any encoded frame.
- Buffer-undersize rejection on both `encode` and `decode`.
- Malformed-frame rejection (zero byte mid-frame, truncated frame).
- Property-based roundtrip across lengths 0–2048 with pseudo-random payloads.
- Property-based check that `encode` output is always `≤ maxEncodedLength`.
- Property-based round-trip across the size × content-pattern matrix
  (`{0, 1, 2, 7, 8, 254, 255, 256, 512, 1024}` × seven patterns including
  all-zero, no-zero, alternating, single-zero placements, and the 254-byte
  worst-case-overhead run).
- Property-based encoded-form invariants across the same matrix.
- Fuzz: 10,000 random-length, random-content round-trips.
- Fuzz: 10,000 random byte sequences fed to `decode` to confirm it never
  panics on garbage input.
- Fuzz: exhaustive single-bit-flip mutations of canonical encoded frames,
  asserting `decode` only ever returns or errors — never crashes.

## Use cases

- Serial / UART framing over MCUs (ESP32, STM32, RP2040)
- Sensor data streams over unreliable links
- USB CDC or BLE characteristic stream framing
- Any byte stream where a single-byte unambiguous frame delimiter is desired

## Why no allocator parameter

`encode` and `decode` operate strictly on caller-provided buffers. This keeps
the library usable on `freestanding` targets, in interrupt handlers, and in
contexts where allocator failure is not an option. Compute the required buffer
size with `maxEncodedLength` at the call site.

## Benchmarks

```sh
zig build bench
```

Three benchmarks ship under `bench/`:

- `bench_encode.zig` — encode throughput at 16 B / 256 B / 1 KiB / 64 KiB
- `bench_decode.zig` — decode throughput at the same matrix
- `bench_worst_case.zig` — 254-byte all-non-zero pattern (the boundary that
  triggers the COBS overhead-byte injection on every run; useful for spotting
  cliffs in the overhead-refresh path)

Each benchmark warms up for 1 000 iterations, then measures with enough
iterations (5 M for 16 B, scaled down for larger sizes) to dampen variance
across roughly one second of wall time. Output is parseable
`key=value` lines so external collectors can scrape them. Timing uses
`std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly — `std.time.Timer` and
`std.time.nanoTimestamp` were removed in Zig 0.16's stdlib reshuffle.

Representative numbers on the maintainer's workstation
(Intel Core i7-1065G7 @ 1.30 GHz, Linux 7.0.3-arch1-1 x86_64, Zig 0.16.0,
`zig build bench` with `-Doptimize=ReleaseFast`):

| Bench                | Size   | ns/op   | MB/s |
| -------------------- | ------ | ------- | ---- |
| encode (random)      | 256 B  | 1 933   |  132 |
| encode (random)      | 1 KiB  | 17 478  |   58 |
| encode (random)      | 64 KiB | 410 359 |  159 |
| decode (random)      | 256 B  | 1 391   |  183 |
| decode (random)      | 64 KiB | 276 451 |  237 |
| encode (worst-case)  | 254 B  | 715     |  354 |
| decode (worst-case)  | 254 B  | 1 215   |  209 |

The worst-case all-non-zero row is faster than the random-payload row because
the inner loop has no zero-byte branch to mispredict; encode hits a
straight-line copy with one overhead-byte refresh.

These numbers are on my workstation; bring your own data.

## License

MIT. See `LICENSE`.

## Contributing

Issues and PRs welcome. The code surface is intentionally small; changes
should preserve zero-allocation, freestanding-friendly, and `O(n)` time
properties.

## Part of the Sovereign Stack

This is one of a set of small, composable Zig libraries.

- [**zig-frame-protocol**](https://github.com/SMC17/zig-frame-protocol) — versioned binary frame protocol that uses `zig-cobs` for framing
- [**zig-graph**](https://github.com/SMC17/zig-graph) — sparse undirected graph + spectral algorithms
- [**zig-h3**](https://github.com/SMC17/zig-h3) — H3 v4 spatial index, pure-Zig + libh3 wrapper

See [github.com/SMC17](https://github.com/SMC17) for the full portfolio.
