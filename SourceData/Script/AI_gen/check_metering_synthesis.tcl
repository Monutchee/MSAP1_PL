# Focused non-project synthesis for one metering module-reference wrapper.

if {$argc != 1} {
  error "usage: vivado ... -source check_metering_synthesis.tcl -tclargs <top>"
}
set top_name [lindex $argv 0]
set allowed_tops [list \
  AdcConversion_Wrapper \
  MeterCore_Wrapper]
if {[lsearch -exact $allowed_tops $top_name] < 0} {
  error "unsupported metering synthesis top: $top_name"
}

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set conditioner_coefficients [file join $design_root MeterProcessing \
  meter_spectral_conditioner_q20.mem]

# Packaged HLS RTL (IP repository entry); refreshed by 'mnc HLS build' or
# SourceData/HLS_DesignFile/run_hls.sh <component>.
set hls_pq_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SlidingOneCycleRmsEngine hdl verilog]
if {![file isdirectory $hls_pq_hdl]} {
  error "missing $hls_pq_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_flicker_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo FlickerEngine hdl verilog]
if {![file isdirectory $hls_flicker_hdl]} {
  error "missing $hls_flicker_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_mains_signal_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo MainsSignalEngine hdl verilog]
if {![file isdirectory $hls_mains_signal_hdl]} {
  error "missing $hls_mains_signal_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_scyc_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SingleCycleEngine hdl verilog]
if {![file isdirectory $hls_scyc_hdl]} {
  error "missing $hls_scyc_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_sim_wave_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SimWaveEngine hdl verilog]
if {![file isdirectory $hls_sim_wave_hdl]} {
  error "missing $hls_sim_wave_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_harmonic_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo HarmonicEngine hdl verilog]
if {![file isdirectory $hls_harmonic_hdl]} {
  error "missing $hls_harmonic_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}

# Keep focused checks predictable on developer workstations where the GUI or
# other Vivado jobs may already be consuming memory.
set_param general.maxThreads 2

read_mem $conditioner_coefficients

read_vhdl -vhdl2008 [file join $design_root MeterCommon metering_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCommon grid_timing_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCommon pq_event_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCommon measurement_record_bus_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_r5_power_quality_protocol_pkg.vhd]
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
read_vhdl -vhdl2008 [file join $design_root MeterProcessing grid_cycle_timing.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing record_word_tap.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_r5_aggregation_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_r5_harmonic_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_r5_harmonic_export.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_axis_packet_arbiter_2to1.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_r5_fixed_packet_export.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_axis_packet_arbiter_5to1.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_r5_aggregation_export.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_single_cycle_hls_shim.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_sliding_rms_hls_shim.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_flicker_hls_shim.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_mains_signal_hls_shim.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_spectral_conditioner.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_spectral_frontend.vhd]
read_verilog [lsort [glob -directory $hls_scyc_hdl *.v]]
read_verilog [lsort [glob -directory $hls_pq_hdl *.v]]
read_verilog [lsort [glob -directory $hls_flicker_hdl *.v]]
read_verilog [lsort [glob -directory $hls_mains_signal_hdl *.v]]
read_verilog [lsort [glob -directory $hls_sim_wave_hdl *.v]]
read_verilog [lsort [glob -directory $hls_harmonic_hdl *.v]]
# Bind the IP-customization module names over the packaged RTL for this
# non-project flow (the project gets the same modules from the XCIs).
read_verilog [file join $design_root MeterProcessing tb hls_sliding_one_cycle_rms_engine_ip.v]
read_verilog [file join $design_root MeterProcessing tb hls_flicker_engine_ip.v]
read_verilog [file join $design_root MeterProcessing tb hls_mains_signal_engine_ip.v]
read_verilog [file join $design_root MeterProcessing tb hls_single_cycle_engine_ip.v]
read_verilog [file join $design_root MeterProcessing tb hls_harmonic_engine_ip.v]
read_verilog [file join $design_root MeterCore tb hls_sim_wave_engine_ip.v]
read_vhdl -vhdl2008 [file join $design_root MeterProcessing meter_harmonic_hls_shim.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore adc_simulator_pkg.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore adc_simulator.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore adc_source_mux.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore meter_waveform_axi_regs.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore meter_waveform.vhd]
read_vhdl [file join $design_root AdcConversion AdcConversion_Wrapper.vhd]
read_vhdl -vhdl2008 [file join $design_root MeterCore meter_core.vhd]
read_vhdl [file join $design_root MeterCore MeterCore_Wrapper.vhd]

synth_design -top $top_name -part xck26-sfvc784-2LV-c
create_clock -name metering_aclk -period 10.000 [get_ports aclk]
if {[llength [get_ports -quiet adc_dclk]] != 0} {
  create_clock -name adc_dclk -period 122.070 [get_ports adc_dclk]
  set_clock_groups -asynchronous \
    -group [get_clocks metering_aclk] -group [get_clocks adc_dclk]
}
if {$top_name eq "MeterCore_Wrapper"} {
  set uram_count [llength [get_cells -hier -filter {REF_NAME == URAM288}]]
  set ramb36_count [llength [get_cells -hier -filter {REF_NAME == RAMB36E2}]]
  set ramb18_count [llength [get_cells -hier -filter {REF_NAME == RAMB18E2}]]
  set bram_tiles [expr {$ramb36_count + (0.5 * $ramb18_count)}]
  puts "MeterCore storage: BRAM tiles=$bram_tiles URAM=$uram_count"
  if {$uram_count < 14} {
    error "MeterCore packet/history storage did not map to the required K26 UltraRAMs"
  }
  if {$bram_tiles > 104.0} {
    error "MeterCore BRAM use $bram_tiles exceeds the M18 full-design headroom budget"
  }
}
report_utilization -file [file join /tmp ${top_name}_utilization.rpt]
report_timing_summary -delay_type max \
  -file [file join /tmp ${top_name}_timing.rpt]
puts "$top_name focused synthesis PASS"
