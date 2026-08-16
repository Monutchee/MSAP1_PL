# Standalone mixed-language integration verification for MeterCore.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_meter_core_sim]

# Packaged HLS RTL (IP repository entry); refreshed by 'mnc HLS build' or
# SourceData/HLS_DesignFile/run_hls.sh <component>.
set hls_mtr2_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo Mtr2Engine hdl verilog]
if {![file isdirectory $hls_mtr2_hdl]} {
  error "missing $hls_mtr2_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_mtr2_verilog [concat \
  [lsort [glob -directory $hls_mtr2_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_mtr2_engine_ip.v]]]
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

set vhdl2008_sources [list \
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root MeterCommon grid_timing_pkg.vhd] \
  [file join $design_root MeterCommon measurement_record_bus_pkg.vhd] \
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
  [file join $design_root MeterProcessing grid_cycle_timing.vhd] \
  [file join $design_root MeterProcessing record_word_tap.vhd] \
  [file join $design_root MeterProcessing meter_mtr1_hls_shim.vhd] \
  [file join $design_root MeterProcessing meter_mtr2_hls_shim.vhd] \
  [file join $design_root MeterCore adc_simulator_pkg.vhd] \
  [file join $design_root MeterCore adc_simulator.vhd] \
  [file join $design_root MeterCore adc_source_mux.vhd] \
  [file join $design_root MeterCore meter_waveform_axi_regs.vhd] \
  [file join $design_root MeterCore meter_waveform.vhd]]
set core_vhdl2008_sources [list \
  [file join $design_root MeterCore meter_core.vhd]]
set boundary_wrapper [file join $design_root MeterCore MeterCore_Wrapper.vhd]
set testbench [file join $design_root MeterCore tb meter_core_tb.sv]
set simulator_testbench [file join $design_root MeterCore tb adc_simulator_tb.sv]

file delete -force $work_root
file mkdir $work_root
set original_dir [pwd]
cd $work_root

puts [exec $xvhdl --2008 {*}$vhdl2008_sources 2>@1]
puts [exec $xvlog -i $hls_mtr2_hdl {*}$hls_mtr2_verilog 2>@1]
puts [exec $xvlog -i $hls_mtr1_hdl {*}$hls_mtr1_verilog 2>@1]
puts [exec $xvhdl --2008 {*}$core_vhdl2008_sources 2>@1]
puts [exec $xvhdl $boundary_wrapper 2>@1]
puts [exec $xvlog --sv $testbench 2>@1]
puts [exec $xvlog [file join $vivado_root data verilog src glbl.v] 2>@1]
puts [exec $xelab -a --mt off -L xpm meter_core_tb glbl \
  -s meter_core_tb_sim 2>@1]

set axsim [file join $work_root xsim.dir meter_core_tb_sim axsim]
set simulation_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $simulation_log
if {![string match "*PASS: meter_core_tb*" $simulation_log]} {
  error "MeterCore integration simulation did not report PASS"
}

puts [exec $xvlog --sv $simulator_testbench 2>@1]
puts [exec $xelab -a --mt off adc_simulator_tb \
  -s adc_simulator_tb_sim 2>@1]
set simulator_axsim [file join $work_root xsim.dir adc_simulator_tb_sim axsim]
set simulator_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $simulator_axsim 2>@1]
puts $simulator_log
if {![string match "*PASS: adc_simulator_tb*" $simulator_log]} {
  error "ADC simulator simulation did not report PASS"
}

cd $original_dir
file delete -force $work_root
puts "MeterCore and ADC simulator mixed-language simulations PASS"
