# Shared preamble for the staged PL build scripts.
#
# Sourced by build_synth.tcl, build_impl.tcl, build_bitstream.tcl, and
# export_xsa.tcl. It owns the project location, the open/close policy, the
# -jobs count, run-status checking, and the report directory, so each stage
# script stays short enough to read and debug on its own.
#
# Every stage script runs either standalone
# (vivado -mode batch -source SourceData/Script/build_<stage>.tcl) or sourced
# from the Tcl console of a session that already has the product project open.
# The GUI case matters: Vivado does not lock projects, and a live GUI session
# saves its own in-memory state over any batch edit, so with the GUI open the
# stage must run inside it. A script that opened the project itself closes it
# again; one sourced into an open session leaves it open.
#
# Stage scripts that launch a run take the -jobs value as their first
# -tclargs value (see pl_build_jobs); export_xsa.tcl takes an output path
# instead. Failures raise a Tcl error so batch Vivado exits non-zero and
# make_PL.sh can chain stages.

set pl_build_script_dir [file dirname [file normalize [info script]]]
set pl_build_repo_dir [file normalize [file join $pl_build_script_dir ../..]]
set pl_build_project_file \
    [file join $pl_build_repo_dir vivado_gen MSAP1_PL.xpr]
set pl_build_report_dir [file join $pl_build_repo_dir vivado_gen reports]
set pl_build_close_project_when_done false
set pl_build_read_only false

# Open the product project unless this session already has it open. Refuse to
# operate on any other project rather than silently editing the wrong one.
#
# access "read" opens read-only, which cannot save over a live GUI session's
# in-memory state; the query scripts use it so status and reports stay
# available while the project is open in a GUI.
proc pl_build_open_project {{access write}} {
    global pl_build_project_file pl_build_close_project_when_done
    global pl_build_read_only

    set pl_build_close_project_when_done false
    set pl_build_read_only false
    set open_now [current_project -quiet]
    if {$open_now eq ""} {
        if {![file exists $pl_build_project_file]} {
            error "missing project $pl_build_project_file"
        }
        if {$access eq "read"} {
            open_project -read_only $pl_build_project_file
            set pl_build_read_only true
        } else {
            open_project $pl_build_project_file
        }
        set pl_build_close_project_when_done true
        return
    }

    set open_xpr [file normalize [file join \
        [get_property DIRECTORY $open_now] \
        [get_property NAME $open_now].xpr]]
    if {$open_xpr ne [file normalize $pl_build_project_file]} {
        error "A different project is open ($open_xpr); close it or run this\
 script in batch mode against $pl_build_project_file"
    }
}

proc pl_build_close_project {} {
    global pl_build_close_project_when_done

    if {$pl_build_close_project_when_done} {
        set pl_build_close_project_when_done false
        close_project
    }
}

# Job count for launch_runs, highest precedence first: the first -tclargs
# value, the VIVADO_JOBS environment variable, then 8 (matching the focused
# check scripts, which are tuned for a developer workstation).
proc pl_build_jobs {} {
    global argv

    set jobs ""
    if {[info exists argv] && [llength $argv] > 0} {
        set jobs [lindex $argv 0]
    }
    if {$jobs eq "" && [info exists ::env(VIVADO_JOBS)]} {
        set jobs $::env(VIVADO_JOBS)
    }
    if {$jobs eq ""} {
        set jobs 8
    }
    if {![string is integer -strict $jobs] || $jobs < 1} {
        error "invalid Vivado job count: $jobs"
    }
    return $jobs
}

proc pl_build_top {} {
    return [get_property TOP [current_fileset]]
}

proc pl_build_run_dir {run} {
    return [get_property DIRECTORY [get_runs $run]]
}

# Property sets differ between Vivado releases and between run states, and a
# run that never started has no statistics at all. Report what the project
# actually exposes instead of failing on an absent property.
proc pl_build_property {object name} {
    if {[lsearch -exact [list_property $object] $name] < 0} {
        return "n/a"
    }
    set value [get_property $name $object]
    if {[string trim $value] eq ""} {
        return "n/a"
    }
    return $value
}

proc pl_build_properties {object pattern} {
    set matched {}
    foreach property [list_property $object] {
        if {[string match $pattern $property]} {
            lappend matched $property
        }
    }
    return [lsort $matched]
}

# The two top-level runs first, then the out-of-context block-design and IP
# runs, so a status table reads top-down like the GUI's Design Runs window.
proc pl_build_runs {} {
    set all {}
    foreach run [get_runs -quiet] {
        lappend all "$run"
    }
    set all [lsort $all]
    set ordered {}
    foreach preferred {synth_1 impl_1} {
        if {[lsearch -exact $all $preferred] >= 0} {
            lappend ordered $preferred
        }
    }
    foreach run $all {
        if {[lsearch -exact $ordered $run] < 0} {
            lappend ordered $run
        }
    }
    return $ordered
}

# TopDesign.bd is the project's only block design (see AGENTS.md); treat
# anything else as a project problem rather than guessing which one to build.
proc pl_build_block_design {} {
    set designs {}
    foreach design [get_files -quiet *.bd] {
        lappend designs "$design"
    }
    if {[llength $designs] == 0} {
        error "the project has no block design"
    }
    if {[llength $designs] > 1} {
        error "expected exactly one block design, found: $designs"
    }
    return [lindex $designs 0]
}

# Output products land beside the .bd for a block design stored outside the
# project, and under <project>.gen for one stored inside it. Return whichever
# directory holds them, or "" when they have not been generated.
proc pl_build_block_design_products {bd} {
    set candidates [list [file dirname $bd]]
    lappend candidates [file join \
        [get_property DIRECTORY [current_project]] \
        "[get_property NAME [current_project]].gen" sources_1 bd \
        [file rootname [file tail $bd]]]
    foreach candidate $candidates {
        if {[file isdirectory [file join $candidate synth]]} {
            return $candidate
        }
    }
    return ""
}

# Batch Vivado prints its board-file and IP-repository scan before a sourced
# script produces a line, which buries a short report. Bracket the report so
# make_PL.sh can print only the report and leave the scan in the stage log.
proc pl_build_report_begin {} {
    puts "PL_REPORT_BEGIN"
}

proc pl_build_report_end {} {
    puts "PL_REPORT_END"
}

# Locked customizations are exactly the ones trailing their packaged or
# catalog definition, so they would synthesize stale logic.
#
# Only meaningful with the project open for writing: a read-only open makes
# Vivado report every IP as locked, because it cannot be regenerated.
proc pl_build_locked_ips {} {
    set locked {}
    foreach ip [get_ips -quiet] {
        if {[get_property IS_LOCKED $ip]} {
            lappend locked "$ip"
        }
    }
    return [lsort $locked]
}

# Precondition check for a stage that consumes an earlier run's output.
proc pl_build_require_run_complete {run hint} {
    set status [get_property STATUS [get_runs $run]]
    if {![string match "*Complete*" $status]} {
        error "$run is not complete (status: $status) -- run $hint first"
    }
    return $status
}

# Wait for a launched run and turn anything other than completion into an
# error, so the stage never reports success on a failed or aborted run.
proc pl_build_finish_run {run} {
    wait_on_run $run
    set status [get_property STATUS [get_runs $run]]
    puts "PL_BUILD_RUN=$run"
    puts "PL_BUILD_STATUS=$status"
    if {![string match "*Complete*" $status] || \
            [string match -nocase "*error*" $status]} {
        error "$run did not complete: $status (see\
 [file join [pl_build_run_dir $run] runme.log])"
    }
    return $status
}

# Reports are diagnostics, not the stage deliverable: a report that cannot be
# produced warns instead of failing the build. Sourced into a GUI session that
# already has a design open, open_run legitimately refuses; warn and skip.
proc pl_build_write_reports {run reports} {
    global pl_build_report_dir

    file mkdir $pl_build_report_dir
    if {[catch {open_run $run} message]} {
        puts "WARNING: $run could not be opened for reports: $message"
        return
    }
    foreach {name command} $reports {
        set path [file join $pl_build_report_dir "${name}.rpt"]
        if {[catch {{*}$command -file $path} message]} {
            puts "WARNING: $name report failed: $message"
            continue
        }
        puts "PL_BUILD_REPORT=$path"
    }
}
