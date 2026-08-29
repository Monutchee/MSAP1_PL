# Focused verification for the M18 fixed packetizers and fair packet arbiter.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_m18_transport]

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
set original_dir [pwd]
cd $work_root

puts [exec $xvhdl --2008 \
  [file join $design_root MeterProcessing meter_r5_aggregation_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_fixed_packet_export.vhd] \
  [file join $design_root MeterProcessing meter_axis_packet_arbiter_5to1.vhd] \
  2>@1]
puts [exec $xvlog --sv [file join $design_root MeterProcessing tb \
  meter_r5_m18_transport_tb.sv] 2>@1]
puts [exec $xelab -a --mt off -L xpm meter_r5_m18_transport_tb \
  -s meter_r5_m18_transport_tb_sim 2>@1]
set axsim [file join $work_root xsim.dir meter_r5_m18_transport_tb_sim axsim]
set simulation_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $simulation_log
if {[string match "*FAIL:*" $simulation_log] ||
    ![string match "*PASS: meter_r5_m18_transport_tb*" $simulation_log]} {
  error "M18 transport simulation did not report PASS"
}

cd $original_dir
file delete -force $work_root
puts "M18 fixed packetizer and five-source arbiter PASS"
