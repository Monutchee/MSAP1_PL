# Focused regression proving that optional SCYC diagnostic backpressure cannot
# stall the authoritative single-cycle result stream sent to R5C1.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_single_cycle_diag_isolation]

set hls_scyc_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SingleCycleEngine hdl verilog]
if {![file isdirectory $hls_scyc_hdl]} {
  error "missing $hls_scyc_hdl -- run 'mnc HLS build' first"
}

set hls_scyc_verilog [concat \
  [lsort [glob -directory $hls_scyc_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_single_cycle_engine_ip.v]]]

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
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root MeterProcessing meter_single_cycle_hls_shim.vhd] \
  2>@1]
puts [exec $xvlog -i $hls_scyc_hdl {*}$hls_scyc_verilog 2>@1]

foreach rom_image [glob -nocomplain -directory $hls_scyc_hdl *.dat] {
  file copy -force $rom_image [file join $work_root [file tail $rom_image]]
}

set testbench [file join $design_root MeterProcessing tb \
  meter_single_cycle_diag_isolation_tb.sv]
puts [exec $xvlog --sv $testbench 2>@1]
puts [exec $xelab -a --mt off meter_single_cycle_diag_isolation_tb \
  -s meter_single_cycle_diag_isolation_tb_sim 2>@1]

set axsim [file join $work_root xsim.dir \
  meter_single_cycle_diag_isolation_tb_sim axsim]
set simulation_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $simulation_log
if {[string first "PASS:" $simulation_log] < 0} {
  error "diagnostic-isolation regression did not report PASS:\n$simulation_log"
}

cd $original_dir
puts "Single-cycle diagnostic isolation PASS"
