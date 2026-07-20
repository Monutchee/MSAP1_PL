# Focused mixed-language verification for the software-configured metering RTL.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_metering_pipeline]

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
  [file join $design_root AdcConversion adc_conversion_axi_regs.vhd] \
  [file join $design_root AdcConversion adc_conversion.vhd] \
  [file join $design_root MeterProcessing meter_processing_axi_regs.vhd] \
  [file join $design_root MeterProcessing voltage_rms.vhd] \
  [file join $design_root MeterProcessing MeterResultHub_Wrapper.vhd] \
  [file join $design_root MeterProcessing MeterPacketizer_Wrapper.vhd]]

set wrapper_vhdl [list \
  [file join $design_root AdcConversion AdcConversion_Wrapper.vhd] \
  [file join $design_root MeterProcessing CurrentRms_Wrapper.vhd] \
  [file join $design_root MeterProcessing VoltageRms_Wrapper.vhd]]

proc run_test {work_root test_name common_vhdl wrapper_vhdl testbench xvhdl xvlog xelab simulator_libraries} {
  set test_dir [file join $work_root $test_name]
  file mkdir $test_dir
  set original_dir [pwd]
  cd $test_dir
  puts [exec $xvhdl --2008 {*}$common_vhdl 2>@1]
  puts [exec $xvhdl {*}$wrapper_vhdl 2>@1]
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
run_test $work_root voltage_rms_tb $common_vhdl $wrapper_vhdl \
  [file join $design_root MeterProcessing tb voltage_rms_tb.sv] \
  $xvhdl $xvlog $xelab $simulator_libraries
run_test $work_root meter_packet_tb $common_vhdl $wrapper_vhdl \
  [file join $design_root MeterProcessing tb meter_packet_tb.sv] \
  $xvhdl $xvlog $xelab $simulator_libraries

puts "All metering pipeline simulations PASS"
