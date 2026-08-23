# Runs inside a Vivado implementation worker before opt_design or
# write_bitstream. build_impl.tcl installs both stable hooks before resetting
# the run because changing either hook after routing makes Vivado mark the
# otherwise valid result Out-of-date. A general.maxThreads parameter set only
# in the parent process is not reliably inherited by the launch_runs worker.

if {[info exists ::env(PL_BUILD_PREVIOUS_TCL_PRE)] &&
        $::env(PL_BUILD_PREVIOUS_TCL_PRE) ne ""} {
    set previous_hook [file normalize $::env(PL_BUILD_PREVIOUS_TCL_PRE)]
    if {![file exists $previous_hook]} {
        error "configured Vivado pre-hook does not exist: $previous_hook"
    }
    source $previous_hook
}

if {![info exists ::env(VIVADO_THREADS)] ||
        ![string is integer -strict $::env(VIVADO_THREADS)] ||
        $::env(VIVADO_THREADS) < 1} {
    error "VIVADO_THREADS must be a positive integer"
}

set_param general.maxThreads $::env(VIVADO_THREADS)
puts "PL_BUILD_INTERNAL_THREADS=[get_param general.maxThreads]"
