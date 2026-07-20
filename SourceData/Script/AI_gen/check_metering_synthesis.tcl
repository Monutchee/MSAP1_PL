# Focused non-project synthesis for one metering module-reference wrapper.

if {$argc != 1} {
  error "usage: vivado ... -source check_metering_synthesis.tcl -tclargs <top>"
}
set top_name [lindex $argv 0]
set allowed_tops [list \
  AdcConversion_Wrapper \
  VoltageRms_Wrapper \
  CurrentRms_Wrapper \
  MeterResultHub_Wrapper \
  MeterPacketizer_Wrapper]
if {[lsearch -exact $allowed_tops $top_name] < 0} {
  error "unsupported metering synthesis top: $top_name"
}

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]

read_vhdl -vhdl2008 [file join $design_root MeterCommon metering_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root AdcConversion adc_conversion_axi_regs.vhd]
read_vhdl -vhdl2008 [file join $design_root AdcConversion adc_conversion.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_processing_axi_regs.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing voltage_rms.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing MeterResultHub_Wrapper.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing MeterPacketizer_Wrapper.vhd]
read_vhdl [file join $design_root AdcConversion AdcConversion_Wrapper.vhd]
read_vhdl [file join $design_root MeterProcessing CurrentRms_Wrapper.vhd]
read_vhdl [file join $design_root MeterProcessing VoltageRms_Wrapper.vhd]

synth_design -top $top_name -part xck26-sfvc784-2LV-c
create_clock -name metering_aclk -period 10.000 [get_ports aclk]
report_utilization -file [file join /tmp ${top_name}_utilization.rpt]
report_timing_summary -file [file join /tmp ${top_name}_timing.rpt]
puts "$top_name focused synthesis PASS"
