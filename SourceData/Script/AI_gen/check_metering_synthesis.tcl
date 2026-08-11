# Focused non-project synthesis for one metering module-reference wrapper.

if {$argc != 1} {
  error "usage: vivado ... -source check_metering_synthesis.tcl -tclargs <top>"
}
set top_name [lindex $argv 0]
set allowed_tops [list \
  AdcConversion_Wrapper \
  VoltageRms_Wrapper \
  MeterResultHub_Wrapper \
  MeterPacketizer_Wrapper \
  MeterCore_Wrapper]
if {[lsearch -exact $allowed_tops $top_name] < 0} {
  error "unsupported metering synthesis top: $top_name"
}

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]

# Packaged HLS RTL (IP repository entry); refreshed by make_HLS.sh or
# SourceData/HLS_DesignFile/run_hls.sh <component>.
set hls_aggregator_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo CycleAggregator hdl verilog]
if {![file isdirectory $hls_aggregator_hdl]} {
  error "missing $hls_aggregator_hdl -- run make_HLS.sh or HLS_DesignFile/run_hls.sh first"
}

# Keep focused checks predictable on developer workstations where the GUI or
# other Vivado jobs may already be consuming memory.
set_param general.maxThreads 2

read_vhdl -vhdl2008 [file join $design_root MeterCommon metering_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCommon grid_timing_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCommon measurement_record_bus_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root Ad7771Capture ad7771_receiver.vhd]
read_vhdl -vhdl2008 [file join $design_root Ad7771Capture ad7771_axi_regs.vhd]
read_vhdl -vhdl2008 [file join $design_root Ad7771Capture ad7771_dclk_meter.vhd]
read_vhdl -vhdl2008 [file join $design_root Ad7771Capture ad7771_capture.vhd]
read_vhdl -vhdl2008 [file join $design_root AdcConversion adc_conversion_axi_regs.vhd]
read_vhdl -vhdl2008 [file join $design_root AdcConversion adc_conversion.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_frequency_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_processing_axi_regs.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_unsigned_divider.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_zero_crossing.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_frequency_estimator.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_frequency.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_rms.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing grid_cycle_timing.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_cycle_aggregator.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_cycle_aggregator_hls_shim.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_aggregator_compare.vhd]
read_verilog [lsort [glob -directory $hls_aggregator_hdl *.v]]
# Binds the IP-customization module name over the packaged RTL for this
# non-project flow (the project gets the same module from the XCI).
read_verilog [file join $design_root MeterProcessing tb hls_cycle_aggregator_ip.v]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing aggregate_record_producer.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing measurement_record_arbiter.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore adc_simulator_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore adc_simulator.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore adc_source_mux.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore meter_waveform_axi_regs.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore meter_waveform.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing MeterResultHub_Wrapper.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing MeterPacketizer_Wrapper.vhd]
read_vhdl [file join $design_root AdcConversion AdcConversion_Wrapper.vhd]
read_vhdl [file join $design_root MeterProcessing VoltageRms_Wrapper.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore meter_core.vhd]
read_vhdl [file join $design_root MeterCore MeterCore_Wrapper.vhd]

synth_design -top $top_name -part xck26-sfvc784-2LV-c
create_clock -name metering_aclk -period 10.000 [get_ports aclk]
if {[llength [get_ports -quiet adc_dclk]] != 0} {
  create_clock -name adc_dclk -period 122.070 [get_ports adc_dclk]
  set_clock_groups -asynchronous \
    -group [get_clocks metering_aclk] -group [get_clocks adc_dclk]
}
report_utilization -file [file join /tmp ${top_name}_utilization.rpt]
report_timing_summary -delay_type max \
  -file [file join /tmp ${top_name}_timing.rpt]
puts "$top_name focused synthesis PASS"
