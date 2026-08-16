#!/usr/bin/env bash
# Compile and run the common-header unit test with plain g++ against the
# Vitis csim headers. No Vivado/Vitis tool run or license required.
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VITIS_INC="${XILINX_VITIS:-/opt/Xilinx/2025.2/Vitis}/include"
[[ -f "${VITIS_INC}/ap_int.h" ]] || {
    printf 'Error: %s/ap_int.h not found (set XILINX_VITIS)\n' "${VITIS_INC}" >&2
    exit 1
}

OUT="${HERE}/common_headers_test"
# -Wno-unknown-pragmas / -Wno-unused-label: HLS pragmas and loop labels
# are synthesis idioms with no g++ meaning.
g++ -std=c++14 -Wall -Wextra -O1 \
    -Wno-unknown-pragmas -Wno-unused-label \
    -I"${HERE}/../include" -isystem "${VITIS_INC}" \
    -o "${OUT}" "${HERE}/common_headers_test.cpp"
"${OUT}"
