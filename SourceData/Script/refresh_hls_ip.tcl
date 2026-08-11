# Make the product project consume the newest packaged HLS output.
#
# The HLS build flows (HLS_DesignFile/run_hls.sh, workspace make_HLS.sh)
# unpack each component's packaged IP into SourceData/HLS_DesignFile/ip_repo.
# This script points the project at that repository (once), rebuilds the IP
# catalog, and upgrades any project IP customization whose packaged
# definition changed, so the next synthesis/bitstream run regenerates the
# IP output products from the new revision instead of silently reusing
# stale ones.
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

if {![file isdirectory $hls_ip_repo]} {
    error "missing $hls_ip_repo -- run make_HLS.sh (or a component run_hls.sh) first"
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

# Register the repository once; preserve any other configured repositories.
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
puts "IP catalog rebuilt against $hls_ip_repo"

# Upgrade every project IP that came from this repository and now trails
# its packaged definition. Locked customizations are exactly the stale
# ones; upgrading resets their output products so the next run regenerates.
set refreshed {}
foreach ip [get_ips -quiet] {
    set def [get_property IPDEF $ip]
    if {![string match "monutchee:*" $def]} {
        continue
    }
    if {[get_property IS_LOCKED $ip]} {
        upgrade_ip [get_ips $ip]
        lappend refreshed "$ip ($def)"
    }
}
if {[llength $refreshed] > 0} {
    foreach entry $refreshed {
        puts "Upgraded to newest packaged revision: $entry"
    }
} else {
    puts "All HLS IP customizations already match the packaged revisions."
}
puts "HLS IP refresh complete."

if {$close_project_when_done} {
    close_project
}
