# Focused mixed-language verification for the software-configured metering RTL.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_metering_pipeline]

# Packaged HLS RTL (IP repository entry); refreshed by 'mnc HLS build' or
# SourceData/HLS_DesignFile/run_hls.sh <component>.
set hls_scyc_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SingleCycleEngine hdl verilog]
if {![file isdirectory $hls_scyc_hdl]} {
  error "missing $hls_scyc_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_scyc_verilog [concat \
  [lsort [glob -directory $hls_scyc_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_single_cycle_engine_ip.v]]]
set hls_pq_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SlidingOneCycleRmsEngine hdl verilog]
if {![file isdirectory $hls_pq_hdl]} {
  error "missing $hls_pq_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_pq_verilog [concat \
  [lsort [glob -directory $hls_pq_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_sliding_one_cycle_rms_engine_ip.v]]]

set xvlog [lindex [auto_execok xvlog] 0]
set xvhdl [lindex [auto_execok xvhdl] 0]
set xelab [lindex [auto_execok xelab] 0]
if {$xvlog eq "" || $xvhdl eq "" || $xelab eq ""} {
  error "Vivado simulator tools are not available in PATH"
}
set vivado_root [file dirname [file dirname [file normalize $xvlog]]]
set simulator_libraries \
  [file join $vivado_root lib lnx64.o]:[file join $vivado_root lib lnx64.o Default]
if {[info exists ::env(LD_LIBRARY_PATH)] && $::env(LD_LIBRARY_PATH) ne ""} {
  append simulator_libraries :$::env(LD_LIBRARY_PATH)
}

file delete -force $work_root
file mkdir $work_root

set common_vhdl [list \
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root MeterCommon grid_timing_pkg.vhd] \
  [file join $design_root MeterCommon pq_event_pkg.vhd] \
  [file join $design_root MeterCommon measurement_record_bus_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_power_quality_protocol_pkg.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_pkg.vhd] \
  [file join $design_root AdcConversion adc_conversion_axi_regs.vhd] \
  [file join $design_root AdcConversion adc_conversion.vhd] \
  [file join $design_root MeterProcessing meter_frequency_pkg.vhd] \
  [file join $design_root MeterProcessing meter_processing_axi_regs.vhd] \
  [file join $design_root MeterProcessing meter_unsigned_divider.vhd] \
  [file join $design_root MeterProcessing meter_zero_crossing.vhd] \
  [file join $design_root MeterProcessing meter_frequency_estimator.vhd] \
  [file join $design_root MeterProcessing meter_frequency.vhd] \
  [file join $design_root MeterProcessing grid_cycle_timing.vhd] \
  [file join $design_root MeterProcessing record_word_tap.vhd] \
  [file join $design_root MeterProcessing meter_single_cycle_hls_shim.vhd] \
  [file join $design_root MeterProcessing meter_sliding_rms_hls_shim.vhd] \
  [file join $design_root MeterProcessing meter_r5_aggregation_pkg.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_conditioner.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_observer.vhd] \
  [file join $design_root MeterProcessing meter_r5_harmonic_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_harmonic_export.vhd] \
  [file join $design_root MeterProcessing meter_axis_packet_arbiter_2to1.vhd] \
  [file join $design_root MeterProcessing meter_r5_fixed_packet_export.vhd] \
  [file join $design_root MeterProcessing meter_axis_packet_arbiter_5to1.vhd] \
  [file join $design_root MeterProcessing meter_r5_aggregation_export.vhd]]

set wrapper_vhdl [list \
  [file join $design_root AdcConversion AdcConversion_Wrapper.vhd]]

proc run_test {work_root test_name common_vhdl wrapper_vhdl testbench xvhdl xvlog xelab simulator_libraries} {
  global hls_scyc_hdl hls_scyc_verilog hls_pq_hdl hls_pq_verilog
  set test_dir [file join $work_root $test_name]
  file mkdir $test_dir
  set original_dir [pwd]
  cd $test_dir
  puts [exec $xvhdl --2008 {*}$common_vhdl 2>@1]
  puts [exec $xvhdl {*}$wrapper_vhdl 2>@1]
  puts [exec $xvlog -i $hls_scyc_hdl {*}$hls_scyc_verilog 2>@1]
  puts [exec $xvlog -i $hls_pq_hdl {*}$hls_pq_verilog 2>@1]
  # HLS ROMs (the single-cycle trig LUT, the M9 CORDIC atan table, any
  # future table) initialize from .dat images that xsim resolves relative
  # to the working directory — copy them from EVERY packaged engine.
  foreach hdl_dir [list $hls_scyc_hdl $hls_pq_hdl] {
    foreach rom_image [glob -nocomplain -directory $hdl_dir *.dat] {
      file copy -force $rom_image [file join $test_dir [file tail $rom_image]]
    }
  }
  puts [exec $xvlog --sv $testbench 2>@1]
  puts [exec $xelab -a --mt off $test_name -s ${test_name}_sim 2>@1]
  set axsim [file join $test_dir xsim.dir ${test_name}_sim axsim]
  set simulation_log [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
  puts $simulation_log
  if {[string first "PASS" $simulation_log] < 0} {
    error "$test_name did not report PASS:\n$simulation_log"
  }
  puts "$test_name PASS"
  cd $original_dir
}

run_test $work_root adc_conversion_tb $common_vhdl $wrapper_vhdl \
  [file join $design_root AdcConversion tb adc_conversion_tb.sv] \
  $xvhdl $xvlog $xelab $simulator_libraries
run_test $work_root grid_cycle_timing_tb $common_vhdl $wrapper_vhdl \
  [file join $design_root MeterProcessing tb grid_cycle_timing_tb.sv] \
  $xvhdl $xvlog $xelab $simulator_libraries
puts "All metering pipeline simulations PASS"
