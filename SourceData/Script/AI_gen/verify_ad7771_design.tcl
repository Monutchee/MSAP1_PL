# Validate the VHDL module references and regenerate the managed wrapper.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../../..]]
set project_file [file join $repo_dir vivado_gen MSAP1_PL.xpr]

open_project $project_file

set_property TARGET_LANGUAGE VHDL [current_project]
set_property SIMULATOR_LANGUAGE Mixed [current_project]

# Replace the maintained SystemVerilog implementation with VHDL while keeping
# the module-reference top name and ports unchanged. The BD therefore refreshes
# the existing cell instead of deleting and reconnecting it.
set rtl_dir [file join $repo_dir SourceData DesignFile Ad7771Capture]
set heartbeat_dir [file join $repo_dir SourceData DesignFile HeatBeat_Controller]
set legacy_sources [list \
    [file join $rtl_dir ad7771_receiver.sv] \
    [file join $rtl_dir ad7771_axi_regs.sv] \
    [file join $rtl_dir ad7771_capture.sv] \
    [file join $rtl_dir Ad7771Capture_Wrapper.v] \
    [file join $heartbeat_dir HeatBeat_Controller.sv] \
    [file join $heartbeat_dir HeatBeat_Wrapper.v]]
foreach legacy_source $legacy_sources {
    set legacy_file [get_files -quiet $legacy_source]
    if {[llength $legacy_file] != 0} {
        remove_files $legacy_file
    }
}

set vhdl2008_sources [list \
    [file join $rtl_dir ad7771_receiver.vhd] \
    [file join $rtl_dir ad7771_axi_regs.vhd] \
    [file join $rtl_dir ad7771_capture.vhd] \
    [file join $heartbeat_dir HeatBeat_Controller.vhd]]
foreach vhdl_source $vhdl2008_sources {
    if {[llength [get_files -quiet $vhdl_source]] == 0} {
        add_files -norecurse $vhdl_source
    }
    set_property FILE_TYPE {VHDL 2008} [get_files $vhdl_source]
}

set module_reference_sources [list \
    [file join $rtl_dir Ad7771Capture_Wrapper.vhd] \
    [file join $heartbeat_dir HeatBeat_Wrapper.vhd]]
foreach module_reference_source $module_reference_sources {
    if {[llength [get_files -quiet $module_reference_source]] == 0} {
        add_files -norecurse $module_reference_source
    }
    set_property FILE_TYPE VHDL [get_files $module_reference_source]
}
update_compile_order -fileset sources_1

# Failed/retried BDC boundary updates can leave auto-generated filesets in the
# project. Determine the active BDC variant from TopDesign.bxml so cleanup never
# deletes the currently selected container merely because its numeric suffix
# changed after a GUI remove/re-add operation.
set top_bxml [file join $repo_dir SourceData BlockDesign TopDesign TopDesign.bxml]
set bxml_channel [open $top_bxml r]
set bxml_contents [read $bxml_channel]
close $bxml_channel
set active_bdc_filesets {}
foreach fileset_match [regexp -all -inline {BDFileset="[^"]+"} $bxml_contents] {
    if {[regexp {BDFileset="([^"]+)"} $fileset_match -> active_name]} {
        lappend active_bdc_filesets $active_name
    }
}

foreach stale_fileset [get_filesets -quiet AdcSubSystem_inst_*] {
    set stale_name [get_property NAME $stale_fileset]
    if {[lsearch -exact $active_bdc_filesets $stale_name] >= 0} {
        continue
    }
    delete_fileset $stale_fileset
}

# Persist the fileset cleanup before opening/generating any BD. If Vivado
# encounters an output-product problem later, the stale reference must not be
# resurrected in the next synthesis launch.
close_project
open_project $project_file

# Refresh the existing heartbeat module-reference cell in place. Its entity
# name is unchanged; connect the new clock and reset pins to the StatusSignal
# AXI clock domain if the GUI has not already done so.
open_bd_design [get_files StatusSignal.bd]
current_bd_design StatusSignal
set heartbeat_cell [get_bd_cells -quiet HeatBeat_Wrapper_0]
if {[llength $heartbeat_cell] != 0} {
    set heartbeat_ip [get_ips -quiet StatusSignal_HeatBeat_Wrapper_0_*]
    if {[llength $heartbeat_ip] != 1} {
        error "Expected one active heartbeat module-reference IP object, found [llength $heartbeat_ip]"
    }
    update_module_reference $heartbeat_ip

    set heartbeat_clk_pin [get_bd_pins -quiet HeatBeat_Wrapper_0/clk]
    set heartbeat_reset_pin [get_bd_pins -quiet HeatBeat_Wrapper_0/reset_n]
    set status_clk_port [get_bd_ports -quiet s_axi_aclk_0]
    set status_reset_port [get_bd_ports -quiet s_axi_aresetn_0]
    if {[llength $heartbeat_clk_pin] != 1 ||
        [llength $heartbeat_reset_pin] != 1 ||
        [llength $status_clk_port] != 1 ||
        [llength $status_reset_port] != 1} {
        error "Heartbeat clock/reset pins or StatusSignal clock/reset ports were not found"
    }

    if {[llength [get_bd_nets -quiet -of_objects $heartbeat_clk_pin]] == 0} {
        connect_bd_net $status_clk_port $heartbeat_clk_pin
    }
    if {[llength [get_bd_nets -quiet -of_objects $heartbeat_reset_pin]] == 0} {
        connect_bd_net $status_reset_port $heartbeat_reset_pin
    }
}
validate_bd_design
save_bd_design

# The ADC module-reference wrapper does not carry packaged-IP address metadata.
# Maintain its child and parent address assignments explicitly.
open_bd_design [get_files AdcSubSystem.bd]
current_bd_design AdcSubSystem
set capture_cell [get_bd_cells -quiet Ad7771Capture_Wrapper_0]
if {[llength $capture_cell] != 0} {
    set capture_ip [get_ips -quiet AdcSubSystem_Ad7771Capture_Wrapper_0_0]
    if {[llength $capture_ip] == 0} {
        error "AD7771 module-reference IP object was not found"
    }
    update_module_reference $capture_ip
}
set_property CONFIG.FREQ_HZ 99999001 [get_bd_ports s_axi_aclk]
set capture_segment [get_bd_addr_segs -quiet \
    Ad7771Capture_Wrapper_0/S_AXI/reg0]
if {[llength $capture_segment] == 0} {
    error "AD7771 module-reference AXI register segment was not found"
}
assign_bd_address -offset 0x44A10000 -range 4K \
    -target_address_space [get_bd_addr_spaces S00_AXI_0] \
    $capture_segment -force
validate_bd_design
save_bd_design

open_bd_design [get_files TopDesign.bd]
current_bd_design TopDesign
set top_capture_segment [get_bd_addr_segs -quiet \
    AdcSubSystem_0/Ad7771Capture_Wrapper_0/S_AXI/reg0]
if {[llength $top_capture_segment] == 0} {
    error "TopDesign AD7771 AXI register segment was not found"
}
assign_bd_address -offset 0xB0020000 -range 4K \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    $top_capture_segment -force
validate_bd_design
save_bd_design

# Rebuild output metadata as well as HDL. Recreating a BDC boundary can leave
# obsolete ActiveVariant entries in TopDesign.bxml even after the BD itself is
# correct; those entries otherwise resurrect missing generated filesets during
# synthesis.
reset_target all [get_files TopDesign.bd]
generate_target all [get_files StatusSignal.bd]
generate_target all [get_files AdcSubSystem.bd]
generate_target all [get_files TopDesign.bd]

set old_wrapper [file join $repo_dir SourceData BlockDesign TopDesign hdl TopDesign_wrapper.v]
set old_wrapper_file [get_files -quiet $old_wrapper]
if {[llength $old_wrapper_file] != 0} {
    remove_files $old_wrapper_file
}
make_wrapper -files [get_files TopDesign.bd] -top -language VHDL -force
set wrapper [file join $repo_dir SourceData BlockDesign TopDesign hdl TopDesign_wrapper.vhd]
if {[llength [get_files -quiet $wrapper]] == 0} {
    add_files -norecurse $wrapper
}
set_property FILE_TYPE VHDL [get_files $wrapper]
set_property top TopDesign_wrapper [current_fileset]
update_compile_order -fileset sources_1

# A cancelled GUI implementation retry can leave an empty copied run in the
# project. It is not part of the maintained build flow and otherwise creates a
# large, unrelated project-file diff when the wrapper is regenerated.
foreach copied_run [get_runs -quiet impl_1_copy_*] {
    delete_runs $copied_run
}
close_project
