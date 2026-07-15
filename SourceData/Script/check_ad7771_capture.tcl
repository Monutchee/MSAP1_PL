set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../..]]
set rtl_dir [file join $repo_dir SourceData DesignFile Ad7771Capture]

read_verilog -sv [file join $rtl_dir ad7771_receiver.sv]
read_verilog -sv [file join $rtl_dir ad7771_axi_regs.sv]
read_verilog -sv [file join $rtl_dir ad7771_capture.sv]
read_verilog [file join $rtl_dir Ad7771Capture_Wrapper.v]

synth_design -top Ad7771Capture_Wrapper -part xck26-sfvc784-2LV-c
report_utilization -file /tmp/ad7771_capture_utilization.rpt
report_cdc -file /tmp/ad7771_capture_cdc.rpt
