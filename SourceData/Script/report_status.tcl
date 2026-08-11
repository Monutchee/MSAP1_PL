# Where the PL build stands: what passed, what is out of date, what errored.
#
# The same facts the GUI's Design Runs window shows, for the shell:
# per-run status, progress, and the out-of-date flag, plus block-design
# products, trailing IP customizations, and whether a bitstream exists.
#
# Opens the project read-only, so it is safe to run while the project is open
# in a Vivado GUI and cannot save over that session's state.
#
# Debug/standalone use:
#   vivado -mode batch -source SourceData/Script/report_status.tcl
#   source SourceData/Script/report_status.tcl   ;# Vivado Tcl console

source [file join [file dirname [file normalize [info script]]] build_common.tcl]

pl_build_open_project read

pl_build_report_begin

set top [pl_build_top]
puts "PL_STATUS_PROJECT=$pl_build_project_file"
puts "PL_STATUS_PART=[pl_build_property [current_project] PART]"
puts "PL_STATUS_TOP=$top"

set bd [pl_build_block_design]
set products [pl_build_block_design_products $bd]
if {$products eq ""} {
    puts "PL_STATUS_BD=not generated ([file tail $bd]) -- run mnc PL build --build-bd"
} else {
    puts "PL_STATUS_BD=generated ([file tail $bd])"
}

# A read-only open reports every IP as locked, because none of them can be
# regenerated in that state -- a count from here would be pure noise. When
# this script is sourced into a session that already holds the project open
# for writing, the same query is trustworthy, so report it then.
if {$pl_build_read_only} {
    puts "PL_STATUS_LOCKED_IP=not checked (read-only open reports every IP locked)"
} else {
    set locked [pl_build_locked_ips]
    puts "PL_STATUS_LOCKED_IP=[llength $locked]"
    foreach ip $locked {
        puts "PL_STATUS_LOCKED_IP_NAME=$ip"
    }
}

# One line per run. The out-of-context block-design and IP run names are long
# and vary per design, so size the column to the widest actual name rather
# than to a constant that a new module reference would overflow.
set runs [pl_build_runs]
set width 12
foreach run $runs {
    if {[string length $run] > $width} {
        set width [string length $run]
    }
}
set row "%-${width}s %-28s %-9s %s"

puts ""
puts [format $row run status progress out-of-date]
puts [format $row [string repeat - $width] [string repeat - 28] \
    [string repeat - 9] [string repeat - 11]]

set errored {}
set stale {}
set idle 0
foreach run $runs {
    set status [pl_build_property [get_runs $run] STATUS]
    set progress [pl_build_property [get_runs $run] PROGRESS]
    set refresh [pl_build_property [get_runs $run] NEEDS_REFRESH]

    # Vivado reports staleness two ways: the NEEDS_REFRESH property, and an
    # "Out-of-date" run status. Either means the run no longer matches its
    # sources.
    set outdated no
    if {$refresh eq "1" || [string match -nocase "*out-of-date*" $status]} {
        set outdated yes
        lappend stale $run
    }
    if {[string match -nocase "*error*" $status]} {
        lappend errored $run
    }

    # The out-of-context runs Vivado creates per block-design IP include impl
    # runs that this flow never launches. Listing a dozen "Not started" rows
    # buries the two runs that matter; count them instead.
    if {$run ni {synth_1 impl_1} && $status eq "Not started"} {
        incr idle
        continue
    }
    puts [format $row $run $status $progress $outdated]
}
if {$idle > 0} {
    puts "($idle out-of-context run(s) not started)"
}
puts ""

set synth_status [pl_build_property [get_runs synth_1] STATUS]
set impl_status [pl_build_property [get_runs impl_1] STATUS]
puts "PL_STATUS_SYNTH=$synth_status"
puts "PL_STATUS_IMPL=$impl_status"

set routed [file join [pl_build_run_dir impl_1] "${top}_routed.dcp"]
set bitstream [file join [pl_build_run_dir impl_1] "${top}.bit"]
puts "PL_STATUS_ROUTED=[expr {[file exists $routed] ? $routed : "missing"}]"
puts "PL_STATUS_BITSTREAM=[expr {[file exists $bitstream] ? $bitstream : "missing"}]"

# A single machine-readable answer to "what do I have to rerun", worst first.
# Staleness outranks incompleteness: an out-of-date run reads as incomplete
# because "Out-of-date" is not "Complete", and "rerun it" is the useful
# answer either way, but only one of the two names the actual problem.
if {[llength $errored] > 0} {
    puts "PL_STATUS_VERDICT=error ($errored)"
} elseif {[llength $stale] > 0} {
    puts "PL_STATUS_VERDICT=out of date ($stale) -- rerun from mnc PL build --compile-synth"
} elseif {![string match "*Complete*" $synth_status]} {
    puts "PL_STATUS_VERDICT=synthesis incomplete -- run mnc PL build --compile-synth"
} elseif {![file exists $routed]} {
    puts "PL_STATUS_VERDICT=not implemented -- run mnc PL build --compile-impl"
} elseif {![file exists $bitstream]} {
    puts "PL_STATUS_VERDICT=routed, no bitstream -- run mnc PL build --compile-bit"
} else {
    puts "PL_STATUS_VERDICT=ok"
}

pl_build_report_end
pl_build_close_project
