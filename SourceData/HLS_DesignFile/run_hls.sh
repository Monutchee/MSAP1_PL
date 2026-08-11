#!/usr/bin/env bash
# Component-local development loop for ONE Vitis HLS component:
# C simulation -> C synthesis -> C/RTL co-simulation -> IP packaging via
# the vitis-run/v++ CLI, then unpack the packaged IP into ip_repo/<name>.
#
# Shared by every component under this tree -- nothing is per-component:
# the name and work directory come from the component's vitis-comp.json,
# the synthesis top from its cfg file, and the packaged archive from the
# build output. Adding a new HLS component needs no new script.
#
# This is the quick iteration tool; it drives the raw HLS CLI, so it works
# even while a Vitis GUI holds the workspace lock. make_HLS.sh is the
# system flow: all components through the Vitis workspace API plus the
# Vivado IP-catalog refresh. After this script, let Vivado pick up the new
# revision with Script/AI_gen/refresh_hls_ip.tcl (sourced in the GUI's Tcl
# console when the project is open there).
#
# Usage: run_hls.sh [component-dir]
#   component-dir  Path to a component directory (holds vitis-comp.json).
#                  Optional when the current directory is inside one.
set -Eeuo pipefail

HLS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

resolve_component() {
    local candidate="$1"
    [[ -d "${candidate}" ]] || return 1
    candidate="$(cd -- "${candidate}" && pwd -P)"
    while [[ "${candidate}" == "${HLS_ROOT}"/* ]]; do
        if [[ -f "${candidate}/vitis-comp.json" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
        candidate="$(dirname -- "${candidate}")"
    done
    return 1
}

case "$#" in
    0)
        COMPONENT_DIR="$(resolve_component "${PWD}")" || \
            die "not inside an HLS component; pass the component directory"
        ;;
    1)
        COMPONENT_DIR="$(resolve_component "$1")" || \
            die "no vitis-comp.json at or above '$1' inside ${HLS_ROOT}"
        ;;
    *)
        die "usage: run_hls.sh [component-dir]"
        ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 is required"
NAME="$(python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["name"])' \
    "${COMPONENT_DIR}/vitis-comp.json")"
WORK_DIR="$(python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["configuration"]["work_dir"])' \
    "${COMPONENT_DIR}/vitis-comp.json")"

CFG="${COMPONENT_DIR}/hls_config.cfg"
[[ -f "${CFG}" ]] || die "missing ${CFG}"
SYN_TOP="$(sed -n 's/^[[:space:]]*syn\.top[[:space:]]*=[[:space:]]*//p' \
    "${CFG}" | head -n 1)"
[[ -n "${SYN_TOP}" ]] || die "${CFG} does not set syn.top"

XILINX_VITIS="${XILINX_VITIS:-/opt/Xilinx/2025.2/Vitis}"
# The vendor settings script reads variables that may be unset; suspend
# nounset around it.
set +u
# shellcheck disable=SC1091
source "${XILINX_VITIS}/settings64.sh"
set -u

cd -- "${COMPONENT_DIR}"
vitis-run --mode hls --csim --config "${CFG}" --work_dir "${WORK_DIR}"
v++ -c --mode hls --config "${CFG}" --work_dir "${WORK_DIR}"
vitis-run --mode hls --cosim --config "${CFG}" --work_dir "${WORK_DIR}"
vitis-run --mode hls --package --config "${CFG}" --work_dir "${WORK_DIR}"

shopt -s nullglob
ARCHIVES=("${WORK_DIR}"/hls/impl/ip/*.zip)
shopt -u nullglob
((${#ARCHIVES[@]} == 1)) || \
    die "expected exactly one packaged IP archive in ${WORK_DIR}/hls/impl/ip"
REPORT="${WORK_DIR}/hls/syn/report/${SYN_TOP}_csynth.rpt"
[[ -f "${REPORT}" ]] || die "missing synthesis report ${REPORT}"

REPO_ENTRY="${HLS_ROOT}/ip_repo/${NAME}"
rm -rf -- "${REPO_ENTRY}.tmp"
mkdir -p -- "${REPO_ENTRY}.tmp"
unzip -q "${ARCHIVES[0]}" -d "${REPO_ENTRY}.tmp"
[[ -f "${REPO_ENTRY}.tmp/component.xml" ]] || \
    die "${ARCHIVES[0]} is not a packaged IP (no component.xml)"
cp -- "${REPORT}" "${REPO_ENTRY}.tmp/"
rm -rf -- "${REPO_ENTRY}"
mv -- "${REPO_ENTRY}.tmp" "${REPO_ENTRY}"

echo "${NAME} HLS flow PASS; IP repository entry refreshed:"
echo "  ${REPO_ENTRY}"
echo "Pick it up in Vivado with Script/AI_gen/refresh_hls_ip.tcl (or make_HLS.sh)."
