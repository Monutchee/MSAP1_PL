set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../../..]]
set rtl_dir [file join $repo_dir SourceData DesignFile Ad7771Capture]
set receiver_testbench [file join $rtl_dir tb ad7771_receiver_tb.sv]
set capture_testbench [file join $rtl_dir tb ad7771_capture_tb.sv]
set receiver_sim_dir [file join /tmp msap1_ad7771_receiver_sim]
set capture_sim_dir [file join /tmp msap1_ad7771_capture_sim]

# Run the self-checking receiver test before synthesis.  Use the standalone
# simulator executable because some Vivado 2025.2 Linux installations generate
# an xsim launcher with an incorrect library path.
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

# The SystemVerilog receiver testbench binds directly to the VHDL-2008 DUT.
file delete -force $receiver_sim_dir
file mkdir $receiver_sim_dir
cd $receiver_sim_dir
puts [exec $xvhdl --2008 \
    [file join $rtl_dir ad7771_receiver.vhd] 2>@1]
puts [exec $xvlog --sv $receiver_testbench 2>@1]
puts [exec $xelab -a --mt off ad7771_receiver_tb \
    -s ad7771_receiver_tb_sim 2>@1]
set axsim [file join $receiver_sim_dir xsim.dir ad7771_receiver_tb_sim axsim]
set sim_output [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $sim_output
if {![string match "*PASS: ad7771_receiver_tb*" $sim_output]} {
    error "AD7771 receiver simulation did not report PASS"
}

# Exercise AXI-Lite control, the asynchronous width-converting FIFO,
# backpressure, packetization, and AXI4-Stream output with a SystemVerilog
# integration testbench. XPM simulation models reference the global module.
file delete -force $capture_sim_dir
file mkdir $capture_sim_dir
cd $capture_sim_dir
puts [exec $xvhdl --2008 \
    [file join $rtl_dir ad7771_receiver.vhd] \
    [file join $rtl_dir ad7771_axi_regs.vhd] \
    [file join $rtl_dir ad7771_capture.vhd] 2>@1]
puts [exec $xvlog --sv $capture_testbench 2>@1]
puts [exec $xvlog [file join $vivado_root data verilog src glbl.v] 2>@1]
puts [exec $xelab -a --mt off -L xpm ad7771_capture_tb glbl \
    -s ad7771_capture_tb_sim 2>@1]
set axsim [file join $capture_sim_dir xsim.dir ad7771_capture_tb_sim axsim]
set sim_output [exec env "LD_LIBRARY_PATH=$simulator_libraries" $axsim 2>@1]
puts $sim_output
if {![string match "*PASS: ad7771_capture_tb*" $sim_output]} {
    error "AD7771 capture simulation did not report PASS"
}

cd $original_dir
file delete -force $receiver_sim_dir
file delete -force $capture_sim_dir

read_vhdl -vhdl2008 [file join $rtl_dir ad7771_receiver.vhd]
read_vhdl -vhdl2008 [file join $rtl_dir ad7771_axi_regs.vhd]
read_vhdl -vhdl2008 [file join $rtl_dir ad7771_capture.vhd]
read_vhdl [file join $rtl_dir Ad7771Capture_Wrapper.vhd]

synth_design -top Ad7771Capture_Wrapper -part xck26-sfvc784-2LV-c
report_utilization -file /tmp/ad7771_capture_utilization.rpt
report_cdc -file /tmp/ad7771_capture_cdc.rpt
