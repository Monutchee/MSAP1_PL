# Run full top-level synthesis and emit focused reports for the AD7771 path.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../..]]
open_project [file join $repo_dir vivado_gen MSAP1_PL.xpr]
set_property ip_repo_paths \
    [list [file join $repo_dir SourceData DesignFile Ad7771Capture]] \
    [current_project]
update_ip_catalog

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set run_status [get_property STATUS [get_runs synth_1]]
puts "AD7771_SYNTH_STATUS=$run_status"
if {![string match "*Complete*" $run_status]} {
    error "Top-level synthesis did not complete: $run_status"
}

open_run synth_1
report_utilization -file [file join $repo_dir vivado_gen ad7771_utilization.rpt]
report_timing_summary -file [file join $repo_dir vivado_gen ad7771_timing_summary.rpt]
report_cdc -file [file join $repo_dir vivado_gen ad7771_cdc.rpt]
report_io -file [file join $repo_dir vivado_gen ad7771_io.rpt]
close_project
