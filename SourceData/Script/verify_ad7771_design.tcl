# Validate the integrated AD7771 data path and regenerate the managed wrapper.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../..]]
set project_file [file join $repo_dir vivado_gen MSAP1_PL.xpr]
set rtl_dir [file join $repo_dir SourceData DesignFile Ad7771Capture]

open_project $project_file
set_property ip_repo_paths [list $rtl_dir] [current_project]
update_ip_catalog

# Failed/retried BDC boundary updates can leave an auto-disabled generated
# fileset in the project.  It is not part of the active design.
foreach stale_name {AdcSubSystem_inst_0 AdcSubSystem_inst_1} {
    set stale_fileset [get_filesets -quiet $stale_name]
    if {[llength $stale_fileset] != 0} {
        delete_fileset $stale_fileset
    }
}

# Persist the fileset cleanup before opening/generating any BD. If Vivado
# encounters an output-product problem later, the stale reference must not be
# resurrected in the next synthesis launch.
close_project
open_project $project_file
set_property ip_repo_paths [list $rtl_dir] [current_project]
update_ip_catalog

open_bd_design [get_files TopDesign.bd]
validate_bd_design
save_bd_design

# Rebuild output metadata as well as HDL. Recreating a BDC boundary can leave
# obsolete ActiveVariant entries in TopDesign.bxml even after the BD itself is
# correct; those entries otherwise resurrect missing generated filesets during
# synthesis.
reset_target all [get_files TopDesign.bd]
generate_target all [get_files AdcSubSystem.bd]
generate_target all [get_files TopDesign.bd]
make_wrapper -files [get_files TopDesign.bd] -top
set wrapper [file join $repo_dir SourceData BlockDesign TopDesign hdl TopDesign_wrapper.v]
if {[llength [get_files -quiet $wrapper]] == 0} {
    add_files -norecurse $wrapper
}
set_property top TopDesign_wrapper [current_fileset]
update_compile_order -fileset sources_1
close_project
