# PL build stage 4: export the bitstream-inclusive hardware platform (XSA).
#
# Default output is ../runtime-generated/bin_file/<project>.xsa, the path the
# workspace build chain (mnc PL build, mnc RPU build) consumes. An optional
# -tclargs <output-file> overrides it; mnc PL build --gen-xsa passes the exact
# path it will then hand to sdtgen.
#
# Requires a bitstream, so run build_bitstream.tcl (or mnc PL build
# --compile-bit) first.
#
# Debug/standalone use (see build_common.tcl for the GUI rule):
#   vivado -mode batch -source SourceData/Script/export_xsa.tcl
#   source SourceData/Script/export_xsa.tcl   ;# Vivado Tcl console

source [file join [file dirname [file normalize [info script]]] build_common.tcl]

pl_build_open_project

set project [current_project]
set project_name [get_property NAME $project]

set output_file ""
if {[info exists argv] && [llength $argv] > 0} {
    set output_file [file normalize [lindex $argv 0]]
}
if {$output_file eq ""} {
    set output_file [file normalize [file join \
        $pl_build_repo_dir .. .. runtime-generated bin_file \
        "${project_name}.xsa"]]
}

file mkdir [file dirname $output_file]

puts "PL_BUILD_STAGE=xsa"
puts "Exporting hardware platform:"
puts "  Project: $project_name"
puts "  Output:  $output_file"

write_hw_platform \
    -fixed \
    -include_bit \
    -force \
    -file $output_file

if {![file exists $output_file]} {
    error "write_hw_platform reported success but $output_file is missing"
}
puts "PL_BUILD_XSA=$output_file"
puts "XSA export completed."

puts "PL_BUILD_STAGE_COMPLETE=xsa"
pl_build_close_project
