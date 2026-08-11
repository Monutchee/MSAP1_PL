# PL build stage 3: write_bitstream on the routed implementation.
#
# Resumes impl_1 at its remaining steps instead of resetting the run, so the
# routing produced by build_impl.tcl is programmed rather than recomputed.
# Vivado refuses to launch a run that is already complete, so an existing
# bitstream is reset one step -- write_bitstream only -- which keeps the stage
# idempotent without touching placement or routing.
#
# Debug/standalone use (see build_common.tcl for the GUI rule):
#   vivado -mode batch -source SourceData/Script/build_bitstream.tcl -tclargs 16
#   source SourceData/Script/build_bitstream.tcl   ;# Vivado Tcl console
#
# Optional -tclargs <jobs>; otherwise VIVADO_JOBS, otherwise 8.

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
puts "PL_BUILD_STAGE=bitstream"
puts "PL_BUILD_JOBS=$jobs"

if {[file exists $bitstream]} {
    reset_run impl_1 -from_step write_bitstream
}
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
pl_build_finish_run impl_1

if {![file exists $bitstream]} {
    error "write_bitstream reported success but $bitstream is missing"
}
puts "PL_BUILD_BITSTREAM=$bitstream"

puts "PL_BUILD_STAGE_COMPLETE=bitstream"
pl_build_close_project
