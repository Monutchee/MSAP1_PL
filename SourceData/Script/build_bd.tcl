# PL build stage 0: block-design output products.
#
# Only TopDesign.bd and its managed top wrapper are tracked; every generated
# product beside them (ip/, ipshared/, synth/, sim/, hw_handoff/) is
# regenerable and gitignored, so a fresh checkout has none. This stage
# generates them explicitly rather than leaving synthesis to do it as a side
# effect, which is what lets a clean clone reach a bitstream through
# make_PL.sh alone. Rerun it after a block-design edit, and after an IP
# upgrade reset a block-design output product.
#
# Generation is incremental: an up-to-date block design costs one validation
# pass. The tracked top wrapper is never rewritten -- refreshing it after an
# interface change is a design decision made in IP Integrator -- but a
# wrapper older than the block design is reported.
#
# Debug/standalone use (see build_common.tcl for the GUI rule):
#   vivado -mode batch -source SourceData/Script/build_bd.tcl
#   source SourceData/Script/build_bd.tcl   ;# Vivado Tcl console

source [file join [file dirname [file normalize [info script]]] build_common.tcl]

pl_build_open_project

set bd [pl_build_block_design]
puts "PL_BUILD_STAGE=bd"
puts "PL_BUILD_BD=$bd"

# Reported, not fatal: refresh_hls_ip.tcl and register_hls_components.tcl own
# the upgrade, and a locked IP elsewhere in the project must not block block
# design generation. --status reports the same set.
set locked [pl_build_locked_ips]
if {[llength $locked] > 0} {
    puts "WARNING: [llength $locked] IP customization(s) trail their definition\
 and would synthesize stale logic: $locked"
    puts "WARNING: run make_HLS.sh, or source refresh_hls_ip.tcl, before synthesis"
}

# Validate before generating: an interface, clock, or reset error found here
# costs a validation pass instead of a synthesis run. Only close the design if
# this script opened it, so sourcing the stage in a GUI session leaves the
# user's open block design alone.
set bd_was_open [expr {[current_bd_design -quiet] ne ""}]
if {!$bd_was_open} {
    open_bd_design $bd
}
validate_bd_design
puts "PL_BUILD_BD_VALIDATED=$bd"
if {!$bd_was_open} {
    close_bd_design [current_bd_design]
}

generate_target all [get_files $bd]

set products [pl_build_block_design_products $bd]
if {$products eq ""} {
    error "generate_target produced no synthesis output for $bd"
}
puts "PL_BUILD_BD_PRODUCTS=$products"

set top [pl_build_top]
set wrapper ""
foreach extension {vhd v sv} {
    set found [get_files -quiet "${top}.${extension}"]
    if {[llength $found] > 0} {
        set wrapper [lindex $found 0]
        break
    }
}
if {$wrapper eq ""} {
    error "the project has no source file for top $top"
}
puts "PL_BUILD_BD_WRAPPER=$wrapper"
if {[file exists $wrapper] && [file mtime $wrapper] < [file mtime $bd]} {
    puts "WARNING: $top is older than [file tail $bd]; if the block-design\
 boundary changed, refresh the managed top wrapper in IP Integrator"
}

puts "PL_BUILD_STAGE_COMPLETE=bd"
pl_build_close_project
