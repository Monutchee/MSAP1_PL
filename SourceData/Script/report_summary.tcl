# Vivado's own run summary for each run: the numbers behind the GUI's Design
# Runs columns -- WNS, TNS, WHS, THS, failed routes, power, and whatever else
# this Vivado release records as run statistics.
#
# The statistics are read from the run objects, so no design is opened and no
# report is regenerated: this is what the last completed run produced. Runs
# that never completed have no statistics and are listed as such.
#
# Opens the project read-only, so it is safe to run while the project is open
# in a Vivado GUI.
#
# Debug/standalone use:
#   vivado -mode batch -source SourceData/Script/report_summary.tcl
#   source SourceData/Script/report_summary.tcl   ;# Vivado Tcl console

source [file join [file dirname [file normalize [info script]]] build_common.tcl]

pl_build_open_project read

pl_build_report_begin

puts "PL_SUMMARY_PROJECT=$pl_build_project_file"
puts "PL_SUMMARY_TOP=[pl_build_top]"

set idle 0
foreach run [pl_build_runs] {
    set object [get_runs $run]
    set status [pl_build_property $object STATUS]

    # Vivado defines the statistics on every run, so a run that never started
    # prints a full block of n/a. Skip the out-of-context runs in that state;
    # the two top-level runs are always worth a line, started or not.
    if {$run ni {synth_1 impl_1} && $status eq "Not started"} {
        incr idle
        continue
    }

    puts ""
    puts "$run"
    puts [format "  %-26s %s" status $status]
    foreach property {PROGRESS STRATEGY FLOW INCREMENTAL_CHECKPOINT} {
        set value [pl_build_property $object $property]
        if {$value ne "n/a"} {
            puts [format "  %-26s %s" [string tolower $property] $value]
        }
    }

    # Only the statistics this run actually recorded: synthesis has no timing
    # or power numbers, and printing a dozen n/a lines hides the ones it has.
    set reported 0
    foreach property [pl_build_properties $object STATS.*] {
        set value [pl_build_property $object $property]
        if {$value eq "n/a"} {
            continue
        }
        incr reported
        puts [format "  %-26s %s" \
            [string tolower [string range $property 6 end]] $value]
    }
    if {$reported == 0} {
        puts "  (no statistics recorded yet)"
    }
}
if {$idle > 0} {
    puts ""
    puts "($idle out-of-context run(s) not started)"
}

pl_build_report_end
pl_build_close_project
