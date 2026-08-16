# Focused mixed-language verification for the software-configured metering RTL.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_metering_pipeline]

# Packaged HLS RTL (IP repository entry); refreshed by 'mnc HLS build' or
# SourceData/HLS_DesignFile/run_hls.sh <component>.
set hls_aggregator_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo CycleAggregator hdl verilog]
if {![file isdirectory $hls_aggregator_hdl]} {
  error "missing $hls_aggregator_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_aggregator_verilog [concat \
  [lsort [glob -directory $hls_aggregator_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_cycle_aggregator_ip.v]]]
set hls_mtr1_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo Mtr1Engine hdl verilog]
if {![file isdirectory $hls_mtr1_hdl]} {
  error "missing $hls_mtr1_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_mtr1_verilog [concat \
  [lsort [glob -directory $hls_mtr1_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_mtr1_engine_ip.v]]]

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
  [file join $design_root MeterCommon measurement_record_bus_pkg.vhd] \
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
  [file join $design_root MeterProcessing meter_mtr1_hls_shim.vhd]]

set wrapper_vhdl [list \
  [file join $design_root AdcConversion AdcConversion_Wrapper.vhd]]

proc run_test {work_root test_name common_vhdl wrapper_vhdl testbench xvhdl xvlog xelab simulator_libraries} {
  global hls_aggregator_hdl hls_aggregator_verilog hls_mtr1_hdl hls_mtr1_verilog
  set test_dir [file join $work_root $test_name]
  file mkdir $test_dir
  set original_dir [pwd]
  cd $test_dir
  puts [exec $xvhdl --2008 {*}$common_vhdl 2>@1]
  puts [exec $xvhdl {*}$wrapper_vhdl 2>@1]
  puts [exec $xvlog -i $hls_aggregator_hdl {*}$hls_aggregator_verilog 2>@1]
  puts [exec $xvlog -i $hls_mtr1_hdl {*}$hls_mtr1_verilog 2>@1]
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
# Whole-chain record-stream integration: sample beats through the real
# shim, the packaged MTR1 engine, and the packaged aggregator to both
# exported AXIS record streams, under TREADY backpressure, with
# exactly-once sequence accounting and 64-beat framing assertions
# (verification plan TB-1/INV-1/INV-2; guards the 2026-08-13..16
# duplicate/loss fault class).
run_test $work_root meter_record_stream_tb $common_vhdl $wrapper_vhdl \
  [file join $design_root MeterProcessing tb meter_record_stream_tb.sv] \
  $xvhdl $xvlog $xelab $simulator_libraries
run_test $work_root grid_cycle_timing_tb $common_vhdl $wrapper_vhdl \
  [file join $design_root MeterProcessing tb grid_cycle_timing_tb.sv] \
  $xvhdl $xvlog $xelab $simulator_libraries
# The 150/180-cycle aggregation engine is HLS
# (HLS_DesignFile/MeterProcessing/CycleAggregator): its twelve-scenario
# golden bench runs as C simulation and C/RTL co-simulation on every
# 'mnc HLS build' / run_hls.sh build, and check_meter_core.tcl validates a
# complete MTR2 record through the shim and engine in the real pipeline.

puts "All metering pipeline simulations PASS"
