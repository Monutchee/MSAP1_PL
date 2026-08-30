# Focused simulation for orderly waveform DMA close/reopen semantics.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_meter_waveform_sim]

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
  [file join $design_root MeterCore meter_waveform.vhd] \
  [file join $design_root MeterCore tb meter_waveform_tb.vhd] 2>@1]
puts [exec $xelab -a --mt off -L xpm meter_waveform_tb \
  -s meter_waveform_tb_sim 2>@1]
set axsim [file join $work_root xsim.dir meter_waveform_tb_sim axsim]
set simulation_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $simulation_log
if {[string match "*FAILURE*" $simulation_log] ||
    ![string match "*PASS: meter_waveform disable flushes partial packet*" \
      $simulation_log]} {
  error "meter_waveform simulation did not report PASS"
}

cd $original_dir
puts "meter_waveform close/reopen verification passed"
