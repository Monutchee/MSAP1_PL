#!/usr/bin/env python3
"""Reproduce and characterize the M16 16/25 polyphase coefficient ROM."""

from __future__ import annotations

import cmath
import math
from pathlib import Path


PHASES = 16
PHASE_TAPS = 65
PROTOTYPE_TAPS = 1025
PROTOTYPE_MIDPOINT = 512
SOURCE_RATE_HZ = 32_000
OUTPUT_RATE_HZ = 20_480
PASSBAND_HZ = 7_620
STOPBAND_HZ = 10_240
CUTOFF_HZ = 8_930
KAISER_BETA = 7.8562
COEFFICIENT_FRAC = 20
COEFFICIENT_BITS = 21
RATE_DENOMINATOR = 25


def bessel_i0(value: float) -> float:
    total = 1.0
    term = 1.0
    quarter_square = value * value / 4.0
    index = 1
    while True:
        term *= quarter_square / (index * index)
        total += term
        if abs(term) < 1e-18 * abs(total):
            return total
        index += 1


def generated_phases() -> list[list[int]]:
    upsampled_rate = SOURCE_RATE_HZ * PHASES
    normalized_cutoff = CUTOFF_HZ / upsampled_rate
    window_denominator = bessel_i0(KAISER_BETA)
    prototype: list[float] = []

    for index in range(PROTOTYPE_TAPS):
        offset = index - PROTOTYPE_MIDPOINT
        if offset == 0:
            sinc = 2.0 * normalized_cutoff
        else:
            sinc = math.sin(2.0 * math.pi * normalized_cutoff * offset)
            sinc /= math.pi * offset
        radius = offset / PROTOTYPE_MIDPOINT
        window = bessel_i0(
            KAISER_BETA * math.sqrt(max(0.0, 1.0 - radius * radius))
        ) / window_denominator
        prototype.append(PHASES * sinc * window)

    phases: list[list[int]] = []
    unity = 1 << COEFFICIENT_FRAC
    for phase in range(PHASES):
        coefficients = prototype[phase::PHASES]
        phase_sum = sum(coefficients)
        normalized = [coefficient / phase_sum for coefficient in coefficients]
        quantized = [round(coefficient * unity) for coefficient in normalized]
        largest = max(range(len(quantized)), key=lambda i: abs(quantized[i]))
        quantized[largest] += unity - sum(quantized)
        quantized.extend([0] * (PHASE_TAPS - len(quantized)))
        phases.append(quantized)
    return phases


def load_rom(path: Path) -> list[list[int]]:
    encoded = [int(line.strip(), 16) for line in path.read_text().splitlines()
               if line.strip()]
    assert len(encoded) == PHASES * PHASE_TAPS, (
        f"expected {PHASES * PHASE_TAPS} ROM words, found {len(encoded)}"
    )
    sign = 1 << (COEFFICIENT_BITS - 1)
    modulus = 1 << COEFFICIENT_BITS
    decoded = [word - modulus if word & sign else word for word in encoded]
    return [decoded[start:start + PHASE_TAPS]
            for start in range(0, len(decoded), PHASE_TAPS)]


def response_components(phases: list[list[int]], frequency_hz: int) -> list[complex]:
    omega = 2.0 * math.pi * frequency_hz / SOURCE_RATE_HZ
    unity = float(1 << COEFFICIENT_FRAC)
    periodic_gain: list[complex] = []

    # m*25 mod 16 visits every phase once.  The exponent removes the ideal
    # output phase, leaving one period of gain/error modulation.
    for output_index in range(PHASES):
        phase = output_index * RATE_DENOMINATOR % PHASES
        gain = 0j
        for tap, coefficient in enumerate(phases[phase]):
            source_offset = 32.0 - tap - phase / PHASES
            gain += (coefficient / unity) * cmath.exp(1j * omega * source_offset)
        periodic_gain.append(gain)

    components: list[complex] = []
    for image in range(PHASES):
        component = 0j
        for index, gain in enumerate(periodic_gain):
            component += gain * cmath.exp(
                -2j * math.pi * image * index / PHASES
            )
        components.append(component / PHASES)
    return components


def db(value: float) -> float:
    return 20.0 * math.log10(max(value, 1e-30))


def main() -> None:
    rom_path = Path(__file__).resolve().parent.parent / (
        "meter_spectral_conditioner_q20.mem"
    )
    phases = load_rom(rom_path)
    expected = generated_phases()
    assert phases == expected, "coefficient ROM does not match the frozen design"
    assert all(sum(phase) == 1 << COEFFICIENT_FRAC for phase in phases), (
        "every phase must have exact unity DC gain"
    )

    passband_main: list[float] = []
    worst_passband_image = 0.0
    for frequency in range(PASSBAND_HZ + 1):
        components = response_components(phases, frequency)
        passband_main.append(abs(components[0]))
        worst_passband_image = max(
            worst_passband_image, *(abs(component) for component in components[1:])
        )

    worst_stopband_component = 0.0
    for frequency in range(STOPBAND_HZ, SOURCE_RATE_HZ // 2 + 1):
        components = response_components(phases, frequency)
        worst_stopband_component = max(
            worst_stopband_component, *(abs(component) for component in components)
        )

    minimum_gain = min(passband_main)
    maximum_gain = max(passband_main)
    ripple_db = db(maximum_gain / minimum_gain)

    assert ripple_db <= 0.002, f"passband ripple {ripple_db:.6f} dB"
    assert worst_passband_image <= 2.0e-5, (
        f"passband image {db(worst_passband_image):.2f} dBFS"
    )
    assert worst_stopband_component <= 1.2e-4, (
        f"stopband component {db(worst_stopband_component):.2f} dBFS"
    )

    print(
        "meter_spectral_conditioner response PASS: "
        f"0-{PASSBAND_HZ} Hz ripple {ripple_db:.6f} dB, "
        f"worst passband image {db(worst_passband_image):.2f} dBFS, "
        f"{STOPBAND_HZ}-{SOURCE_RATE_HZ // 2} Hz worst component "
        f"{db(worst_stopband_component):.2f} dBFS"
    )


if __name__ == "__main__":
    main()
