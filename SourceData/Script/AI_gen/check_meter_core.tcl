# Standalone mixed-language integration verification for MeterCore.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_meter_core_sim]

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
  [file join $design_root MeterProcessing meter_rms.vhd]]
set dependency_wrappers [list \
  [file join $design_root MeterProcessing MeterResultHub_Wrapper.vhd] \
  [file join $design_root MeterProcessing MeterPacketizer_Wrapper.vhd]]
set core_vhdl2008_sources [list \
  [file join $design_root MeterCore meter_core.vhd]]
set boundary_wrapper [file join $design_root MeterCore MeterCore_Wrapper.vhd]
set testbench [file join $design_root MeterCore tb meter_core_tb.sv]

file delete -force $work_root
file mkdir $work_root
set original_dir [pwd]
cd $work_root

puts [exec $xvhdl --2008 {*}$vhdl2008_sources 2>@1]
puts [exec $xvhdl {*}$dependency_wrappers 2>@1]
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

cd $original_dir
file delete -force $work_root
puts "MeterCore mixed-language integration simulation PASS"
