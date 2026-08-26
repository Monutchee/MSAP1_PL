# Register every packaged HLS component with the product project.
#
# Generic over SourceData/HLS_DesignFile/ip_repo: each entry's VLNV is
# read from its component.xml, so a newly built HLS component needs no
# per-component Tcl. For every packaged component the script
#   * registers the ip_repo repository (once) and rebuilds the catalog,
#   * creates a missing IP customization as SourceData/IP/<name>_ip
#     (Vivado reserves the bare IP definition name, hence the suffix),
#   * registers an existing tracked XCI that the project lost, and
#   * upgrades customizations that trail their packaged revision.
# Legacy direct file references under HLS_DesignFile (the pre-IP-catalog
# integration) are dropped.
#
# Run this once after creating a NEW HLS component (after 'mnc HLS build' or
# HLS_DesignFile/run_hls.sh has produced its package). For rebuilds of
# already-registered components, refresh_hls_ip.tcl is sufficient -- and
# 'mnc HLS build' runs that automatically. What this script cannot do is add
# a new component's maintained VHDL boundary sources (its shim): add those to
# sources_1 yourself.
#
# Idempotent: safe to re-run any time; unchanged projects are untouched.
#
# Run either standalone (vivado -mode batch -source ...) or sourced from
# the Tcl console of a session that already has the product project open.
# The GUI case matters: Vivado does not lock projects, and a live GUI
# session saves its own in-memory state over any batch edit, so with the
# GUI open this script must run inside it.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../..]]
set project_file [file join $repo_dir vivado_gen MSAP1_PL.xpr]
set hls_ip_repo [file join $repo_dir SourceData HLS_DesignFile ip_repo]
set xci_parent [file join $repo_dir SourceData IP]

if {![file isdirectory $hls_ip_repo]} {
    error "missing $hls_ip_repo -- run 'mnc HLS build' (or HLS_DesignFile/run_hls.sh) first"
}

# Discover the packaged components from disk: every ip_repo entry with a
# component.xml, VLNV parsed from the IP-XACT identification block.
proc read_package_vlnv {package_xml} {
    set content [read [set f [open $package_xml r]]]
    close $f
    set fields {}
    foreach tag {vendor library name version} {
        if {![regexp "<(?:spirit|ipxact):$tag>(\[^<\]+)</(?:spirit|ipxact):$tag>" \
                $content -> value]} {
            error "cannot read IP-XACT $tag from $package_xml"
        }
        lappend fields [string trim $value]
    }
    return $fields
}

set packages {}
foreach package_xml [lsort [glob -nocomplain \
        [file join $hls_ip_repo * component.xml]]] {
    lappend packages [read_package_vlnv $package_xml]
}
if {[llength $packages] == 0} {
    error "no packaged components below $hls_ip_repo -- run 'mnc HLS build' first"
}

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

# Drop legacy direct file references under HLS_DesignFile: the IP-catalog
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
    foreach reference $removed {
        puts "Removed legacy reference: $reference"
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

set changed false
foreach package $packages {
    lassign $package vendor library name version
    set vlnv_base "${vendor}:${library}:${name}"
    set module_name "${name}_ip"
    set xci_file [file join $xci_parent $module_name "${module_name}.xci"]

    # Any existing customization of this definition counts as registered,
    # whatever its module name.
    set customized false
    foreach ip [get_ips -quiet] {
        if {[string match "${vlnv_base}:*" [get_property IPDEF $ip]]} {
            set customized true
        }
    }

    if {!$customized && [file exists $xci_file]} {
        add_files -fileset sources_1 -norecurse $xci_file
        puts "Registered existing customization: $xci_file"
        set changed true
        set customized true
    }
    if {!$customized} {
        set defs [get_ipdefs -quiet "${vlnv_base}:*"]
        if {[llength $defs] == 0} {
            error "the rebuilt IP catalog has no $vlnv_base definition;\
 check [file join $hls_ip_repo $name]"
        }
        set def [lindex [lsort -dictionary $defs] end]
        puts "Creating IP customization $module_name from $def"
        create_ip -vlnv $def -module_name $module_name -dir $xci_parent
        set changed true
    }

    # A customization may trail a newly packaged revision.
    foreach ip [get_ips -quiet] {
        if {[string match "${vlnv_base}:*" [get_property IPDEF $ip]] && \
                [get_property IS_LOCKED $ip]} {
            upgrade_ip [get_ips $ip]
            puts "Upgraded to newest packaged revision: $ip"
            set changed true
        }
    }
}

update_compile_order -fileset sources_1

if {!$changed && [llength $removed] == 0} {
    puts "All packaged HLS components already registered; project unchanged."
}
puts "Reminder: a new component's maintained VHDL boundary sources (its"
puts "shim) are design intent this script does not add; add them to"
puts "sources_1."
puts "HLS component registration complete."
if {$close_project_when_done} {
    close_project
}
