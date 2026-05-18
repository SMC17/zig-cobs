# Changelog

All notable changes to `zig-cobs` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.2.0] — 2026-05-15

### Added
- **Line coverage measurement: 100% on `src/root.zig`** (48/48 lines).
  Closes the Wave-4 fleet-wide gap "we cite test counts without naming
  what % of code those tests actually exercise". Methodology:
  - `examples/coverage_driver.zig` — single-binary executable that
    exercises every public function (`encode`, `decode`,
    `maxEncodedLength`) and every public error path (`BufferTooSmall`,
    `InvalidEncoding`) across a deterministic input matrix.
  - `tools/coverage.sh` — wrapper that builds the driver in Debug,
    runs `kcov --include-pattern=root.zig` against it, prints the
    line %, and fails if coverage drops below 80% (current floor).
  - `.github/workflows/ci.yml` — `coverage` job that runs on every
    push and uploads the kcov HTML report as an artifact.

### Why a coverage-driver instead of `zig test`
- The Zig 0.16 test runner's debug-info layout currently does not
  surface line-coverage to kcov through the nixpkgs build (which is
  compiled without libbfd-dev). A plain executable has standard
  ELF+DWARF and kcov captures it cleanly. The driver runs the same
  assertions as the test suite, in a form kcov can introspect.

### Evidence vocabulary added
- `coverage-measured` evidence level documented in README.

## [Unreleased]

### Honesty correction — 2026-05-15

Prior `v1.0` / `v1.1` / "production-grade hygiene milestone" framing was
a Type-I error class per the no-premature-production-claims doctrine:

- **Zig itself is on 0.16, not 1.0.** No Zig library can credibly claim
  API stability beyond "stable on Zig 0.16 today" until the language
  itself ships 1.0. The v1.x git tags are honored for changelog
  continuity, but every reader should treat this as **pre-1.0 in semver
  spirit** until both that gate and a real-deployment gate close.
- **Zero production deployment exists.** No real-traffic operation, no
  soak time, no incident history. The hygiene work
  (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT / dependabot
  / CODEOWNERS) is real. The production claim it implied **wasn't
  earned.**

Going forward, the AGENT_HARNESS proof vocabulary (`scaffold` /
`compiled` / `unit-tested` / `integration-tested` / `audited` /
`benchmarked` / `hardware-verified`) is used strictly. See `STATUS.md`
for the per-component proof index + the gates that would justify a
stronger claim.

### Added

- `tests/differential.zig` + `tests/c_ref/` — differential conformance harness cross-checking the Zig encoder/decoder against an independent C reference (written from Cheshire & Baker 1997/1999) plus the first five canonical paper test vectors from Table 1 of the IEEE/ACM ToN 1999 writeup. `zig build differential` runs 5 paper vectors + 10,000 random trials (mixed size buckets 0..4096) + 16 boundary sizes + 32 pure-pattern inputs; all 10,053 checks pass byte-identical in both encode and cross-decode directions on Linux x86_64 / Zig 0.16.0. Scope-honest: paper vectors 6–10 are intentionally omitted because the paper's tabulated encoded form drops the phantom-block trailer that every real implementation must emit — the rationale is documented in the test source.
- `bench/RESULTS.md` — published throughput numbers from `zig build bench -Doptimize=ReleaseFast` on a pinned hardware class (Intel Core i7-1065G7 / Linux x86_64 / Zig 0.16.0). Asymptotic encode ~340 MB/s, decode ~425 MB/s, worst-case 254-byte run encode 465 MB/s / decode 883 MB/s. Reproducer + reading notes + not-yet list pinned in the file. Closes the "throughput benchmark not chosen by the differential rip" gap.

## [1.1.0] — 2026-05-14

First post-hygiene-v1.0 feature release. Adds a substantive fuzz harness.

### Added

- `tests/fuzz.zig` — three-property fuzz harness asserting against arbitrary byte inputs:
  1. **Round-trip invariance:** `decode(encode(x)) == x` for all `x`.
  2. **Zero-freeness:** `encode` output never contains a `0x00` byte.
  3. **Decoder soundness:** `decode` on adversarial random bytes either succeeds or returns `InvalidEncoding` / `BufferTooSmall` — never panics, never overflows the destination buffer.
- `zig build fuzz` step (ReleaseFast): 117,000 trials (12K boundary + 100K random round-trip + 5K adversarial decoder).
- Boundary sizes specifically exercised at 1,000 reps each: `{0, 1, 2, 253, 254, 255, 256, 508, 509, 510, 762, 4096}` — the overhead-byte injection boundary that random-PRNG-only trials would hit with low probability.
- `zig build test` now includes a 2,400-trial CI-friendly fuzz subset.
- CI workflow gates the full `zig build fuzz` after every push.

### Verified

- Linux x86_64: 117,000 trials pass, all three properties hold.
- Apple Silicon arm64 (mac): identical 117,000 trials pass.

## [1.0.0] — 2026-05-13

**Production-grade hygiene milestone.**

- Added SECURITY.md (coordinated disclosure policy).
- Verified LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT, CI workflow all in place and accurate.
- API surface declared stable for the v1.x cycle. Breaking changes will bump to v2.x.
- Engineering posture: Virgil work-in-progress convention adapted for OSS — v1.0 means we stand behind the existing surface; v1.x patches refine implementation without breaking the API.

## [0.1.0] — 2026-05-13

Initial release.

### Added
- `encode(src, dst)` — COBS encoder writing into a caller-provided buffer.
- `decode(src, dst)` — COBS decoder writing into a caller-provided buffer.
- `maxEncodedLength(input_len)` — exact worst-case encoded size, suitable
  for sizing destination buffers at the call site.
- `Error` enum: `BufferTooSmall`, `InvalidEncoding`.
- Property-based roundtrip tests across input lengths 0–2048 with
  pseudo-random payloads.
- Boundary tests at the 254 and 255 byte overhead breakpoints.
- Encoded-output invariant test confirming no `0x00` bytes in any frame.
- Buffer-undersize and malformed-frame rejection tests for both `encode`
  and `decode`.

### Fixed (vs. internal predecessor implementations)
- Bounds check in `encode` previously read `dst.len < src.len + 2`, which
  was too permissive for inputs whose worst-case encoded length exceeds
  `src.len + 1`. The check now uses `maxEncodedLength(src.len)` directly.
