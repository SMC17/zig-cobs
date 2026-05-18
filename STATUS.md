# zig-cobs status

Last touched: 2026-05-15

## Honest version posture

Despite the `v1.1.0` git tag, this project is **pre-1.0 in semver
spirit** for two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the Zig language hits 1.0,
   no Zig library can credibly claim API stability beyond "stable on
   Zig 0.16 today." Tagging v1.x against a pre-1.0 substrate is a
   vanity claim — the language guarantees aren't there yet.
2. **No production deployment exists.** This library has zero
   real-traffic operation, zero soak time, zero production-incident
   history. "Production-grade hygiene milestone" describes shipping
   process (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT)
   — necessary but **not sufficient** for "production-grade."

The hygiene work is real. The v1.x tag will be honored for changelog
continuity. But every reader should treat this as a pre-1.0 substrate
until both gates above close.

## Proof-vocabulary index (per `~/AGENT_HARNESS.md`)

| component                | proof level                  | evidence                                                                 |
|--------------------------|------------------------------|--------------------------------------------------------------------------|
| `encode` / `decode`      | `unit-tested` + `audited`    | 22 in-source tests; differential vs independent C reference + 5 ToN-1999 paper vectors; 10 053 checks total |
| Fuzz harness             | `audited` (self-consistent)  | 117 K trials (12 K boundary + 100 K random + 5 K adversarial); zero panics on `decode` of garbage |
| Throughput               | `benchmarked` (one HW class) | `bench/RESULTS.md`: single-run + statistical (`tools/bench-statistical.sh`); Linux x86_64 only |
| Mutation surface         | `audited`                    | `tools/mutation-test.sh` 10/10 killed after `maxEncodedLength`-tightness regression test (commit `111584d`) |
| README/code drift        | `unit-tested`                | `tools/doctest.sh` 5/5: Quickstart block + API signatures + build steps |
| Cross-architecture build | `compiled` (CI only)         | CI matrix on Linux x86_64 + Linux aarch64 + macOS arm64                  |

## Gates that would justify a stronger claim

- **G1 — Hardware-verified throughput on an MCU target.** ESP32-class
  run with measured throughput + bit-error curve under noisy serial.
  Status: `NOT YET CLOSED`.
- **G2 — Soak time.** ≥30 days of continuous deployment under real
  serial / UART / USB-CDC traffic in some real system (mast, a sovereign-
  stack-demo node, anything that uses the library in anger). Status:
  `NOT YET CLOSED`.
- **G3 — Independent security review.** A second pair of eyes on the
  COBS implementation, ideally someone who has shipped framing in
  production. Status: `NOT YET CLOSED`.
- **G4 — Zig 1.0 reaches stable.** The language-level guarantee that
  makes the v1.x tag mean what it says in any other ecosystem. Status:
  `NOT YET CLOSED` (out of this repo's control).

Only after G4 + at least one of G1 / G2 / G3 do the words "production-
grade" or "stable v1" honestly fit.
