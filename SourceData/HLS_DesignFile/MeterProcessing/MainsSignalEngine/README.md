# MainsSignalEngine

`MainsSignalEngine` is the M18 dedicated narrowband estimator for one
configured mains-signalling carrier. It evaluates voltage phases A/B/C with
seven synchronous-correlation probes over the fixed 200 ms observation
window. Five probes cover the configured passband and two measure adjacent
background; the implementation does not instantiate or reuse the harmonic
FFT pipeline.

The engine emits one bounded 20-word `MCS1` payload per observation. It carries
the configured and measured carrier frequency, per-phase carrier magnitude and
background in microvolts, exact sample anchors, validity/detection masks,
configuration generation, and discontinuity/arithmetic provenance. R5C1 owns
the final 256-byte `MAINS-SIGNAL-v1` record.

The testbench uses an independent double-precision source model at every
supported acquisition rate for which the default 1 kHz carrier is below
Nyquist. It also covers in-band detuning, adjacent-tone rejection, APPLY,
sample gaps, and the 2 kSPS Nyquist boundary. Run it through
`HLS_DesignFile/run_hls.sh MainsSignalEngine`.
