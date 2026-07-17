set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../../..]]
set rtl_dir [file join $repo_dir SourceData DesignFile HeatBeat_Controller]
set testbench [file join $rtl_dir tb heartbeat_tb.sv]
set sim_dir [file join /tmp msap1_heartbeat_sim]

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

set original_dir [pwd]
file delete -force $sim_dir
file mkdir $sim_dir
cd $sim_dir

puts [exec $xvhdl --2008 \
    [file join $rtl_dir HeatBeat_Controller.vhd] 2>@1]
puts [exec $xvlog --sv $testbench 2>@1]
puts [exec $xelab -a --mt off heartbeat_tb \
    -s heartbeat_tb_sim 2>@1]

set axsim [file join $sim_dir xsim.dir heartbeat_tb_sim axsim]
set sim_output [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $sim_output
if {![string match "*PASS: heartbeat_tb*" $sim_output]} {
    error "Heartbeat simulation did not report PASS"
}

cd $original_dir
file delete -force $sim_dir

read_vhdl -vhdl2008 [file join $rtl_dir HeatBeat_Controller.vhd]
read_vhdl [file join $rtl_dir HeatBeat_Wrapper.vhd]
synth_design -top HeatBeat_Wrapper -part xck26-sfvc784-2LV-c
report_utilization -file /tmp/msap1_heartbeat_utilization.rpt
