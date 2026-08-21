# PL build stage 1: top-level synthesis.
#
# Resets synth_1 so the stage always synthesizes the current sources, then
# launches it. Vivado launches the out-of-context block-design and IP runs
# synth_1 depends on, so no separate stage is needed for them; 'mnc HLS build'
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

# An HLS rebuild leaves the packaged IP's customization trailing its definition
# and therefore locked. Repair it here too, so this stage is correct on its own
# and not only after build_bd.tcl.
pl_build_refresh_hls_ips

# A locked IP cannot be generated and its out-of-context run will not launch,
# so synthesis is certain to fail -- minutes later, deep in whatever module
# reference instantiates it, naming neither the IP nor the revision. Refuse now.
set locked [pl_build_locked_ips]
if {[llength $locked] > 0} {
    error "locked IP customization(s) cannot be synthesized: $locked --\
 upgrade them (report_ip_status), then rerun; a packaged HLS IP is repaired by\
 'mnc HLS build'"
}

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

pl_build_utilization_summary [file join $pl_build_report_dir synth_utilization.rpt]
pl_build_estimated_wns [file join $pl_build_report_dir synth_timing_summary.rpt]
pl_build_message_summary synth_1

puts "PL_BUILD_STAGE_COMPLETE=synth"
pl_build_close_project
