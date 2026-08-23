# Stable impl_1 OPT_DESIGN pre-hook. A parent set_param is not reliably
# inherited by the launch_runs worker, so the requested value crosses the
# process boundary in VIVADO_THREADS. Use the normal project default when an
# engineer launches implementation directly from the Vivado GUI.

set threads 8
if {[info exists ::env(VIVADO_THREADS)] && $::env(VIVADO_THREADS) ne ""} {
    set threads $::env(VIVADO_THREADS)
}
if {![string is integer -strict $threads] || $threads < 1} {
    error "VIVADO_THREADS must be a positive integer"
}

set_param general.maxThreads $threads
puts "PL_BUILD_INTERNAL_THREADS=[get_param general.maxThreads]"
