# A4 harmonic-engine sizing prototype

This directory answers the resource question that must be settled before the
M15 harmonic engine is integrated. It is not production RTL and is not added to
`MeterCore`, `TopDesign.bd`, the record stream, RPU configuration, or Linux.

The prototype contains:

- two ping/pong seven-channel sample-window buffers implemented with AMD XPM
  block memory;
- one shared Q1.17 Hann coefficient ROM;
- a channel scheduler that serializes CH0 through CH6;
- one shared AMD/Xilinx FFT v9.1 core using the area-oriented radix-2-lite
  burst architecture; and
- zero padding from the exact ten-cycle sample count to the FFT power of two.

CH7 is deliberately excluded. Samples are normalized signed 24-bit values,
matching the ADC information content. M15 must specify the production
normalization and bin calibration before integration.

Run both K26 out-of-context synthesis cases with:

```sh
SourceData/Prototype/HarmonicSizing/run_harmonic_sizing.sh
```

Reports are written to:

```text
vivado_gen/a4_harmonic_sizing/4k/
vivado_gen/a4_harmonic_sizing/32k/
```

The cases are:

| Case | Analysis rate | Exact 10-cycle window | FFT |
| --- | ---: | ---: | ---: |
| Decimated | 16 kSPS | 3,200 samples at 50 Hz | 4,096 |
| Undecimated | 128 kSPS | 25,600 samples at 50 Hz | 32,768 |

The 16 kSPS production path will require a metrology-qualified anti-alias
filter before decimation. This prototype intentionally does not size that
filter: A4 compares the window/scheduler/FFT storage choice, and a bare
sample-drop decimator must not be promoted into M15.

## Synthesis results

Both variants were synthesized against `xck26-sfvc784-2LV-c` with Vivado
2025.2. The figures below are post-synthesis estimates for the complete
standalone prototype: two sample-window banks, the Hann ROM, scheduler, and
one shared FFT core.

| Case | LUT | FF | BRAM tiles | DSP | 100 MHz WNS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 16 kSPS / 4K FFT | 965 | 1,593 | 47 | 5 | +6.573 ns |
| 128 kSPS / 32K FFT | 1,522 | 2,018 | 310 | 5 | +5.906 ns |

For the 4K case, the FFT accounts for 744 LUT, 1,465 FF, seven equivalent
BRAM tiles (one RAMB36 plus twelve RAMB18), and four DSPs. The two XPM window
banks and Hann ROM account for the remaining 40 BRAM tiles. The frontend uses
one DSP for the shared window multiply.

For the 32K case, the FFT alone uses 54 BRAM tiles and the frontend storage
uses 256. Vivado reports BRAM over-utilization during synthesis, and the total
is 310 of the K26's 144 tiles (215.28%). Positive synthesized timing therefore
does not make this variant implementable.

## A4 decision

M15 must use the shared 16 kSPS / 4K FFT architecture. On the current routed
A3 K26 baseline, adding this isolated prototype gives a rough pre-integration
total of 78,000 LUT, 114,995 FF, 105.5 BRAM tiles, and 410 DSPs. That leaves
BRAM—not arithmetic—as the binding resource for the production harmonic
classifier, record buffers, and anti-alias path.

This is a sizing decision, not permission to drop input samples. M15 must add
a metrology-qualified anti-alias filter before decimation and must re-run the
full implementation resource/timing gate. A5 must independently re-baseline
the design and this prototype against the intended K24 part before the SOM
choice is closed.
