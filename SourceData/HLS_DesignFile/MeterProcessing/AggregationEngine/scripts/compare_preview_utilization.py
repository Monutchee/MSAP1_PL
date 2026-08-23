#!/usr/bin/env python3
"""Compare AggregationEngine preview-enabled and preview-disabled reports.

The HLS comparison is always available.  Vivado utilization reports are
optional because producing each one requires repackaging the selected HLS IP
and synthesizing the complete design with identical constraints.
"""

from __future__ import annotations

import argparse
import pathlib
import re
from collections.abc import Mapping


HLS_METRICS = ("BRAM_18K", "DSP", "FF", "LUT", "URAM")
VIVADO_ROWS = {
    "LUT": "CLB LUTs",
    "LUTRAM": "LUT as Memory",
    "FF": "CLB Registers",
    "BRAM": "Block RAM Tile",
    "DSP": "DSPs",
    "CLB": "CLB",
    "CONTROL_SETS": "Unique Control Sets",
}


def parse_number(text: str) -> float:
    return float(text.replace(",", ""))


def parse_hls(path: pathlib.Path) -> tuple[dict[str, float], dict[str, float]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    section = text.split("== Utilization Estimates", 1)[-1].split("+ Detail:", 1)[0]
    total = re.search(
        r"^\|Total\s*\|\s*([0-9.]+)\|\s*([0-9.]+)\|\s*([0-9.]+)"
        r"\|\s*([0-9.]+)\|\s*([0-9.]+)\|",
        section,
        re.MULTILINE,
    )
    available = re.search(
        r"^\|Available\s*\|\s*([0-9.]+)\|\s*([0-9.]+)\|\s*([0-9.]+)"
        r"\|\s*([0-9.]+)\|\s*([0-9.]+)\|",
        section,
        re.MULTILINE,
    )
    if total is None or available is None:
        raise ValueError(f"cannot find HLS utilization totals in {path}")
    return (
        dict(zip(HLS_METRICS, map(parse_number, total.groups()), strict=True)),
        dict(zip(HLS_METRICS, map(parse_number, available.groups()), strict=True)),
    )


def parse_vivado(path: pathlib.Path) -> tuple[dict[str, float], dict[str, float]]:
    used: dict[str, float] = {}
    available: dict[str, float] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        cells = [cell.strip() for cell in line.split("|")]
        if len(cells) < 7:
            continue
        name = cells[1].rstrip("*")
        for metric, row in VIVADO_ROWS.items():
            if name == row and metric not in used:
                used[metric] = parse_number(cells[2])
                available[metric] = parse_number(cells[5])
    if not used:
        raise ValueError(f"cannot find Vivado utilization rows in {path}")
    return used, available


def format_value(value: float) -> str:
    return str(int(value)) if value.is_integer() else f"{value:g}"


def table(
    title: str,
    enabled: Mapping[str, float],
    disabled: Mapping[str, float],
    available: Mapping[str, float],
) -> list[str]:
    lines = [
        f"## {title}",
        "",
        "| Resource | Previews enabled | Previews disabled | Preview cost | Device cost |",
        "|---|---:|---:|---:|---:|",
    ]
    preferred_order = (
        "LUT",
        "LUTRAM",
        "FF",
        "BRAM_18K",
        "BRAM",
        "DSP",
        "CLB",
        "CONTROL_SETS",
        "URAM",
    )
    metrics = [
        metric
        for metric in preferred_order
        if metric in enabled or metric in disabled
    ]
    metrics.extend(
        sorted((enabled.keys() | disabled.keys()) - set(metrics))
    )
    for metric in metrics:
        on = enabled.get(metric, 0.0)
        off = disabled.get(metric, 0.0)
        delta = on - off
        capacity = available.get(metric, 0.0)
        device_cost = f"{100.0 * delta / capacity:.2f}%" if capacity else "n/a"
        lines.append(
            f"| {metric} | {format_value(on)} | {format_value(off)} | "
            f"{format_value(delta)} | {device_cost} |"
        )
    lines.append("")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hls-enabled", type=pathlib.Path, required=True)
    parser.add_argument("--hls-disabled", type=pathlib.Path, required=True)
    parser.add_argument("--vivado-enabled", type=pathlib.Path)
    parser.add_argument("--vivado-disabled", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()

    hls_on, hls_available = parse_hls(args.hls_enabled)
    hls_off, _ = parse_hls(args.hls_disabled)
    lines = ["# AggregationEngine live-preview utilization comparison", ""]
    lines += table("Vitis HLS estimates", hls_on, hls_off, hls_available)

    if bool(args.vivado_enabled) != bool(args.vivado_disabled):
        parser.error("--vivado-enabled and --vivado-disabled must be supplied together")
    if args.vivado_enabled and args.vivado_disabled:
        vivado_on, vivado_available = parse_vivado(args.vivado_enabled)
        vivado_off, _ = parse_vivado(args.vivado_disabled)
        lines += table("Vivado design utilization", vivado_on, vivado_off, vivado_available)

    output = "\n".join(lines)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n", encoding="utf-8")
    else:
        print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
