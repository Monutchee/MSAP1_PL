# PL build stage 3: write_bitstream on the routed implementation.
#
# Opens the completed routed checkpoint and writes the bitstream directly.
# This deliberately avoids relaunching impl_1: Vivado fingerprints run-hook
# properties and can report the run as Out-of-date after a temporary worker
# thread hook changes, even though route_design and Bitgen both completed.
# The routed DCP is the stage boundary, so writing from it is deterministic,
# idempotent, and cannot reset or repeat placement and routing.
#
# Debug/standalone use (see build_common.tcl for the GUI rule):
#   vivado -mode batch -source SourceData/Script/build_bitstream.tcl -tclargs 1 16
#   source SourceData/Script/build_bitstream.tcl   ;# Vivado Tcl console
#
# Optional -tclargs <jobs> <threads>; otherwise VIVADO_JOBS and
# VIVADO_THREADS, with defaults of 8 for each.

source [file join [file dirname [file normalize [info script]]] build_common.tcl]

pl_build_open_project

set top [pl_build_top]
set run_dir [pl_build_run_dir impl_1]
set routed [file join $run_dir "${top}_routed.dcp"]
set bitstream [file join $run_dir "${top}.bit"]

if {![file exists $routed]} {
    error "no routed checkpoint at $routed -- run 'mnc PL build --compile-impl' first"
}

set jobs [pl_build_jobs]
set threads [pl_build_threads]
puts "PL_BUILD_STAGE=bitstream"
puts "PL_BUILD_JOBS=$jobs"
puts "PL_BUILD_THREADS=$threads"

# Bitgen runs in this Vivado process rather than a launch_runs worker, so the
# requested internal-thread setting applies directly and no run property must
# be changed. Close a design left open by an interactive caller before loading
# the routed checkpoint.
set_param general.maxThreads $threads
if {[current_design -quiet] ne ""} {
    close_design
}

set started [clock seconds]
set failed [catch {
    open_checkpoint $routed
    write_bitstream -force $bitstream
} result options]
catch {close_design}

if {$failed} {
    return -options $options $result
}

puts "PL_BUILD_RUN=impl_1"
puts "PL_BUILD_ELAPSED=[pl_build_elapsed [expr {[clock seconds] - $started}]]"
puts "PL_BUILD_STATUS=write_bitstream Complete!"

if {![file exists $bitstream]} {
    error "write_bitstream reported success but $bitstream is missing"
}
puts "PL_BUILD_BITSTREAM=$bitstream"
puts "PL_BUILD_BITSTREAM_BYTES=[file size $bitstream]"

pl_build_timing_verdict impl_1
pl_build_power_summary impl_1

puts "PL_BUILD_STAGE_COMPLETE=bitstream"
pl_build_close_project
