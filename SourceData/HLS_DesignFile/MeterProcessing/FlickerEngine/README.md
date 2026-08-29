# FlickerEngine

`FlickerEngine` is the independent IEC 61000-4-15:2010 flickermeter front
end for M18. It consumes converted voltage frames, reduces every supported
ADC profile to a fixed 2 kSPS internal stream, and implements voltage
adaptation, square demodulation, carrier rejection, the 120 V or 230 V
lamp/eye/brain weighting model, squaring, and the 300 ms memory filter.

The engine emits only bounded `FLK1` sufficient statistics. One-second live
packets carry peak `Pinst`. A completed standard 600-second classifier is a
lossless sequence of 35 packets containing all 512 bins for each phase. R5C1
computes the standardized percentiles, `Pst`, and the rolling twelve-value
`Plt`; sample payloads never cross RPMsg.

The testbench pins the published IEC sinusoidal-modulation reference points,
the packet geometry, full histogram reconstruction, APPLY, missing-reference,
and discontinuity behavior. Run it through the repository-wide
`HLS_DesignFile/run_hls.sh FlickerEngine` flow.
