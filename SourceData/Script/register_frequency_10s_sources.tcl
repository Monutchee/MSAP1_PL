# Register the maintained Class-A ten-second frequency observation boundary.
# These sources are ordinary VHDL, not packaged IP, and must be present before
# MeterCore's module-reference interface is refreshed. The script is
# idempotent and may be sourced by either normal build stage.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../..]]
set project_file [file join $project_root vivado_gen MSAP1_PL.xpr]
set processing_dir [file join $project_root SourceData DesignFile \
    MeterProcessing]
set meter_core_dir [file join $project_root SourceData DesignFile MeterCore]

set close_project_when_done false
set open_now [current_project -quiet]
if {$open_now eq ""} {
    open_project $project_file
    set close_project_when_done true
} else {
    set open_xpr [file normalize [file join \
        [get_property DIRECTORY $open_now] \
        [get_property NAME $open_now].xpr]]
    if {$open_xpr ne [file normalize $project_file]} {
        error "A different project is open ($open_xpr); close it or run this\
 script in batch mode against $project_file"
    }
}

set vhdl_sources [list \
    [file join $processing_dir meter_frequency_10s_pkg.vhd] \
    [file join $processing_dir meter_frequency_10s_conditioner.vhd] \
    [file join $processing_dir meter_frequency_10s_observer.vhd] \
    [file join $meter_core_dir meter_time_control_axi_regs.vhd]]

set missing_sources [list]
foreach source $vhdl_sources {
    if {![file exists $source]} {
        error "Missing maintained frequency ten-second source $source"
    }
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] \
            $source]] == 0} {
        lappend missing_sources $source
    }
}
if {[llength $missing_sources] != 0} {
    add_files -fileset sources_1 -norecurse $missing_sources
}

set_property FILE_TYPE {VHDL 2008} [get_files $vhdl_sources]
set_property USED_IN {synthesis simulation} [get_files $vhdl_sources]
update_compile_order -fileset sources_1

puts "Class-A frequency ten-second project sources registered"
if {$close_project_when_done} {
    close_project
}
