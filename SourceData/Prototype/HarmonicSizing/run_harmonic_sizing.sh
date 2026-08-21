#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for variant in 4k 32k; do
    vivado -mode batch -nolog -nojournal -notrace \
        -source "${script_dir}/run_harmonic_sizing.tcl" \
        -tclargs "${variant}"
done

echo "A4 sizing reports are under vivado_gen/a4_harmonic_sizing/{4k,32k}."
