# PL build stage 1: top-level synthesis.
#
# Resets synth_1 so the stage always synthesizes the current sources, then
# launches it. Vivado launches the out-of-context block-design and IP runs
# synth_1 depends on, so no separate stage is needed for them; make_HLS.sh
# and refresh_hls_ip.tcl remain responsible for pointing the project at the
# newest packaged HLS revision beforehand.
#
# Debug/standalone use (see build_common.tcl for the GUI rule):
#   vivado -mode batch -source SourceData/Script/build_synth.tcl -tclargs 16
#   source SourceData/Script/build_synth.tcl   ;# Vivado Tcl console
#
# Optional -tclargs <jobs>; otherwise VIVADO_JOBS, otherwise 8.

source [file join [file dirname [file normalize [info script]]] build_common.tcl]

pl_build_open_project

set jobs [pl_build_jobs]
puts "PL_BUILD_STAGE=synth"
puts "PL_BUILD_JOBS=$jobs"

reset_run synth_1
launch_runs synth_1 -jobs $jobs
pl_build_finish_run synth_1

set checkpoint [file join [pl_build_run_dir synth_1] "[pl_build_top].dcp"]
if {![file exists $checkpoint]} {
    error "synthesis reported success but $checkpoint is missing"
}
puts "PL_BUILD_CHECKPOINT=$checkpoint"

pl_build_write_reports synth_1 [list \
    synth_utilization    {report_utilization} \
    synth_timing_summary {report_timing_summary} \
    synth_cdc            {report_cdc} \
]

puts "PL_BUILD_STAGE_COMPLETE=synth"
pl_build_close_project
