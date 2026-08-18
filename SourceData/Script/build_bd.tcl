# PL build stage 0: block-design output products.
#
# Only TopDesign.bd and its managed top wrapper are tracked; every generated
# product beside them (ip/, ipshared/, synth/, sim/, hw_handoff/) is
# regenerable and gitignored, so a fresh checkout has none. This stage
# generates them explicitly rather than leaving synthesis to do it as a side
# effect, which is what lets a clean clone reach a bitstream through
# 'mnc PL build' alone. Rerun it after a block-design edit, and after an IP
# upgrade reset a block-design output product.
#
# Generation is incremental: an up-to-date block design costs one validation
# pass. This stage never calls make_wrapper, so it does not re-derive the top
# wrapper from the block-design boundary -- doing that after an interface
# change is a design decision made in IP Integrator -- and a wrapper older
# than the block design is reported instead.
#
# generate_target does still refresh what it owns, so on a checkout whose
# products were never generated expect two tracked files to come back
# modified: the wrapper's generated "--Date" header, and the block design's
# stored xci_name/xci_path entries, which Vivado normalizes to the cell names.
# Both are Vivado's own normalization, not design changes.
#
# Debug/standalone use (see build_common.tcl for the GUI rule):
#   vivado -mode batch -source SourceData/Script/build_bd.tcl
#   source SourceData/Script/build_bd.tcl   ;# Vivado Tcl console

source [file join [file dirname [file normalize [info script]]] build_common.tcl]

pl_build_open_project

set bd [pl_build_block_design]
puts "PL_BUILD_STAGE=bd"
puts "PL_BUILD_BD=$bd"

# Repair a packaged HLS IP that trails its definition rather than reporting it:
# an HLS rebuild always leaves one behind, and a locked IP breaks synthesis
# several minutes later with an error that names neither HLS nor the revision.
pl_build_refresh_hls_ips

# Anything still locked came from elsewhere in the catalog (a Xilinx IP needing
# a tool-version upgrade, say), which is not this stage's business to fix.
set locked [pl_build_locked_ips]
if {[llength $locked] > 0} {
    puts "WARNING: [llength $locked] IP customization(s) trail their definition\
 and would synthesize stale logic: $locked"
    puts "WARNING: upgrade them (report_ip_status) before synthesis"
}

# Validate before generating: an interface, clock, or reset error found here
# costs a validation pass instead of a synthesis run. Only close the design if
# this script opened it, so sourcing the stage in a GUI session leaves the
# user's open block design alone.
set bd_was_open [expr {[current_bd_design -quiet] ne ""}]
if {!$bd_was_open} {
    open_bd_design $bd
}

# A module-reference cell snapshots its HDL interface into the block design;
# an RTL port or interface edit (a widened AXI address bus, say) reaches
# neither the BD nor the out-of-context run's staleness check until the
# reference is updated. Without this, synthesis silently links the previous
# checkpoint and ships yesterday's logic (2026-08-18: a MeterCore interface
# change left the built bitstream on the prior ADC-simulator core). The
# refresh is idempotent and costs seconds when nothing changed.
set module_cells [get_bd_cells -quiet -filter {VLNV =~ "*:module_ref:*"}]
if {[llength $module_cells] > 0} {
    puts "PL_BUILD_MODULE_REFS=$module_cells"
    update_module_reference $module_cells
    save_bd_design
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
