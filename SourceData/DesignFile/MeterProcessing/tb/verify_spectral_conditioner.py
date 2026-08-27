#!/usr/bin/env python3
"""Generate and characterize the M16 adaptive L/25 coefficient ROM.

All supported ADC rates are converted to the common 20.48 kframe/s FFT
input rate. The numerator is L = 512000 / Fs and the denominator is always
25. Profiles at and above 32 kSPS share a 1,025-tap prototype on the 512 kHz
interpolation grid. Lower-rate profiles linearly interpolate a compact
129-row fractional-delay table whose passband is limited to 0.4 Fs. The
hardware carries each division remainder from tap to tap, so every
interpolated Q20 phase retains exact unity gain without a correction ROM.

The ROM packs three signed Q20 coefficients into each 63-bit word. Run with
``--write`` after changing the characterized design constants; the default
mode proves that the checked-in image is an exact reproduction.
"""

from __future__ import annotations

import argparse
import cmath
from dataclasses import dataclass
import math
from pathlib import Path


COEFFICIENT_FRAC = 20
COEFFICIENT_BITS = 21
UNITY = 1 << COEFFICIENT_FRAC
COEFFICIENT_MASK = (1 << COEFFICIENT_BITS) - 1
INTERMEDIATE_RATE_HZ = 512_000
KAISER_BETA = 7.8562

LOW_FINE_PHASES = 512
LOW_BASE_INTERVALS = 128
LOW_BASE_ROWS = LOW_BASE_INTERVALS + 1
LOW_FINE_PER_BASE = LOW_FINE_PHASES // LOW_BASE_INTERVALS
LOW_TAPS = 69
LOW_DELAY = 34
LOW_PASSBAND_RATIO = 0.40
LOW_CUTOFF_RATIO = 0.45

HIGH_PROTOTYPE_TAPS = 1025
HIGH_PROTOTYPE_MIDPOINT = 512
HIGH_PASSBAND_HZ = 7_620
HIGH_STOPBAND_HZ = 10_240
HIGH_CUTOFF_HZ = 8_930


@dataclass(frozen=True)
class Profile:
    identifier: int
    rate_hz: int
    numerator: int
    taps: int
    delay: int
    low_table: bool


# Profile 1 remains the deployed 32 kSPS profile identifier. The remaining
# IDs grow upward first, then downward, without changing the record ABI.
PROFILES = (
    Profile(1, 32_000, 16, 65, 32, False),
    Profile(2, 64_000, 8, 129, 64, False),
    Profile(3, 128_000, 4, 257, 128, False),
    Profile(4, 16_000, 32, LOW_TAPS, LOW_DELAY, True),
    Profile(5, 8_000, 64, LOW_TAPS, LOW_DELAY, True),
    Profile(6, 4_000, 128, LOW_TAPS, LOW_DELAY, True),
    Profile(7, 2_000, 256, LOW_TAPS, LOW_DELAY, True),
    Profile(8, 1_000, 512, LOW_TAPS, LOW_DELAY, True),
)


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


def quantize_unity(values: list[float]) -> list[int]:
    total = sum(values)
    normalized = [value / total for value in values]
    quantized = [round(value * UNITY) for value in normalized]
    largest = max(
        range(len(quantized)), key=lambda index: abs(quantized[index])
    )
    quantized[largest] += UNITY - sum(quantized)
    assert sum(quantized) == UNITY
    assert all(
        -(1 << (COEFFICIENT_BITS - 1))
        <= value
        < (1 << (COEFFICIENT_BITS - 1))
        for value in quantized
    )
    return quantized


def generated_low_base_phases() -> list[list[int]]:
    """Build the 129 endpoint-inclusive 1/128-sample base phase rows."""
    window_denominator = bessel_i0(KAISER_BETA)
    phases: list[list[int]] = []
    for phase in range(LOW_BASE_ROWS):
        fraction = phase / LOW_BASE_INTERVALS
        values: list[float] = []
        for tap in range(LOW_TAPS):
            offset = LOW_DELAY - tap - fraction
            if abs(offset) < 1e-15:
                sinc = 2.0 * LOW_CUTOFF_RATIO
            else:
                sinc = math.sin(
                    2.0 * math.pi * LOW_CUTOFF_RATIO * offset
                )
                sinc /= math.pi * offset
            radius = offset / LOW_DELAY
            if abs(radius) <= 1.0:
                window = bessel_i0(
                    KAISER_BETA
                    * math.sqrt(max(0.0, 1.0 - radius * radius))
                ) / window_denominator
            else:
                window = 0.0
            values.append(sinc * window)
        phases.append(quantize_unity(values))
    return phases


def interpolate_low_phase(
    low_base: list[list[int]], fine_phase: int
) -> list[int]:
    """Mirror the tap-ordered, carried-floor interpolator in the RTL."""
    base_index, fraction = divmod(fine_phase, LOW_FINE_PER_BASE)
    first = low_base[base_index]
    second = low_base[base_index + 1]
    remainder = 0
    result: list[int] = []
    for coefficient_a, coefficient_b in zip(first, second, strict=True):
        numerator = (
            coefficient_a * LOW_FINE_PER_BASE
            + (coefficient_b - coefficient_a) * fraction
            + remainder
        )
        coefficient, remainder = divmod(numerator, LOW_FINE_PER_BASE)
        result.append(coefficient)
    assert remainder == 0
    assert sum(result) == UNITY
    return result


def generated_high_phases(profile: Profile) -> list[list[int]]:
    normalized_cutoff = HIGH_CUTOFF_HZ / INTERMEDIATE_RATE_HZ
    window_denominator = bessel_i0(KAISER_BETA)
    prototype: list[float] = []
    for index in range(HIGH_PROTOTYPE_TAPS):
        offset = index - HIGH_PROTOTYPE_MIDPOINT
        if offset == 0:
            sinc = 2.0 * normalized_cutoff
        else:
            sinc = math.sin(
                2.0 * math.pi * normalized_cutoff * offset
            )
            sinc /= math.pi * offset
        radius = offset / HIGH_PROTOTYPE_MIDPOINT
        window = bessel_i0(
            KAISER_BETA
            * math.sqrt(max(0.0, 1.0 - radius * radius))
        ) / window_denominator
        prototype.append(profile.numerator * sinc * window)

    phases: list[list[int]] = []
    for phase in range(profile.numerator):
        values = prototype[phase::profile.numerator]
        coefficients = quantize_unity(values)
        coefficients.extend([0] * (profile.taps - len(coefficients)))
        phases.append(coefficients)
    return phases


def generated_tables() -> dict[int, list[list[int]]]:
    low_base = generated_low_base_phases()
    tables: dict[int, list[list[int]]] = {}
    for profile in PROFILES:
        if profile.low_table:
            stride = LOW_FINE_PHASES // profile.numerator
            tables[profile.identifier] = [
                interpolate_low_phase(low_base, phase * stride)
                for phase in range(profile.numerator)
            ]
        else:
            tables[profile.identifier] = generated_high_phases(profile)
    return tables


def packed_words(tables: dict[int, list[list[int]]]) -> list[int]:
    words: list[int] = []

    # Store only the 129 endpoint-inclusive 1/128-sample base rows. The RTL
    # interpolates the 512 fine phases while retaining exact Q20 unity gain.
    # Each phase occupies 23 words and begins on a word boundary.
    for coefficients in generated_low_base_phases():
        for start in range(0, LOW_TAPS, 3):
            word = 0
            for slot, coefficient in enumerate(
                coefficients[start : start + 3]
            ):
                word |= (coefficient & COEFFICIENT_MASK) << (
                    slot * COEFFICIENT_BITS
                )
            words.append(word)

    # High-rate phase rows are independently padded to a multiple of three.
    for profile in PROFILES[:3]:
        padded_taps = ((profile.taps + 2) // 3) * 3
        for coefficients in tables[profile.identifier]:
            row = coefficients + [0] * (padded_taps - len(coefficients))
            for start in range(0, padded_taps, 3):
                word = 0
                for slot, coefficient in enumerate(row[start : start + 3]):
                    word |= (coefficient & COEFFICIENT_MASK) << (
                        slot * COEFFICIENT_BITS
                    )
                words.append(word)
    return words


def load_words(path: Path) -> list[int]:
    return [
        int(line.strip(), 16)
        for line in path.read_text().splitlines()
        if line.strip()
    ]


def db(value: float) -> float:
    return 20.0 * math.log10(max(value, 1e-30))


def response_metrics(
    profile: Profile, phases: list[list[int]]
) -> tuple[float, float, float | None]:
    passband_hz = (
        int(profile.rate_hz * LOW_PASSBAND_RATIO)
        if profile.low_table
        else HIGH_PASSBAND_HZ
    )
    passband_main: list[float] = []
    worst_image_bound = 0.0

    # Dense enough to catch the smooth Kaiser extrema while keeping this
    # dependency-free verifier practical for every focused build.
    for point in range(321):
        frequency_hz = passband_hz * point / 320.0
        omega = 2.0 * math.pi * frequency_hz / profile.rate_hz
        gains: list[complex] = []
        for phase, coefficients in enumerate(phases):
            gain = 0j
            for tap, coefficient in enumerate(coefficients):
                source_offset = (
                    profile.delay - tap - phase / profile.numerator
                )
                gain += (coefficient / UNITY) * cmath.exp(
                    1j * omega * source_offset
                )
            gains.append(gain)
        main = abs(sum(gains) / profile.numerator)
        passband_main.append(main)
        total_power = (
            sum(abs(gain) ** 2 for gain in gains) / profile.numerator
        )
        worst_image_bound = max(
            worst_image_bound,
            math.sqrt(max(0.0, total_power - main * main)),
        )

    ripple_db = db(max(passband_main) / min(passband_main))
    stopband = None
    if not profile.low_table:
        worst_stopband = 0.0
        for point in range(321):
            frequency_hz = HIGH_STOPBAND_HZ + (
                profile.rate_hz / 2 - HIGH_STOPBAND_HZ
            ) * point / 320.0
            omega = 2.0 * math.pi * frequency_hz / profile.rate_hz
            gains = []
            for phase, coefficients in enumerate(phases):
                gain = sum(
                    (coefficient / UNITY)
                    * cmath.exp(
                        1j
                        * omega
                        * (
                            profile.delay
                            - tap
                            - phase / profile.numerator
                        )
                    )
                    for tap, coefficient in enumerate(coefficients)
                )
                gains.append(gain)
            mean = abs(sum(gains) / profile.numerator)
            total_power = (
                sum(abs(gain) ** 2 for gain in gains)
                / profile.numerator
            )
            worst_stopband = max(
                worst_stopband, math.sqrt(total_power), mean
            )
        stopband = worst_stopband
    return ripple_db, worst_image_bound, stopband


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--write",
        action="store_true",
        help="replace the ROM image with the characterized design",
    )
    args = parser.parse_args()

    rom_path = Path(__file__).resolve().parent.parent / (
        "meter_spectral_conditioner_q20.mem"
    )
    tables = generated_tables()
    expected_words = packed_words(tables)
    if args.write:
        rom_path.write_text(
            "".join(f"{word:016x}\n" for word in expected_words),
            encoding="ascii",
        )
    actual_words = load_words(rom_path)
    assert actual_words == expected_words, (
        "coefficient ROM does not match the adaptive characterized design; "
        "run verify_spectral_conditioner.py --write"
    )
    assert len(actual_words) == 4_007

    summaries: list[str] = []
    for profile in PROFILES:
        phases = tables[profile.identifier]
        assert len(phases) == profile.numerator
        assert all(len(row) == profile.taps for row in phases)
        assert all(sum(row) == UNITY for row in phases)
        ripple, image_bound, stopband = response_metrics(profile, phases)
        assert ripple <= 0.0021, (
            f"profile {profile.identifier} ripple {ripple:.6f} dB"
        )
        assert image_bound <= 8.0e-5, (
            f"profile {profile.identifier} image bound "
            f"{db(image_bound):.2f} dBFS"
        )
        if stopband is not None:
            assert stopband <= 1.5e-4, (
                f"profile {profile.identifier} stopband "
                f"{db(stopband):.2f} dBFS"
            )
        detail = (
            f"P{profile.identifier} {profile.rate_hz // 1000}k "
            f"L={profile.numerator}: ripple {ripple:.6f} dB, "
            f"image bound {db(image_bound):.2f} dBFS"
        )
        if stopband is not None:
            detail += f", stopband {db(stopband):.2f} dBFS"
        summaries.append(detail)

    print("meter_spectral_conditioner adaptive response PASS")
    for summary in summaries:
        print(f"  {summary}")


if __name__ == "__main__":
    main()
