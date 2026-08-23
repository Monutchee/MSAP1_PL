# AggregationEngine preview utilization comparison

`MNC_AGGREGATION_ENABLE_OPEN_PREVIEWS` is a synthesis-time diagnostic switch.
The production value is `1`; setting it to `0` removes only the non-normative
open 10-minute and 2-hour records. Completed measurement records and their
sequence spaces are unchanged.

To perform an A/B measurement:

1. Build the component with the macro set to `1` in both `syn.cflags` and
   `tb.cflags`, and preserve its HLS and Vivado utilization reports.
2. Build the identical sources and constraints with the macro set to `0`, and
   preserve those reports separately.
3. Restore the macro to `1` before packaging the production IP.
4. Compare the reports:

```sh
python3 scripts/compare_preview_utilization.py \
  --hls-enabled preview-enabled-csynth.rpt \
  --hls-disabled preview-disabled-csynth.rpt \
  --vivado-enabled preview-enabled-utilization.rpt \
  --vivado-disabled preview-disabled-utilization.rpt \
  --output preview-utilization-comparison.md
```

The C test bench accepts `MNC_COMPLETED_RECORD_TRACE=/path/to/trace.bin`. It
writes every completed record, excluding open previews, in stream order. The
preview-enabled and preview-disabled traces must be byte-identical.

Vivado's paired reports must come from the same source revision, part,
constraints, and implementation strategy. HLS estimates alone do not prove a
physical-CLB reduction.
