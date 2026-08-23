# PL build stage 2: implementation through route_design.
#
# Resets impl_1 and runs it to route_design only. The bitstream is a separate
# stage (build_bitstream.tcl) so a routed design can be reviewed -- timing,
# CDC, DRC, I/O -- before it is programmed, and so a bitstream rerun never
# discards the routing.
#
# Debug/standalone use (see build_common.tcl for the GUI rule):
#   vivado -mode batch -source SourceData/Script/build_impl.tcl -tclargs 1 16
#   source SourceData/Script/build_impl.tcl   ;# Vivado Tcl console
#
# Optional -tclargs <jobs> <threads>; otherwise VIVADO_JOBS and
# VIVADO_THREADS, with defaults of 8 for each.
#
# PL_INCREMENTAL=1 reuses the previous routed checkpoint for place and route
# (see pl_build_apply_incremental). Off by default: the result then depends on
# build history, so it is an iteration aid, not how a release is built.

source [file join [file dirname [file normalize [info script]]] build_common.tcl]

pl_build_open_project
pl_build_require_run_complete synth_1 "mnc PL build --compile-synth"

set jobs [pl_build_jobs]
set threads [pl_build_threads]
puts "PL_BUILD_STAGE=impl"
puts "PL_BUILD_JOBS=$jobs"
puts "PL_BUILD_THREADS=$threads"

pl_build_apply_incremental impl_1

pl_build_reset_run impl_1
pl_build_launch_with_threads impl_1 route_design $jobs $threads OPT_DESIGN

set routed [file join [pl_build_run_dir impl_1] "[pl_build_top]_routed.dcp"]
if {![file exists $routed]} {
    error "implementation reported success but $routed is missing"
}
puts "PL_BUILD_ROUTED=$routed"

pl_build_write_reports impl_1 [list \
    impl_utilization              {report_utilization} \
    impl_utilization_hierarchical {report_utilization -hierarchical -hierarchical_depth 5} \
    impl_congestion               {report_design_analysis -congestion} \
    impl_control_sets             {report_control_sets -verbose} \
    impl_timing_summary           {report_timing_summary} \
    impl_cdc                      {report_cdc} \
    impl_drc                      {report_drc} \
    impl_io                       {report_io} \
]

pl_build_utilization_summary [file join $pl_build_report_dir impl_utilization.rpt]
puts "PL_BUILD_REPORT_HIERARCHY=[file join $pl_build_report_dir impl_utilization_hierarchical.rpt]"
puts "PL_BUILD_REPORT_CONTROL_SETS=[file join $pl_build_report_dir impl_control_sets.rpt]"
pl_build_timing_verdict impl_1
pl_build_message_summary impl_1

puts "PL_BUILD_STAGE_COMPLETE=impl"
pl_build_close_project
