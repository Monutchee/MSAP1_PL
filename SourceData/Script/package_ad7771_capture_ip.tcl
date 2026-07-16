# Package the focused AD7771 receiver as reusable Vivado IP.  Packaging gives
# the AXI-Lite interface a real memory map, which a plain module-reference block
# cannot express.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../..]]
set rtl_dir [file join $repo_dir SourceData DesignFile Ad7771Capture]
set temp_project /tmp/ad7771_capture_ip_project

create_project -force ad7771_capture_ip $temp_project -part xck26-sfvc784-2LV-c
add_files -norecurse [list \
    [file join $rtl_dir ad7771_receiver.sv] \
    [file join $rtl_dir ad7771_axi_regs.sv] \
    [file join $rtl_dir ad7771_capture.sv] \
    [file join $rtl_dir Ad7771Capture_Wrapper.v]]
set_property top Ad7771Capture_Wrapper [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project \
    -root_dir $rtl_dir \
    -vendor monutchee.com \
    -library user \
    -name ad7771_capture \
    -version 1.0 \
    -taxonomy /UserIP \
    -set_current true \
    -force

set core [ipx::current_core]
set_property display_name {AD7771 Capture} $core
set_property description {Four-lane AD7771 receiver, CDC FIFO, AXI Stream packetizer, and control/status registers} $core
set_property vendor_display_name {Monutchee} $core
set_property company_url {https://monutchee.com} $core
set_property supported_families {zynquplus Production} $core
# Bump this revision whenever the implementation changes without changing the
# public 1.0 interface. Vivado uses it to unlock/upgrade existing BD cells.
set_property core_revision 5 $core

set s_axi [ipx::get_bus_interfaces S_AXI -of_objects $core]
set memory_maps [ipx::get_memory_maps -quiet S_AXI -of_objects $core]
if {[llength $memory_maps] == 0} {
    set memory_map [ipx::add_memory_map S_AXI $core]
} else {
    set memory_map [lindex $memory_maps 0]
}
set_property slave_memory_map_ref S_AXI $s_axi

# The RTL packager may infer a small, generically named address block before
# this script runs.  Normalize that inferred object instead of creating a
# second block, so the BD segment has a stable S_AXI/Reg path.
set address_blocks [ipx::get_address_blocks -quiet -of_objects $memory_map]
if {[llength $address_blocks] == 0} {
    set address_block [ipx::add_address_block Reg $memory_map]
} else {
    set address_block [lindex $address_blocks 0]
}
set_property name Reg $address_block
set_property display_name {AD7771 capture registers} $address_block
set_property width 32 $address_block
set_property access read-write $address_block
set_property usage register $address_block
set_property base_address 0 $address_block
set_property base_address_resolve_type immediate $address_block
set_property range 65536 $address_block
set_property range_resolve_type generated $address_block

ipx::associate_bus_interfaces -busif S_AXI -clock s_axi_aclk $core
ipx::associate_bus_interfaces -busif M_AXIS -clock s_axi_aclk $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
close_project
