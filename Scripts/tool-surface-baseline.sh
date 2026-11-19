#!/usr/bin/env bash
set -euo pipefail
# cross-process stability probe for the tool surface (T0 step 3).
#
# runs the inventory suite three times — three separate processes — and greps
# the `TOOL-SURFACE-BASELINE` lines out of each run. a variant whose sha is
# identical across all three runs is byte-stable across processes; more than
# one distinct sha is the F2 measurement, recorded verbatim in §0. the suite's
# own verdict (step 2's expected red) is not this script's concern.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for i in 1 2 3; do
    swift test --filter ToolSurfaceInventoryTests 2>&1 \
        | grep 'TOOL-SURFACE-BASELINE' > "$work/run-$i.txt" || true
done
for variant in builtin plugin; do
    distinct="$(grep -h "variant=$variant" "$work"/run-*.txt 2>/dev/null \
        | grep -o 'sha=[0-9a-f]*' | sort -u | wc -l | tr -d ' ' || true)"
    echo "variant=$variant distinct_shas=$distinct   # 1 = byte-stable across processes"
done
