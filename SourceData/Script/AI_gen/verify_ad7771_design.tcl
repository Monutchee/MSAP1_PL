# Validate the integrated AD7771 data path and regenerate the managed wrapper.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../../..]]
set project_file [file join $repo_dir vivado_gen MSAP1_PL.xpr]

open_project $project_file

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

# The module-reference wrapper does not carry packaged-IP address metadata.
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
assign_bd_address -offset 0x44A10000 -range 64K \
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
assign_bd_address -offset 0xB0020000 -range 64K \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    $top_capture_segment -force
validate_bd_design
save_bd_design

# Rebuild output metadata as well as HDL. Recreating a BDC boundary can leave
# obsolete ActiveVariant entries in TopDesign.bxml even after the BD itself is
# correct; those entries otherwise resurrect missing generated filesets during
# synthesis.
reset_target all [get_files TopDesign.bd]
generate_target all [get_files AdcSubSystem.bd]
generate_target all [get_files TopDesign.bd]
make_wrapper -files [get_files TopDesign.bd] -top
set wrapper [file join $repo_dir SourceData BlockDesign TopDesign hdl TopDesign_wrapper.v]
if {[llength [get_files -quiet $wrapper]] == 0} {
    add_files -norecurse $wrapper
}
set_property top TopDesign_wrapper [current_fileset]
update_compile_order -fileset sources_1
close_project
