# PL build stage 3: write_bitstream on the routed implementation.
#
# Resumes impl_1 at its remaining steps instead of resetting the run, so the
# routing produced by build_impl.tcl is programmed rather than recomputed.
# Vivado refuses to launch a run that is already complete, so an existing
# bitstream is reset one step -- write_bitstream only -- which keeps the stage
# idempotent without touching placement or routing.
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

if {[file exists $bitstream]} {
    reset_run impl_1 -from_step write_bitstream
}
# Never add or replace a hook after routing. New implementation runs already
# carry the stable WRITE_BITSTREAM hook installed by build_impl.tcl. An older
# routed run remains usable with Vivado's default worker-thread policy.
pl_build_launch_with_threads \
    impl_1 write_bitstream $jobs $threads WRITE_BITSTREAM false

if {![file exists $bitstream]} {
    error "write_bitstream reported success but $bitstream is missing"
}
puts "PL_BUILD_BITSTREAM=$bitstream"
puts "PL_BUILD_BITSTREAM_BYTES=[file size $bitstream]"

pl_build_timing_verdict impl_1
pl_build_power_summary impl_1

puts "PL_BUILD_STAGE_COMPLETE=bitstream"
pl_build_close_project
