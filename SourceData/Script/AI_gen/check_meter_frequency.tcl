# Focused VLA zero-crossing and frequency-estimator simulation.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_meter_frequency_sim]

set xvlog [lindex [auto_execok xvlog] 0]
set xvhdl [lindex [auto_execok xvhdl] 0]
set xelab [lindex [auto_execok xelab] 0]
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

set sources [list \
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root MeterProcessing meter_frequency_pkg.vhd] \
  [file join $design_root MeterProcessing meter_unsigned_divider.vhd] \
  [file join $design_root MeterProcessing meter_zero_crossing.vhd] \
  [file join $design_root MeterProcessing meter_frequency_estimator.vhd] \
  [file join $design_root MeterProcessing meter_frequency.vhd]]
puts [exec $xvhdl --2008 {*}$sources 2>@1]
puts [exec $xvlog --sv \
  [file join $design_root MeterProcessing tb meter_frequency_tb.sv] 2>@1]
puts [exec $xelab -a --mt off -L xpm meter_frequency_tb \
  -s meter_frequency_tb_sim 2>@1]

set axsim [file join $work_root xsim.dir meter_frequency_tb_sim axsim]
set simulation_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $simulation_log
if {![string match "*PASS: meter_frequency_tb*" $simulation_log]} {
  error "Frequency simulation did not report PASS"
}

cd $original_dir
file delete -force $work_root
puts "Frequency simulation PASS"
