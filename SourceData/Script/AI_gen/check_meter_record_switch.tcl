# Generate and simulate the same AMD AXI4-Stream Switch customization used by
# the compact four-producer meter-record transport. Every input holds three
# complete 64-beat records valid simultaneously while the output applies
# deterministic randomized backpressure.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set testbench [file join $project_root SourceData DesignFile MeterProcessing \
    tb meter_record_axis_switch_tb.sv]
set work_root [file join /tmp msap1_meter_record_switch_sim]

file delete -force $work_root
file mkdir $work_root
create_project -force [file join $work_root project] \
    -part xck26-sfvc784-2LV-c
create_ip -name axis_switch -vendor xilinx.com -library ip -version 1.1 \
    -module_name meter_record_axis_switch
set switch_ip [get_ips meter_record_axis_switch]
set_property -dict [list \
    CONFIG.NUM_SI {4} \
    CONFIG.NUM_MI {1} \
    CONFIG.TDATA_NUM_BYTES {4} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.ARB_ON_TLAST {1} \
    CONFIG.ARB_ON_MAX_XFERS {0} \
    CONFIG.ARB_ON_NUM_CYCLES {0} \
    CONFIG.ARB_ALGORITHM {3}] $switch_ip
generate_target all $switch_ip

set switch_model [file join $work_root project.gen sources_1 ip \
    meter_record_axis_switch sim meter_record_axis_switch.v]
if {![file exists $switch_model]} {
    error "Generated AXIS switch simulation model was not found"
}

close_project

# Use the same direct axsim launcher as the other focused PL checks. The
# debugger-backed project launcher raises an internal XSim exception for this
# encrypted/precompiled IP combination in Vivado 2025.2, while the compiled
# simulation kernel runs it correctly.
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

set original_dir [pwd]
set sim_root [file join $work_root direct]
file mkdir $sim_root
cd $sim_root
puts [exec $xvlog $switch_model 2>@1]
puts [exec $xvlog --sv $testbench 2>@1]
puts [exec $xelab -a --mt off \
    -L axis_infrastructure_v1_1_1 \
    -L axis_register_slice_v1_1_35 \
    -L axis_switch_v1_1_35 \
    meter_record_axis_switch_tb \
    -s meter_record_axis_switch_tb_sim 2>@1]
set axsim [file join $sim_root xsim.dir meter_record_axis_switch_tb_sim axsim]
set simulation_log [exec env "LD_LIBRARY_PATH=$simulator_libraries" \
    $axsim 2>@1]
puts $simulation_log
if {![string match "*PASS: meter_record_axis_switch_tb*" $simulation_log]} {
    error "Meter-record AXIS switch simulation did not report PASS"
}

cd $original_dir
file delete -force $work_root
puts "Four-input meter-record AXIS switch simulation PASS"
