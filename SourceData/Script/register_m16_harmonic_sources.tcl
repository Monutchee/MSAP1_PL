# Register the maintained M16 harmonic boundary sources with the product
# Vivado project. The packaged HarmonicEngine customization is registered by
# register_hls_components.tcl; this companion script owns the RTL shim,
# conditioner/frontend, and coefficient ROM that are ordinary project sources.
#
# Idempotent. Source it in the Vivado Tcl console if that GUI owns the project,
# or run it in batch mode while the GUI is closed.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../..]]
set project_file [file join $project_root vivado_gen MSAP1_PL.xpr]
set processing_dir [file join $project_root SourceData DesignFile \
    MeterProcessing]

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
    [file join $processing_dir meter_r5_harmonic_pkg.vhd] \
    [file join $processing_dir meter_r5_harmonic_export.vhd] \
    [file join $processing_dir meter_axis_packet_arbiter_2to1.vhd] \
    [file join $processing_dir meter_spectral_conditioner.vhd] \
    [file join $processing_dir meter_spectral_frontend.vhd] \
    [file join $processing_dir meter_harmonic_hls_shim.vhd]]
set memory_sources [list \
    [file join $processing_dir meter_spectral_conditioner_q20.mem]]
set required_sources [concat $vhdl_sources $memory_sources]

# Migrate projects registered before the conditioner and frontend moved from
# SystemVerilog to VHDL. Remove stale references even though the old files no
# longer exist on disk.
foreach legacy_name [list meter_spectral_conditioner.sv \
                          meter_spectral_frontend.sv] {
    set legacy_source [file join $processing_dir $legacy_name]
    set legacy_refs [get_files -quiet -of_objects [get_filesets sources_1] \
        $legacy_source]
    if {[llength $legacy_refs] != 0} {
        remove_files -fileset sources_1 $legacy_refs
        puts "Removed legacy M16 source: $legacy_source"
    }
}

set missing_sources [list]
foreach source $required_sources {
    if {![file exists $source]} {
        error "Missing maintained M16 source $source"
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
set_property USED_IN {synthesis simulation} [get_files $required_sources]
update_compile_order -fileset sources_1

puts "M16 harmonic project sources registered"
if {$close_project_when_done} {
    close_project
}
