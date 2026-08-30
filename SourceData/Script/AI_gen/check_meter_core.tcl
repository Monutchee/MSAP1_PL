# Standalone mixed-language integration verification for MeterCore.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_meter_core_sim]

# Packaged HLS RTL (IP repository entry); refreshed by 'mnc HLS build' or
# SourceData/HLS_DesignFile/run_hls.sh <component>.
set hls_pq_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SlidingOneCycleRmsEngine hdl verilog]
if {![file isdirectory $hls_pq_hdl]} {
  error "missing $hls_pq_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_pq_verilog [concat \
  [lsort [glob -directory $hls_pq_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_sliding_one_cycle_rms_engine_ip.v]]]
set hls_sim_wave_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SimWaveEngine hdl verilog]
if {![file isdirectory $hls_sim_wave_hdl]} {
  error "missing $hls_sim_wave_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_sim_wave_verilog [concat \
  [lsort [glob -directory $hls_sim_wave_hdl *.v]] \
  [list [file join $design_root MeterCore tb hls_sim_wave_engine_ip.v]]]
set hls_scyc_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo SingleCycleEngine hdl verilog]
if {![file isdirectory $hls_scyc_hdl]} {
  error "missing $hls_scyc_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_scyc_verilog [concat \
  [lsort [glob -directory $hls_scyc_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_single_cycle_engine_ip.v]]]
set hls_harmonic_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo HarmonicEngine hdl verilog]
if {![file isdirectory $hls_harmonic_hdl]} {
  error "missing $hls_harmonic_hdl -- run 'mnc HLS build' or HLS_DesignFile/run_hls.sh first"
}
set hls_harmonic_verilog [concat \
  [lsort [glob -directory $hls_harmonic_hdl *.v]] \
  [list [file join $design_root MeterProcessing tb hls_harmonic_engine_ip.v]]]

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

set vhdl2008_sources [list \
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root MeterCommon grid_timing_pkg.vhd] \
  [file join $design_root MeterCommon pq_event_pkg.vhd] \
  [file join $design_root MeterCommon measurement_record_bus_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_power_quality_protocol_pkg.vhd] \
  [file join $design_root Ad7771Capture ad7771_receiver.vhd] \
  [file join $design_root Ad7771Capture ad7771_axi_regs.vhd] \
  [file join $design_root Ad7771Capture ad7771_dclk_meter.vhd] \
  [file join $design_root Ad7771Capture ad7771_capture.vhd] \
  [file join $design_root AdcConversion adc_conversion_axi_regs.vhd] \
  [file join $design_root AdcConversion adc_conversion.vhd] \
  [file join $design_root MeterProcessing meter_frequency_pkg.vhd] \
  [file join $design_root MeterProcessing meter_processing_axi_regs.vhd] \
  [file join $design_root MeterProcessing meter_unsigned_divider.vhd] \
  [file join $design_root MeterProcessing meter_zero_crossing.vhd] \
  [file join $design_root MeterProcessing meter_frequency_estimator.vhd] \
  [file join $design_root MeterProcessing meter_frequency.vhd] \
  [file join $design_root MeterProcessing grid_cycle_timing.vhd] \
  [file join $design_root MeterProcessing record_word_tap.vhd] \
  [file join $design_root MeterProcessing meter_r5_aggregation_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_harmonic_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_harmonic_export.vhd] \
  [file join $design_root MeterProcessing meter_axis_packet_arbiter_2to1.vhd] \
  [file join $design_root MeterProcessing meter_r5_fixed_packet_export.vhd] \
  [file join $design_root MeterProcessing meter_axis_packet_arbiter_5to1.vhd] \
  [file join $design_root MeterProcessing meter_r5_aggregation_export.vhd] \
  [file join $design_root MeterProcessing meter_single_cycle_hls_shim.vhd] \
  [file join $design_root MeterProcessing meter_sliding_rms_hls_shim.vhd] \
  [file join $design_root MeterProcessing meter_voltage_sample_batcher.vhd] \
  [file join $design_root MeterProcessing meter_spectral_conditioner.vhd] \
  [file join $design_root MeterProcessing meter_spectral_frontend.vhd] \
  [file join $design_root MeterProcessing meter_harmonic_hls_shim.vhd] \
  [file join $design_root MeterCore adc_simulator_pkg.vhd] \
  [file join $design_root MeterCore adc_simulator.vhd] \
  [file join $design_root MeterCore adc_source_mux.vhd] \
  [file join $design_root MeterCore meter_waveform_axi_regs.vhd] \
  [file join $design_root MeterCore meter_waveform.vhd]]
set core_vhdl2008_sources [list \
  [file join $design_root MeterCore meter_core.vhd]]
set boundary_wrapper [file join $design_root MeterCore MeterCore_Wrapper.vhd]
set simulator_testbench [file join $design_root MeterCore tb adc_simulator_tb.sv]
set spectral_testbench [file join $design_root MeterProcessing tb \
  meter_spectral_frontend_tb.sv]
set conditioner_testbench [file join $design_root MeterProcessing tb \
  meter_spectral_conditioner_tb.sv]
set conditioner_context_snapshot_testbench [file join $design_root \
  MeterProcessing tb meter_spectral_context_snapshot_tb.sv]
set conditioner_profiles_testbench [file join $design_root MeterProcessing tb \
  meter_spectral_profiles_tb.sv]
set conditioner_coefficients [file join $design_root MeterProcessing \
  meter_spectral_conditioner_q20.mem]
set conditioner_response_check [file join $design_root MeterProcessing tb \
  verify_spectral_conditioner.py]

file delete -force $work_root
file mkdir $work_root
# ROM initialization images referenced by the packaged HLS RTL via
# relative $readmemh paths -- xsim resolves them against the working
# directory, so stage them beside the compiled snapshot. Sweep EVERY
# packaged engine (sim-wave sine LUT, single-cycle trig LUT, the M9
# CORDIC atan table, anything future).
foreach hdl_dir [list $hls_sim_wave_hdl $hls_scyc_hdl $hls_pq_hdl \
                      $hls_harmonic_hdl] {
  foreach rom_image [glob -nocomplain -directory $hdl_dir *.dat] {
    file copy -force $rom_image $work_root
  }
}
file copy -force $conditioner_coefficients $work_root
puts [exec python3 $conditioner_response_check 2>@1]
set original_dir [pwd]
cd $work_root

puts [exec $xvhdl --2008 {*}$vhdl2008_sources 2>@1]
puts [exec $xvlog -i $hls_sim_wave_hdl {*}$hls_sim_wave_verilog 2>@1]
puts [exec $xvlog -i $hls_scyc_hdl {*}$hls_scyc_verilog 2>@1]
puts [exec $xvlog -i $hls_pq_hdl {*}$hls_pq_verilog 2>@1]
puts [exec $xvlog -i $hls_harmonic_hdl {*}$hls_harmonic_verilog 2>@1]
puts [exec $xvhdl --2008 {*}$core_vhdl2008_sources 2>@1]
puts [exec $xvhdl $boundary_wrapper 2>@1]
puts [exec $xvlog [file join $vivado_root data verilog src glbl.v] 2>@1]
puts [exec $xvlog --sv $simulator_testbench 2>@1]
puts [exec $xvlog --sv $spectral_testbench $conditioner_testbench \
  $conditioner_context_snapshot_testbench \
  $conditioner_profiles_testbench 2>@1]
puts [exec $xelab -a --mt off adc_simulator_tb \
  -s adc_simulator_tb_sim 2>@1]
set simulator_axsim [file join $work_root xsim.dir adc_simulator_tb_sim axsim]
set simulator_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $simulator_axsim 2>@1]
puts $simulator_log
if {![string match "*PASS: adc_simulator_tb*" $simulator_log]} {
  error "ADC simulator simulation did not report PASS"
}

# The M16 frontend TB uses its small behavioral banks; production keeps the
# default XPM BRAM implementation, which is checked by the focused OOC synth.
puts [exec $xelab -a --mt off meter_spectral_frontend_tb \
  -s meter_spectral_frontend_tb_sim 2>@1]
set spectral_axsim \
  [file join $work_root xsim.dir meter_spectral_frontend_tb_sim axsim]
set spectral_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $spectral_axsim 2>@1]
puts $spectral_log
if {[string match "*FAIL:*" $spectral_log] ||
    ![string match "*meter_spectral_frontend PASS*" $spectral_log]} {
  error "M16 spectral frontend simulation did not report PASS"
}

puts [exec $xelab -a --mt off -L xpm meter_spectral_conditioner_tb \
  -s meter_spectral_conditioner_tb_sim 2>@1]
set conditioner_axsim \
  [file join $work_root xsim.dir meter_spectral_conditioner_tb_sim axsim]
set conditioner_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" $conditioner_axsim 2>@1]
puts $conditioner_log
if {[string match "*FAIL:*" $conditioner_log] ||
    ![string match "*meter_spectral_conditioner PASS*" $conditioner_log]} {
  error "M16 spectral conditioner simulation did not report PASS"
}
puts [exec $xelab -a --mt off -L xpm \
  meter_spectral_context_snapshot_tb \
  -s meter_spectral_context_snapshot_tb_sim 2>@1]
set conditioner_context_snapshot_axsim [file join $work_root xsim.dir \
  meter_spectral_context_snapshot_tb_sim axsim]
set conditioner_context_snapshot_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" \
    $conditioner_context_snapshot_axsim 2>@1]
puts $conditioner_context_snapshot_log
if {[string match "*FAIL:*" $conditioner_context_snapshot_log] ||
    ![string match "*meter_spectral_context_snapshot PASS*" \
      $conditioner_context_snapshot_log]} {
  error "spectral context snapshot simulation did not report PASS"
}

puts [exec $xelab -a --mt off -L xpm meter_spectral_profiles_tb \
  -s meter_spectral_profiles_tb_sim 2>@1]
set conditioner_profiles_axsim \
  [file join $work_root xsim.dir meter_spectral_profiles_tb_sim axsim]
set conditioner_profiles_log \
  [exec env "LD_LIBRARY_PATH=$simulator_libraries" \
    $conditioner_profiles_axsim 2>@1]
puts $conditioner_profiles_log
if {[string match "*FAIL:*" $conditioner_profiles_log] ||
    ![string match "*meter_spectral_profiles PASS*" \
      $conditioner_profiles_log]} {
  error "M16 adaptive spectral profile sweep did not report PASS"
}

# Elaborate the production configuration explicitly and prove that the
# simulator-disabled shape still binds.
set disabled_log [exec $xelab --mt off -L xpm MeterCore_Wrapper glbl \
  -generic_top "G_SIMULATOR_ENABLE=false" \
  -s meter_core_sim_disabled 2>@1]
puts $disabled_log
puts "MeterCore production simulator-disabled elaboration PASS"

cd $original_dir
file delete -force $work_root
puts "MeterCore elaboration, ADC simulator, and M16 spectral simulations PASS"
