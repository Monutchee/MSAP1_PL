# Confirm Vivado IP Integrator recognizes the MeterCore module-reference
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
  [file join $design_root Ad7771Capture ad7771_receiver.vhd] \
  [file join $design_root Ad7771Capture ad7771_axi_regs.vhd] \
  [file join $design_root Ad7771Capture ad7771_dclk_meter.vhd] \
  [file join $design_root Ad7771Capture ad7771_capture.vhd] \
  [file join $design_root AdcConversion adc_conversion_axi_regs.vhd] \
  [file join $design_root AdcConversion adc_conversion.vhd] \
  [file join $design_root MeterProcessing meter_frequency_pkg.vhd] \
  [file join $design_root MeterProcessing meter_processing_axi_regs.vhd] \
  [file join $design_root MeterProcessing meter_unsigned_divider.vhd] \
  [file join $design_root MeterProcessing meter_zero_crossing.vhd] \
  [file join $design_root MeterProcessing meter_frequency_estimator.vhd] \
  [file join $design_root MeterProcessing meter_frequency.vhd] \
  [file join $design_root MeterProcessing meter_rms.vhd] \
  [file join $design_root MeterCore meter_core.vhd]]
set wrapper_sources [list \
  [file join $design_root MeterProcessing MeterResultHub_Wrapper.vhd] \
  [file join $design_root MeterProcessing MeterPacketizer_Wrapper.vhd] \
  [file join $design_root MeterCore MeterCore_Wrapper.vhd]]

add_files -norecurse [concat $vhdl_2008_sources $wrapper_sources]
set_property FILE_TYPE {VHDL 2008} [get_files $vhdl_2008_sources]
update_compile_order -fileset sources_1
create_bd_design metering_module_reference_check

create_bd_cell -type module -reference MeterCore_Wrapper meter_core

set expected_interfaces [list \
  meter_core/S_AXI_CAPTURE meter_core/S_AXI_CONVERSION \
  meter_core/S_AXI_PROCESSING meter_core/M_AXIS_METER]
foreach interface_name $expected_interfaces {
  if {[llength [get_bd_intf_pins -quiet $interface_name]] != 1} {
    error "missing inferred interface $interface_name"
  }
}

set meter_clock [get_bd_pins -quiet meter_core/aclk]
if {[llength $meter_clock] != 1} {
  error "missing inferred MeterCore clock pin"
}
if {[get_property CONFIG.FREQ_HZ $meter_clock] != 99999001} {
  error "MeterCore aclk FREQ_HZ metadata was not inferred as 99999001"
}
if {[get_property CONFIG.ASSOCIATED_BUSIF $meter_clock] ne \
    "S_AXI_CAPTURE:S_AXI_CONVERSION:S_AXI_PROCESSING:M_AXIS_METER"} {
  error "MeterCore aclk AXI interface associations were not inferred"
}

puts "Metering module-reference interface inference PASS"
