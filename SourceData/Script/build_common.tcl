# Shared preamble for the staged PL build scripts.
#
# Sourced by build_synth.tcl, build_impl.tcl, build_bitstream.tcl, and
# export_xsa.tcl. It owns the project location, the open/close policy, the
# -jobs count, the incremental-implementation opt-in, run-status checking, and
# the report directory, so each stage script stays short enough to read and
# debug on its own.
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
# mnc PL build can chain stages.

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

# Incremental implementation, opt in with PL_INCREMENTAL=1.
#
# Place and route reuse an earlier routed checkpoint, which cuts impl runtime
# substantially once the design is mostly unchanged. The cost is that the result
# then depends on build history: two clones of the same commit can route
# differently, and reuse can hold a placement that no longer suits the changed
# logic, so timing has to be re-read rather than assumed. It stays off by
# default and a release bitstream is always a full run.
#
# Automatic mode is the only form safe to use here. An explicit
# INCREMENTAL_CHECKPOINT is a path, it is saved into the tracked
# vivado_gen/MSAP1_PL.xpr, and Vivado treats a named checkpoint it cannot read
# as an error rather than as a reason to run normally -- so committing one fails
# every fresh clone, where no .runs tree exists yet. In automatic mode Vivado
# owns the reference itself under AUTO_INCREMENTAL_CHECKPOINT.DIRECTORY
# (vivado_gen/MSAP1_PL.srcs/..., untracked), runs a full pass whenever it is
# absent, and writes it afterwards. That directory is outside the run
# directory, so it survives the reset_run each impl stage performs, and Vivado
# abandons incremental mode on its own when too little of the design is
# reusable.
#
# The property is written on every build, not only when enabling, so an opt-in
# run cannot leave a stray true behind in the tracked project file: the next
# default build sets it back to the committed value.
proc pl_build_apply_incremental {run} {
    set enabled 0
    if {[info exists ::env(PL_INCREMENTAL)]} {
        set value [string tolower [string trim $::env(PL_INCREMENTAL)]]
        if {[lsearch -exact [list 1 true yes on] $value] >= 0} {
            set enabled 1
        } elseif {[lsearch -exact [list 0 false no off {}] $value] < 0} {
            error "invalid PL_INCREMENTAL value: '$::env(PL_INCREMENTAL)'\
 (expected 1 or 0)"
        }
    }

    # Incremental implementation is a runtime optimisation, not part of the
    # stage's deliverable, so a release that spells it differently, has dropped
    # it, or refuses the value must cost the speedup and nothing else. Both the
    # absence of the property and a rejected write degrade to a full run; only
    # an explicit PL_INCREMENTAL=1 that could not be honoured says anything, so
    # a default build stays silent on a release that no longer offers it.
    if {[lsearch -exact [list_property [get_runs $run]] \
            AUTO_INCREMENTAL_CHECKPOINT] < 0} {
        if {$enabled} {
            puts "WARNING: $run has no AUTO_INCREMENTAL_CHECKPOINT property in\
 this Vivado release -- PL_INCREMENTAL ignored, running full implementation"
        }
        return 0
    }
    if {[catch {set_property AUTO_INCREMENTAL_CHECKPOINT $enabled \
            [get_runs $run]} message]} {
        if {$enabled} {
            puts "WARNING: $run rejected AUTO_INCREMENTAL_CHECKPOINT\
 ($message) -- PL_INCREMENTAL ignored, running full implementation"
        }
        return 0
    }

    puts "PL_BUILD_INCREMENTAL=$enabled"
    if {$enabled} {
        puts "PL_BUILD_INCREMENTAL_DIR=[pl_build_property [get_runs $run] \
            AUTO_INCREMENTAL_CHECKPOINT.DIRECTORY]"
    }
    return $enabled
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
# the query stages can print only the report and leave the scan in the stage log.
proc pl_build_report_begin {} {
    puts "PL_REPORT_BEGIN"
}

proc pl_build_report_end {} {
    puts "PL_REPORT_END"
}

# Make the project consume the newest packaged HLS output, then regenerate.
#
# Vitis HLS stamps a fresh coreRevision every time it packages a component, so
# after any HLS rebuild the tracked XCI trails its definition and Vivado locks
# it -- "IP definition ... has a different revision in the IP Catalog". A
# locked IP cannot be generated, its out-of-context run refuses to launch, and
# synthesis then fails deep inside the module reference that instantiates it
# with an error that names neither HLS nor the revision.
#
# This is the same repair refresh_hls_ip.tcl performs. The build stages run it
# themselves so a fresh clone reaches a bitstream even when that script has not
# been run -- make_HLS.sh skips it whenever any Vivado process is alive, which
# includes a GUI on an unrelated workspace. Idempotent and cheap when nothing
# is stale.
#
# Upgrading rewrites the tracked .xci's ip_revision, so an HLS rebuild always
# leaves that file modified. That is inherent to tracking a file the packager
# re-stamps; it is not a failure.
proc pl_build_refresh_hls_ips {} {
    update_ip_catalog -rebuild -quiet

    set upgraded {}
    foreach ip [get_ips -quiet] {
        if {![string match "monutchee:*" [get_property IPDEF $ip]]} {
            continue
        }
        if {![get_property IS_LOCKED $ip]} {
            continue
        }
        upgrade_ip [get_ips $ip]
        lappend upgraded "$ip"
    }
    if {[llength $upgraded] == 0} {
        return {}
    }

    # Upgrading resets the output products, so generate them now rather than
    # leaving synthesis to discover they are missing.
    foreach ip $upgraded {
        if {[catch {generate_target all [get_files -quiet \
                [get_property IP_FILE [get_ips $ip]]]} message]} {
            puts "WARNING: could not generate output products for $ip: $message"
        }
        puts "PL_BUILD_HLS_IP_UPGRADED=$ip"
    }
    return $upgraded
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

proc pl_build_elapsed {seconds} {
    return [format "%d:%02d:%02d" [expr {$seconds / 3600}] \
        [expr {($seconds % 3600) / 60}] [expr {$seconds % 60}]]
}

# A ten-cell bar over the run's own PROGRESS percentage. Vivado reports
# progress in 10% steps, so finer cells would only imply precision that the
# underlying value does not have.
proc pl_build_progress_bar {progress} {
    set percent 0
    regexp {(\d+)} $progress -> percent
    set filled [expr {$percent / 10}]
    return [format "\[%s%s\] %3d%%" [string repeat "#" $filled] \
        [string repeat "." [expr {10 - $filled}]] $percent]
}

# Runs Vivado currently reports as running, top-level ones first
# (pl_build_runs ordering).
proc pl_build_running_runs {} {
    set active {}
    foreach run [pl_build_runs] {
        set status [pl_build_property [get_runs $run] STATUS]
        if {[string match -nocase "*running*" $status]} {
            lappend active $run
        }
    }
    return $active
}

# Wait for a launched run, reporting progress, and turn anything other than
# completion into an error so the stage never reports success on a failed or
# aborted run.
#
# wait_on_run blocks silently, so a stage that takes tens of minutes used to
# print one line and then show no sign of life for the rest of it. Poll the
# run's STATUS and PROGRESS instead -- the same values the GUI's Design Runs
# window shows -- and print a line whenever they change, plus a heartbeat
# while they do not. A top-level run stays queued until the out-of-context
# block-design and IP runs it depends on finish, so name those while they are
# the ones doing the work; that early phase is otherwise the longest silence
# in the whole build.
#
# The loop is presentation only. wait_on_run still decides when the run is
# really finished (it returns immediately when it already is), so a stale or
# unexpected property value can delay a message but can never let a stage
# continue over an unfinished run.
proc pl_build_finish_run {run {poll_seconds 5} {heartbeat_seconds 60}} {
    set started [clock seconds]
    set last_line ""
    set last_print 0

    while {1} {
        set object [get_runs $run]
        set status [pl_build_property $object STATUS]
        set progress [pl_build_property $object PROGRESS]
        set elapsed [expr {[clock seconds] - $started}]

        set detail $status
        if {![string match -nocase "*running*" $status]} {
            set others {}
            foreach active [pl_build_running_runs] {
                if {$active ne $run} {
                    lappend others $active
                }
            }
            if {[llength $others] > 0} {
                set detail "$status -- waiting on [join $others {, }]"
            }
        }

        set line "[pl_build_progress_bar $progress] $detail"
        if {$line ne $last_line || \
                $elapsed - $last_print >= $heartbeat_seconds} {
            puts "PL_BUILD_PROGRESS=$run [pl_build_elapsed $elapsed] $line"
            flush stdout
            set last_line $line
            set last_print $elapsed
        }

        if {$progress eq "100%" || [string match "*Complete*" $status] || \
                [string match -nocase "*error*" $status]} {
            break
        }

        # A failed DEPENDENCY run leaves this run parked at "Queued"/
        # "Scripts Generated" forever: its own STATUS never says error, so
        # without this scan the loop idles at 0% while nothing is running
        # (seen 2026-08-18: a failed MeterCore OOC synthesis left synth_1
        # apparently alive for 12 minutes). Abort naming the actual
        # failure instead.
        foreach dependency_run [get_runs -quiet] {
            set dependency_status \
                [get_property -quiet STATUS $dependency_run]
            if {[string match -nocase "*error*" $dependency_status]} {
                error "$dependency_run failed while $run waited:\
 $dependency_status (see\
 [file join [pl_build_run_dir $dependency_run] runme.log])"
            }
        }
        after [expr {$poll_seconds * 1000}]
    }

    wait_on_run $run
    set status [get_property STATUS [get_runs $run]]
    puts "PL_BUILD_RUN=$run"
    puts "PL_BUILD_ELAPSED=[pl_build_elapsed [expr {[clock seconds] - $started}]]"
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
