#!/usr/bin/env bash
# zig-cobs / tools / bench-statistical.sh
#
# Re-run `zig build bench -Doptimize=ReleaseFast` N times, collect samples
# per (bench, size, op) row, report median / p95 / p99 / IQR instead of a
# single-run point estimate.
#
# WHY: A single benchmark run is a noisy sample of the underlying
# distribution. CPU thermal throttling, scheduler jitter, page-cache
# variance, and (especially) cold-cache vs warm-cache can push a single
# number by ±30%–4× in the worst case. The Jane-Street latency-
# distribution discipline says: publish the distribution, not the mean.
#
# Empirical evidence on this very repo: a 2026-05-14 RESULTS.md run
# reported decode @ 16B = 342 MB/s; a 2026-05-15 single re-run reported
# 1083 MB/s on the same hardware. That's a 3× delta from thermal /
# cache state — exactly the noise distributional reporting catches.
#
# Run: `BENCH_N=15 bash tools/bench-statistical.sh` (default N=15).

set -euo pipefail
cd "$(dirname "$0")/.."

N="${BENCH_N:-15}"
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

# Warm-up — discarded.
echo "warming up..." >&2
zig build bench -Doptimize=ReleaseFast >/dev/null 2>&1 || { echo "ERROR: zig build bench failed"; exit 1; }

echo "collecting $N samples..." >&2
for i in $(seq 1 "$N"); do
  printf "  run %2d/%d\r" "$i" "$N" >&2
  zig build bench -Doptimize=ReleaseFast 2>&1 | while IFS= read -r line; do
    case "$line" in
      bench=*)
        # Each bench line: bench=<NAME> size=<SIZE> bytes=<N> op=<OP> iters=<N> total_ns=<N> ns_per_op=<N> MBps=<N>
        # Parse with awk to extract just the key fields we want, comma-separated.
        echo "$line" | awk '
          {
            bench=""; size=""; op=""; ns=""; mbps="";
            for (i = 1; i <= NF; i++) {
              if ($i ~ /^bench=/)     { sub(/^bench=/,  "", $i); bench = $i }
              else if ($i ~ /^size=/) { sub(/^size=/,   "", $i); size  = $i }
              else if ($i ~ /^op=/)   { sub(/^op=/,     "", $i); op    = $i }
              else if ($i ~ /^ns_per_op=/) { sub(/^ns_per_op=/, "", $i); ns = $i }
              else if ($i ~ /^MBps=/) { sub(/^MBps=/,   "", $i); mbps  = $i }
            }
            # Use a colon-separated key — none of the field values contain colons.
            print bench ":" size ":" op " " ns " " mbps
          }
        '
        ;;
    esac
  done >> "$WORK/all-samples"
done
echo "" >&2

# Now bucket samples by key (first field of each line).
# Use sed-friendly key in the filename: replace ":" with "_".
while read -r key ns mbps; do
  fname="$WORK/$(echo -n "$key" | tr ':' '_')"
  echo "$ns $mbps" >> "$fname"
done < "$WORK/all-samples"

# For each bucket: compute order statistics.
echo "| bench | size | op | n | p50 ns | p95 ns | p99 ns | IQR ns | p50 MB/s |"
echo "|-------|------|-----|---|--------|--------|--------|--------|----------|"

for sample_file in "$WORK"/*; do
  [ "$(basename "$sample_file")" = "all-samples" ] && continue
  key=$(basename "$sample_file")
  # Reconstruct bench / size / op from the "_"-separated filename.
  bench=$(echo "$key" | awk -F_ '{print $1}')
  size=$(echo  "$key" | awk -F_ '{print $2}')
  op=$(echo    "$key" | awk -F_ '{print $3}')

  sort -n "$sample_file" > "$sample_file.sorted"
  n=$(wc -l < "$sample_file.sorted")
  [ "$n" -lt 1 ] && continue

  # Nearest-rank percentiles.
  pct_line() { echo "$1" | awk -v n="$n" '{print int(($1*n+99)/100)}'; }
  p50_ln=$(pct_line 50); p25_ln=$(pct_line 25); p75_ln=$(pct_line 75)
  p95_ln=$(pct_line 95); p99_ln=$(pct_line 99)

  p50_ns=$(sed -n "${p50_ln}p" "$sample_file.sorted" | awk '{print $1}')
  p25_ns=$(sed -n "${p25_ln}p" "$sample_file.sorted" | awk '{print $1}')
  p75_ns=$(sed -n "${p75_ln}p" "$sample_file.sorted" | awk '{print $1}')
  p95_ns=$(sed -n "${p95_ln}p" "$sample_file.sorted" | awk '{print $1}')
  p99_ns=$(sed -n "${p99_ln}p" "$sample_file.sorted" | awk '{print $1}')
  iqr=$((p75_ns - p25_ns))
  p50_mbps=$(sed -n "${p50_ln}p" "$sample_file.sorted" | awk '{print $2}')

  printf "| %s | %s | %s | %d | %d | %d | %d | %d | %s |\n" \
    "$bench" "$size" "$op" "$n" "$p50_ns" "$p95_ns" "$p99_ns" "$iqr" "$p50_mbps"
done | sort
