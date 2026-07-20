# Confirm Vivado IP Integrator recognizes every metering module-reference
# boundary and its named AXI interfaces without modifying the product project.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_metering_module_reference]
file delete -force $work_root
file mkdir $work_root
cd $work_root

create_project -in_memory -part xck26-sfvc784-2LV-c
set_property source_mgmt_mode All [current_project]
set vhdl_2008_sources [list \
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root AdcConversion adc_conversion_axi_regs.vhd] \
  [file join $design_root AdcConversion adc_conversion.vhd] \
  [file join $design_root MeterProcessing meter_processing_axi_regs.vhd] \
  [file join $design_root MeterProcessing voltage_rms.vhd]]
set wrapper_sources [list \
  [file join $design_root AdcConversion AdcConversion_Wrapper.vhd] \
  [file join $design_root MeterProcessing CurrentRms_Wrapper.vhd] \
  [file join $design_root MeterProcessing VoltageRms_Wrapper.vhd] \
  [file join $design_root MeterProcessing MeterResultHub_Wrapper.vhd] \
  [file join $design_root MeterProcessing MeterPacketizer_Wrapper.vhd]]

add_files -norecurse [concat $vhdl_2008_sources $wrapper_sources]
set_property FILE_TYPE {VHDL 2008} [get_files $vhdl_2008_sources]
update_compile_order -fileset sources_1
create_bd_design metering_module_reference_check

create_bd_cell -type module -reference AdcConversion_Wrapper conversion
create_bd_cell -type module -reference VoltageRms_Wrapper voltage
create_bd_cell -type module -reference CurrentRms_Wrapper current
create_bd_cell -type module -reference MeterResultHub_Wrapper hub
create_bd_cell -type module -reference MeterPacketizer_Wrapper packetizer

set expected_interfaces [list \
  conversion/S_AXIS_RAW conversion/M_AXIS_CONVERTED conversion/S_AXI_CONFIG \
  voltage/S_AXIS_CONVERTED voltage/S_AXI_CONFIG \
  current/S_AXIS_CONVERTED packetizer/M_AXIS_METER]
foreach interface_name $expected_interfaces {
  if {[llength [get_bd_intf_pins -quiet $interface_name]] != 1} {
    error "missing inferred interface $interface_name"
  }
}

puts "Metering module-reference interface inference PASS"
