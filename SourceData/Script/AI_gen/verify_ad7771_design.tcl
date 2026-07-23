# Refresh the maintained VHDL sources, validate TopDesign, and regenerate its
# managed VHDL wrapper. TopDesign is the only block design; MeterCore_Wrapper
# is the only metering module-reference boundary.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../../..]]
set project_file [file join $repo_dir vivado_gen MSAP1_PL.xpr]
set design_dir [file join $repo_dir SourceData DesignFile]

open_project $project_file
set_property TARGET_LANGUAGE VHDL [current_project]
set_property SIMULATOR_LANGUAGE Mixed [current_project]

set obsolete_sources [list \
    [file join $design_dir Ad7771Capture ad7771_receiver.sv] \
    [file join $design_dir Ad7771Capture ad7771_axi_regs.sv] \
    [file join $design_dir Ad7771Capture ad7771_capture.sv] \
    [file join $design_dir Ad7771Capture Ad7771Capture_Wrapper.v] \
    [file join $design_dir HeatBeat_Controller HeatBeat_Controller.sv] \
    [file join $design_dir HeatBeat_Controller HeatBeat_Wrapper.v] \
    [file join $design_dir MeterCore meter_frame_fifo.vhd] \
    [file join $design_dir MeterProcessing CurrentRms_Wrapper.vhd] \
    [file join $design_dir MeterProcessing voltage_rms.vhd]]
foreach obsolete_source $obsolete_sources {
    set obsolete_file [get_files -quiet $obsolete_source]
    if {[llength $obsolete_file] != 0} {
        remove_files $obsolete_file
    }
}

set vhdl2008_sources [list \
    [file join $design_dir HeatBeat_Controller HeatBeat_Controller.vhd] \
    [file join $design_dir MeterCommon metering_pkg.vhd] \
    [file join $design_dir Ad7771Capture ad7771_receiver.vhd] \
    [file join $design_dir Ad7771Capture ad7771_axi_regs.vhd] \
    [file join $design_dir Ad7771Capture ad7771_capture.vhd] \
    [file join $design_dir AdcConversion adc_conversion_axi_regs.vhd] \
    [file join $design_dir AdcConversion adc_conversion.vhd] \
    [file join $design_dir MeterProcessing meter_processing_axi_regs.vhd] \
    [file join $design_dir MeterProcessing meter_rms.vhd] \
    [file join $design_dir MeterCore meter_core.vhd]]
foreach vhdl_source $vhdl2008_sources {
    if {[llength [get_files -quiet $vhdl_source]] == 0} {
        add_files -norecurse $vhdl_source
    }
    set_property FILE_TYPE {VHDL 2008} [get_files $vhdl_source]
}

set module_reference_sources [list \
    [file join $design_dir HeatBeat_Controller HeatBeat_Wrapper.vhd] \
    [file join $design_dir MeterProcessing MeterResultHub_Wrapper.vhd] \
    [file join $design_dir MeterProcessing MeterPacketizer_Wrapper.vhd] \
    [file join $design_dir MeterCore MeterCore_Wrapper.vhd]]
foreach module_reference_source $module_reference_sources {
    if {[llength [get_files -quiet $module_reference_source]] == 0} {
        add_files -norecurse $module_reference_source
    }
    set_property FILE_TYPE VHDL [get_files $module_reference_source]
}
update_compile_order -fileset sources_1

open_bd_design [get_files TopDesign.bd]
current_bd_design TopDesign

set meter_ip [get_ips -quiet TopDesign_MeterCore_Wrapper_0_0]
if {[llength $meter_ip] != 1} {
    error "Expected one MeterCore module-reference IP, found [llength $meter_ip]"
}
update_module_reference $meter_ip

set heartbeat_ip [get_ips -quiet TopDesign_HeatBeat_Wrapper_0_0]
if {[llength $heartbeat_ip] != 1} {
    error "Expected one heartbeat module-reference IP, found [llength $heartbeat_ip]"
}
update_module_reference $heartbeat_ip

set meter_cell [get_bd_cells -quiet MeterLogic/MeterCore_Wrapper]
if {[llength $meter_cell] != 1} {
    error "MeterCore module-reference cell was not found in TopDesign"
}
set meter_clock [get_bd_pins -quiet MeterLogic/MeterCore_Wrapper/aclk]
set meter_reset [get_bd_pins -quiet MeterLogic/MeterCore_Wrapper/aresetn]
if {[llength $meter_clock] != 1 || [llength $meter_reset] != 1} {
    error "MeterCore clock/reset pins were not found"
}
if {[get_property CONFIG.FREQ_HZ $meter_clock] != 99999001} {
    error "MeterCore aclk metadata is not 99999001 Hz"
}
if {[llength [get_bd_nets -quiet -of_objects $meter_clock]] == 0 ||
    [llength [get_bd_nets -quiet -of_objects $meter_reset]] == 0} {
    error "MeterCore clock or reset is unconnected"
}

set ps_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]
set capture_segment [get_bd_addr_segs -quiet \
    MeterLogic/MeterCore_Wrapper/s_axi_capture/reg0]
set conversion_segment [get_bd_addr_segs -quiet \
    MeterLogic/MeterCore_Wrapper/s_axi_conversion/reg0]
set processing_segment [get_bd_addr_segs -quiet \
    MeterLogic/MeterCore_Wrapper/s_axi_processing/reg0]
if {[llength $capture_segment] != 1 ||
    [llength $conversion_segment] != 1 ||
    [llength $processing_segment] != 1} {
    error "MeterCore AXI-Lite address segments were not found"
}
assign_bd_address -offset 0xB0020000 -range 64K \
    -target_address_space $ps_address_space $capture_segment -force
assign_bd_address -offset 0xB0040000 -range 64K \
    -target_address_space $ps_address_space $conversion_segment -force
assign_bd_address -offset 0xB0050000 -range 64K \
    -target_address_space $ps_address_space $processing_segment -force

validate_bd_design
save_bd_design
reset_target all [get_files TopDesign.bd]
generate_target all [get_files TopDesign.bd]

set old_wrapper [file join $repo_dir SourceData BlockDesign TopDesign hdl \
    TopDesign_wrapper.v]
set old_wrapper_file [get_files -quiet $old_wrapper]
if {[llength $old_wrapper_file] != 0} {
    remove_files $old_wrapper_file
}
make_wrapper -files [get_files TopDesign.bd] -top -language VHDL -force
set wrapper [file join $repo_dir SourceData BlockDesign TopDesign hdl \
    TopDesign_wrapper.vhd]
if {[llength [get_files -quiet $wrapper]] == 0} {
    add_files -norecurse $wrapper
}
set_property FILE_TYPE VHDL [get_files $wrapper]
set_property top TopDesign_wrapper [current_fileset]
update_compile_order -fileset sources_1
close_project
