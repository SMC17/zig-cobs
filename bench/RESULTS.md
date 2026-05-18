# zig-cobs / bench / RESULTS

**Reproducer:** `zig build bench -Doptimize=ReleaseFast`

**Run captured:** 2026-05-14

**Hardware class:** Intel Core i7-1065G7 @ 1.30 GHz (Ice Lake, 4c8t mobile)
laptop / Linux 7.0.3-arch1-1 / Zig 0.16.0

**Timing:** `std.os.linux.clock_gettime(.MONOTONIC, ...)` direct
(`std.time.Timer` was removed in Zig 0.16). Resolution is nanoseconds,
single VDSO call per checkpoint — no syscall overhead.

**Inputs:** pseudo-random payloads (~99.6 % non-zero bytes on average),
seeded so reruns are deterministic. Warm-up 1 000 iters discarded.
Measurement loops scaled so each row is ~1 s of wall time.

## Numbers

### encode (random payload, ~99.6 % non-zero)

| Size  | Iters     | Total       | ns/op    | MB/s |
| ----- | --------- | ----------- | -------- | ---- |
| 16 B  | 5 000 000 | 179.9 ms    | 35       | 444  |
| 256 B | 1 000 000 | 684.3 ms    | 684      | 374  |
| 1 KiB | 500 000   | 1.867 s     | 3 733    | 274  |
| 64 KiB| 20 000    | 3.845 s     | 192 262  | 340  |

### decode (random payload, ~99.6 % non-zero)

| Size  | Iters     | Total       | ns/op    | MB/s |
| ----- | --------- | ----------- | -------- | ---- |
| 16 B  | 5 000 000 | 233.6 ms    | 46       | 342  |
| 256 B | 1 000 000 | 632.0 ms    | 632      | 405  |
| 1 KiB | 500 000   | 1.238 s     | 2 475    | 413  |
| 64 KiB| 20 000    | 3.079 s     | 153 964  | 425  |

### worst-case 254-byte run (all non-zero — maximum overhead block density)

| Op     | Iters     | Total    | ns/op  | MB/s |
| ------ | --------- | -------- | ------ | ---- |
| encode | 2 000 000 | 1.091 s  | 545    | 465  |
| decode | 2 000 000 | 575.1 ms | 287    | 883  |

## Reading

- **Asymptotic encode ≈ 340 MB/s** at 64 KiB on this hardware; the dip at
  1 KiB vs 256 B reflects cache-line pressure on the overhead-byte refresh
  pattern. 16 B is fastest because the entire payload fits in registers.
- **Asymptotic decode ≈ 425 MB/s** — slightly faster than encode because
  decode does one pass with simple branchy byte copies, no overhead-block
  bookkeeping.
- **Worst-case 254-byte run encode (465 MB/s)** is *faster* than the
  random-payload encode at 256 B (374 MB/s). This is because the worst
  case avoids the conditional-branch overhead per overhead-block: the
  encoder writes one block of 254 + the phantom terminator in a tight
  loop.

## Theoretical overhead

COBS adds 1 byte per 254-byte run + 1 byte at the head + 1 byte
delimiter. For an N-byte payload with no embedded zeros, overhead is
roughly `1 + ceil(N / 254) + 1` ≈ 0.4 % at large N. The
`bench_worst_case` row exercises exactly this density.

## Not yet measured

- **aarch64 / Apple Silicon** — same hardware class as the rest of the
  Sovereign Stack today; mobile/desktop x86_64 only.
- **ESP32 / Cortex-M0+ / RP2040 / STM32** — the freestanding targets the
  README pitches. The library compiles for those targets (verified by
  `zig build` with cross-target flags), but no on-device throughput
  numbers are published.
- **Streaming / chunked encode-decode** — current API is one-shot.
- **Different allocator patterns** — n/a; this lib is zero-allocation by
  construction.

## Reproducibility

To reproduce on your own hardware:

```sh
git checkout v1.1.0  # or current HEAD
zig build bench -Doptimize=ReleaseFast
```

Per-bench seeds are pinned in source; output is plain `key=value`
whitespace-separated and parseable into tabular form.
