# Focused end-to-end simulation for the FRQ1 ten-second observation path.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_frequency_10s_transport]

set xvhdl [lindex [auto_execok xvhdl] 0]
set xelab [lindex [auto_execok xelab] 0]
if {$xvhdl eq "" || $xelab eq ""} {
  error "Vivado simulator tools are not available in PATH"
}
set vivado_root [file dirname [file dirname [file normalize $xvhdl]]]
set simulator_libraries \
  [file join $vivado_root lib lnx64.o]:[file join $vivado_root lib lnx64.o Default]
if {[info exists ::env(LD_LIBRARY_PATH)] && $::env(LD_LIBRARY_PATH) ne ""} {
  append simulator_libraries :$::env(LD_LIBRARY_PATH)
}

file delete -force $work_root
file mkdir $work_root
set original_dir [pwd]
cd $work_root

puts [exec $xvhdl --2008 \
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_aggregation_pkg.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_pkg.vhd] \
  [file join $design_root MeterProcessing meter_unsigned_divider.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_conditioner.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_observer.vhd] \
  [file join $design_root MeterProcessing meter_r5_fixed_packet_export.vhd] \
  [file join $design_root MeterCore meter_time_control_axi_regs.vhd] \
  [file join $design_root MeterProcessing tb \
    meter_frequency_10s_transport_tb.vhd] \
  [file join $design_root MeterCore tb \
    meter_time_control_regs_tb.vhd] 2>@1]
puts [exec $xelab -a --mt off -L xpm meter_frequency_10s_transport_tb \
  -s meter_frequency_10s_transport_tb_sim 2>@1]
set axsim [file join $work_root xsim.dir \
  meter_frequency_10s_transport_tb_sim axsim]
set simulation_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $simulation_log
if {[string match "*Failure:*" $simulation_log] ||
    ![string match "*PASS: meter_frequency_10s_transport_tb*" \
      $simulation_log]} {
  error "frequency ten-second transport simulation did not report PASS"
}

puts [exec $xelab -a --mt off meter_time_control_regs_tb \
  -s meter_time_control_regs_tb_sim 2>@1]
set register_axsim [file join $work_root xsim.dir \
  meter_time_control_regs_tb_sim axsim]
set register_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $register_axsim 2>@1]
puts $register_log
if {[string match "*Failure:*" $register_log] ||
    ![string match "*PASS: meter_time_control_regs_tb*" \
      $register_log]} {
  error "frequency ten-second register simulation did not report PASS"
}

cd $original_dir
file delete -force $work_root
puts "frequency ten-second registers, observer, and FRQ1 transport PASS"
