# A4 harmonic sizing flow.  This is intentionally independent of MSAP1_PL.xpr
# and never modifies the production block design or IP catalog.

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ../../..]]

if {[llength $argv] != 1 || [lindex $argv 0] ni {4k 32k}} {
    error "usage: vivado -mode batch -source run_harmonic_sizing.tcl -tclargs 4k|32k"
}

set variant [lindex $argv 0]
if {$variant eq "4k"} {
    set fft_length 4096
    set window_samples 3200
    set analysis_rate_hz 16000
} else {
    set fft_length 32768
    set window_samples 25600
    set analysis_rate_hz 128000
}

set part xck26-sfvc784-2LV-c
set output_dir [file normalize [file join $repo_root vivado_gen a4_harmonic_sizing $variant]]
file mkdir $output_dir

# Deterministic Q1.17 Hann coefficients.  The zero-padded tail belongs to the
# FFT input scheduler and therefore is not stored in this ROM.
set window_file [file join $output_dir hann.mem]
set fd [open $window_file w]
set pi [expr {acos(-1.0)}]
set coefficient_max [expr {(1 << 17) - 1}]
for {set i 0} {$i < $window_samples} {incr i} {
    set phase [expr {2.0 * $pi * $i / ($window_samples - 1)}]
    set coefficient [expr {round((0.5 - 0.5 * cos($phase)) * $coefficient_max)}]
    puts $fd [format %05X $coefficient]
}
close $fd

create_project -force a4_harmonic_sizing [file join $output_dir project] -part $part
set_property target_language Verilog [current_project]

add_files -norecurse [list \
    [file join $script_dir spectral_frontend.sv] \
    [file join $script_dir a4_harmonic_sizing_top.sv] \
    $window_file]
add_files -fileset constrs_1 -norecurse [file join $script_dir a4_harmonic_sizing.xdc]
set_property file_type {Memory Initialization Files} [get_files $window_file]
set_property verilog_define [list \
    A4_FFT_LENGTH=$fft_length \
    A4_WINDOW_SAMPLES=$window_samples] [get_filesets sources_1]
set_property top a4_harmonic_sizing_top [get_filesets sources_1]

create_ip -name xfft -vendor xilinx.com -library ip -version 9.1 -module_name a4_xfft
set_property -dict [list \
    CONFIG.channels {1} \
    CONFIG.transform_length $fft_length \
    CONFIG.implementation_options {radix_2_lite_burst_io} \
    CONFIG.input_width {24} \
    CONFIG.phase_factor_width {24} \
    CONFIG.data_format {fixed_point} \
    CONFIG.scaling_options {scaled} \
    CONFIG.output_ordering {bit_reversed_order} \
    CONFIG.memory_options_data {block_ram} \
    CONFIG.memory_options_phase_factors {block_ram} \
    CONFIG.memory_options_reorder {block_ram} \
    CONFIG.butterfly_type {use_luts} \
    CONFIG.complex_mult_type {use_mults_resources} \
    CONFIG.aresetn {true} \
    CONFIG.target_clock_frequency {100}] [get_ips a4_xfft]
generate_target all [get_ips a4_xfft]

# The project contains only the isolated A4 wrapper, so the normal project
# synthesis run is itself the out-of-context sizing boundary.  Vivado 2025.2
# does not expose STEPS.SYNTH_DESIGN.ARGS.MODE on a project synthesis run.
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "A4 $variant synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

open_run synth_1
report_utilization -file [file join $output_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 \
    -file [file join $output_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $output_dir timing_summary.rpt]

set summary_fd [open [file join $output_dir configuration.txt] w]
puts $summary_fd "variant=$variant"
puts $summary_fd "part=$part"
puts $summary_fd "analysis_rate_hz=$analysis_rate_hz"
puts $summary_fd "window_samples=$window_samples"
puts $summary_fd "fft_length=$fft_length"
puts $summary_fd "channels=7"
puts $summary_fd "sample_width=24"
puts $summary_fd "buffer_banks=2"
puts $summary_fd "fft_architecture=radix_2_lite_burst_io"
close $summary_fd

puts "A4 $variant reports: $output_dir"
