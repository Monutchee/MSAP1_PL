# Register the HLS cycle-aggregator trial with the product project using
# the IP-catalog flow.
#
# The project consumes the HLS engine as a packaged IP customization:
#   * SourceData/HLS_DesignFile/ip_repo            registered ip_repo_paths
#   * SourceData/IP/hls_cycle_aggregator_ip/*.xci  tracked IP customization
#   * meter_cycle_aggregator_hls_shim.vhd          maintained VHDL boundary
#   * meter_aggregator_compare.vhd                 maintained compare block
# The customization is named hls_cycle_aggregator_ip because Vivado
# reserves the bare IP definition name; the non-project check flows bind
# that module name through DesignFile/MeterProcessing/tb/
# hls_cycle_aggregator_ip.v over the packaged RTL.
# No generated HLS RTL is referenced directly; simulation-side check
# scripts compile the packaged hdl/verilog straight from ip_repo instead.
#
# Idempotent: safe to re-run any time. Legacy direct-RTL file references
# under HLS_DesignFile (the pre-IP-catalog integration) are dropped.
#
# Run either standalone (vivado -mode batch -source ...) or sourced from
# the Tcl console of a session that already has the product project open.
# The GUI case matters: Vivado does not lock projects, and a live GUI
# session saves its own in-memory state over any batch edit, so with the
# GUI open this script must run inside it.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../../..]]
set project_file [file join $repo_dir vivado_gen MSAP1_PL.xpr]
set design_root [file join $repo_dir SourceData DesignFile]
set hls_ip_repo [file join $repo_dir SourceData HLS_DesignFile ip_repo]
set package_dir [file join $hls_ip_repo CycleAggregator]
set xci_parent [file join $repo_dir SourceData IP]
set xci_file [file join $xci_parent hls_cycle_aggregator_ip \
    hls_cycle_aggregator_ip.xci]

if {![file isdirectory $package_dir]} {
    error "missing $package_dir -- run make_HLS.sh (or HLS_DesignFile/run_hls.sh) first"
}

set shim_file [file join $design_root MeterProcessing \
    meter_cycle_aggregator_hls_shim.vhd]
set compare_file [file join $design_root MeterProcessing \
    meter_aggregator_compare.vhd]

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

# Drop every direct file reference under HLS_DesignFile: the IP-catalog
# flow reaches that tree only through ip_repo_paths. Classify first,
# remove in one call (removing while iterating live file objects
# invalidates the remainder of the collection).
set removed {}
foreach project_file_ref [get_files -quiet -of_objects \
        [get_filesets sources_1] [file join $repo_dir SourceData \
        HLS_DesignFile *]] {
    lappend removed [file normalize "$project_file_ref"]
}
if {[llength $removed] > 0} {
    remove_files -fileset sources_1 $removed
}

# Maintained VHDL boundary sources.
set added {}
foreach vhdl_2008_file [list $shim_file $compare_file] {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] \
            $vhdl_2008_file]] == 0} {
        add_files -fileset sources_1 -norecurse $vhdl_2008_file
        set_property FILE_TYPE {VHDL 2008} \
            [get_files -of_objects [get_filesets sources_1] $vhdl_2008_file]
        lappend added $vhdl_2008_file
    }
}

# IP repository registration and catalog rebuild (kept in step with
# refresh_hls_ip.tcl).
set repo_paths [get_property ip_repo_paths [current_project]]
set normalized {}
foreach path $repo_paths {
    lappend normalized [file normalize $path]
}
if {[lsearch -exact $normalized [file normalize $hls_ip_repo]] < 0} {
    set_property ip_repo_paths \
        [concat $repo_paths [list $hls_ip_repo]] [current_project]
    puts "Registered IP repository: $hls_ip_repo"
}
update_ip_catalog -rebuild -quiet

# The IP customization: create it from the discovered packaged definition
# (never a hard-coded VLNV) or register an existing tracked XCI.
if {![file exists $xci_file]} {
    set defs [get_ipdefs -quiet *msap1*hls_cycle_aggregator*]
    if {[llength $defs] == 0} {
        error "the rebuilt IP catalog has no msap1 hls_cycle_aggregator\
 definition; check $package_dir"
    }
    set def [lindex [lsort -dictionary $defs] end]
    puts "Creating IP customization from $def"
    create_ip -vlnv $def -module_name hls_cycle_aggregator_ip -dir $xci_parent
    lappend added $xci_file
} elseif {[llength [get_files -quiet -of_objects [get_filesets sources_1] \
        $xci_file]] == 0} {
    add_files -fileset sources_1 -norecurse $xci_file
    lappend added $xci_file
}

# A pre-existing customization may trail a newly packaged revision.
foreach ip [get_ips -quiet hls_cycle_aggregator_ip] {
    if {[get_property IS_LOCKED $ip]} {
        upgrade_ip [get_ips $ip]
        puts "Upgraded IP customization: $ip"
    }
}

update_compile_order -fileset sources_1

if {[llength $added] == 0 && [llength $removed] == 0} {
    puts "HLS cycle-aggregator integration already current; project unchanged."
} else {
    foreach source_file $removed {
        puts "Removed legacy reference: $source_file"
    }
    foreach source_file $added {
        puts "Added: $source_file"
    }
}
puts "HLS cycle-aggregator integration complete."
if {$close_project_when_done} {
    close_project
}
