set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../..]]
set rtl_dir [file join $repo_dir SourceData DesignFile Ad7771Capture]
set testbench [file join $rtl_dir tb ad7771_receiver_tb.sv]
set sim_dir [file join /tmp msap1_ad7771_receiver_sim]

# Run the self-checking receiver test before synthesis.  Use the standalone
# simulator executable because some Vivado 2025.2 Linux installations generate
# an xsim launcher with an incorrect library path.
set xvlog [lindex [auto_execok xvlog] 0]
set xelab [lindex [auto_execok xelab] 0]
if {$xvlog eq "" || $xelab eq ""} {
    error "Vivado simulator tools are not available in PATH"
}
set vivado_root [file dirname [file dirname [file normalize $xvlog]]]
set simulator_libraries \
    [file join $vivado_root lib lnx64.o]:[file join $vivado_root lib lnx64.o Default]
if {[info exists ::env(LD_LIBRARY_PATH)] && $::env(LD_LIBRARY_PATH) ne ""} {
    append simulator_libraries :$::env(LD_LIBRARY_PATH)
}

file delete -force $sim_dir
file mkdir $sim_dir
set original_dir [pwd]
cd $sim_dir
puts [exec $xvlog --sv \
    [file join $rtl_dir ad7771_receiver.sv] $testbench 2>@1]
puts [exec $xelab -a --mt off ad7771_receiver_tb \
    -s ad7771_receiver_tb_sim 2>@1]
set axsim [file join $sim_dir xsim.dir ad7771_receiver_tb_sim axsim]
set sim_output [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $sim_output
if {![string match "*PASS: ad7771_receiver_tb*" $sim_output]} {
    error "AD7771 receiver simulation did not report PASS"
}
cd $original_dir
file delete -force $sim_dir

read_verilog -sv [file join $rtl_dir ad7771_receiver.sv]
read_verilog -sv [file join $rtl_dir ad7771_axi_regs.sv]
read_verilog -sv [file join $rtl_dir ad7771_capture.sv]
read_verilog [file join $rtl_dir Ad7771Capture_Wrapper.v]

synth_design -top Ad7771Capture_Wrapper -part xck26-sfvc784-2LV-c
report_utilization -file /tmp/ad7771_capture_utilization.rpt
report_cdc -file /tmp/ad7771_capture_cdc.rpt
