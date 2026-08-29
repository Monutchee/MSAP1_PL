# Register maintained power-quality private-packet infrastructure with the product
# Vivado project. HLS customizations remain owned by register_hls_components;
# this script adds only ordinary VHDL sources and is idempotent.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../..]]
set project_file [file join $project_root vivado_gen MSAP1_PL.xpr]
set processing_dir [file join $project_root SourceData DesignFile MeterProcessing]

set close_project_when_done false
set open_now [current_project -quiet]
if {$open_now eq ""} {
    open_project $project_file
    set close_project_when_done true
}

set vhdl_sources [list \
    [file join $processing_dir meter_r5_power_quality_protocol_pkg.vhd] \
    [file join $processing_dir meter_r5_fixed_packet_export.vhd] \
    [file join $processing_dir meter_axis_packet_arbiter_5to1.vhd] \
    [file join $processing_dir meter_flicker_hls_shim.vhd] \
    [file join $processing_dir meter_mains_signal_hls_shim.vhd]]

set missing_sources [list]
foreach source $vhdl_sources {
    if {![file exists $source]} {
        error "Missing maintained power-quality source $source"
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

puts "Power-quality private-packet project sources registered"
if {$close_project_when_done} {
    close_project
}
