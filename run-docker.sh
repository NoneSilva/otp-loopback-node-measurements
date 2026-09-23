#!/usr/bin/env bash
# Runs measure.escript inside the official erlang:<version> Docker images and
# saves the output under results/.
#
# Usage: ./run-docker.sh [--bridge] 27 28 29
#   default : --network host  (same interfaces and firewall as the host)
#   --bridge: Docker's default bridge network, i.e. the container's own
#             network namespace: no host firewall rules, no global IPv6
#
# The containers are throwaway (--rm), so MEASURE_EDIT_ETC=1 lets cases 8, 9
# and 23 edit /etc/hosts and the resolver inside them. EPMD_PORT is forwarded.
set -euo pipefail
cd "$(dirname "$0")"
MODE=host; NET=(--network host)
if [ "${1:-}" = "--bridge" ]; then MODE=bridge; NET=(); shift; fi
[ $# -gt 0 ] || { echo "usage: $0 [--bridge] <otp-version>..." >&2; exit 2; }
mkdir -p results
for V in "$@"; do
  OUT="results/otp$V-docker-$MODE.txt"
  echo "== erlang:$V ($MODE) -> $OUT"
  docker run --rm ${NET[@]+"${NET[@]}"} -e MEASURE_EDIT_ETC=1 -e EPMD_PORT="${EPMD_PORT:-4370}" \
    -v "$PWD/measure.escript:/measure.escript:ro" "erlang:$V" escript /measure.escript 2>&1 | tee "$OUT"
done
