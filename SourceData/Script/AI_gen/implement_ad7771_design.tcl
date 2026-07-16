# Place, route, generate the programming image, and export the hardware
# handoff consumed by the RPU Vitis platform.

set script_dir [file dirname [file normalize [info script]]]
set pl_repo_dir [file normalize [file join $script_dir ../..]]
set workspace_dir [file normalize [file join $pl_repo_dir ..]]
set project_file [file join $pl_repo_dir vivado_gen MSAP1_PL.xpr]
set xsa_file [file join $workspace_dir runtime-generated bin_file MSAP1_PL.xsa]

open_project $project_file

set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    error "Top-level synthesis is not complete: $synth_status"
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "AD7771_IMPL_STATUS=$impl_status"
if {![string match "*Complete*" $impl_status]} {
    error "Top-level implementation did not complete: $impl_status"
}

open_run impl_1
report_timing_summary -file \
    [file join $pl_repo_dir vivado_gen ad7771_timing_implemented.rpt]
report_cdc -file [file join $pl_repo_dir vivado_gen ad7771_cdc_implemented.rpt]
report_drc -file [file join $pl_repo_dir vivado_gen ad7771_drc_implemented.rpt]
report_io -file [file join $pl_repo_dir vivado_gen ad7771_io_implemented.rpt]

file mkdir [file dirname $xsa_file]
write_hw_platform -fixed -include_bit -force -file $xsa_file
puts "AD7771_XSA=$xsa_file"
close_project
