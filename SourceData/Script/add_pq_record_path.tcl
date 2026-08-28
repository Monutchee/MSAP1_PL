# Historical one-time M12 migration, retained for provenance. Current
# TopDesign already contains this path and the compact switch topology is owned
# by AI_gen/remove_legacy_mtr_record_paths.tcl; do not use this script to grow
# the current switch. At M12 it added MeterCore M_AXIS_PQ -> packet-mode FIFO ->
# a new slave port alongside the then-existing MTR1, MTR2, and SCYC paths.
#
# Idempotent: rerunning after the path exists changes nothing. Follows
# the register_hls_components.tcl GUI rule: source it in the GUI's Tcl
# console when the project is open there, never batch.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set already_open [expr {[catch {current_project}] == 0}]
if {!$already_open} {
    open_project [file join $project_root .. vivado_gen MSAP1_PL.xpr]
}

set bd [get_files TopDesign.bd]
open_bd_design $bd

# The module reference must expose M_AXIS_PQ first (build_bd.tcl also
# refreshes on every build; this keeps the script self-sufficient).
foreach candidate_ip [get_ips -quiet] {
    if {[string match "*:module_ref:MeterCore_Wrapper*" \
             [get_property -quiet IPDEF $candidate_ip]]} {
        update_module_reference $candidate_ip
    }
}

set meter_core [get_bd_cells -hierarchical -quiet -filter {NAME == "MeterCore_Wrapper"}]
if {$meter_core eq ""} { error "MeterCore_Wrapper cell not found" }
set pq_port [get_bd_intf_pins -quiet $meter_core/M_AXIS_PQ]
if {$pq_port eq ""} { error "M_AXIS_PQ did not appear on the module reference" }

if {[get_bd_cells -quiet ${meter_core}/../PQ_record_fifo] ne "" ||
    [get_bd_cells -hierarchical -quiet -filter {NAME == "PQ_record_fifo"}] ne ""} {
    puts "PQ record path already present; nothing to do"
} else {
    # Historical migration path: clone a template FIFO inside MTR_Buffer and
    # add a new hierarchy pin. The current design must take the early exit.
    set buffer_group [get_bd_cells -quiet /MeterLogic/MTR_Buffer]
    if {$buffer_group eq ""} { error "MTR_Buffer hierarchy not found" }
    set template_fifo ""
    set switch_cell ""
    foreach cell [get_bd_cells -quiet $buffer_group/*] {
        set vlnv [get_property -quiet VLNV $cell]
        if {[string match "*axis_data_fifo*" $vlnv] && $template_fifo eq ""} {
            set template_fifo $cell
        }
        if {[string match "*axis_switch*" $vlnv]} { set switch_cell $cell }
    }
    if {$template_fifo eq ""} { error "record FIFO template not found in MTR_Buffer" }
    if {$switch_cell eq ""} { error "record AXIS switch not found in MTR_Buffer" }

    set fifo [create_bd_cell -type ip \
        -vlnv [get_property VLNV $template_fifo] $buffer_group/PQ_record_fifo]
    foreach prop [list_property $template_fifo CONFIG.*] {
        if {[string match "CONFIG.*" $prop] &&
            ![string match "*.VALUE_SRC" $prop]} {
            catch {set_property $prop [get_property $prop $template_fifo] $fifo}
        }
    }

    set num_si [get_property CONFIG.NUM_SI $switch_cell]
    set new_si [format "S%02d_AXIS" $num_si]
    set_property CONFIG.NUM_SI [expr {$num_si + 1}] $switch_cell

    # New group pin, then outer and inner data connections.
    set group_pin [create_bd_intf_pin -mode Slave \
        -vlnv xilinx.com:interface:axis_rtl:1.0 $buffer_group/S_AXIS_PQ]
    connect_bd_intf_net $pq_port $group_pin
    connect_bd_intf_net [get_bd_intf_pins $buffer_group/S_AXIS_PQ] \
        [get_bd_intf_pins $fifo/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins $fifo/M_AXIS] \
        [get_bd_intf_pins $switch_cell/$new_si]

    # Clock/reset: mirror the template FIFO pin for pin.
    foreach pin_name {s_axis_aclk s_axis_aresetn m_axis_aclk m_axis_aresetn} {
        set template_pin [get_bd_pins -quiet $template_fifo/$pin_name]
        set new_pin [get_bd_pins -quiet $fifo/$pin_name]
        if {$template_pin ne "" && $new_pin ne ""} {
            set net [get_bd_nets -quiet -of_objects $template_pin]
            if {$net ne ""} { connect_bd_net -net $net $new_pin }
        }
    }

    validate_bd_design
    save_bd_design
    puts "PQ record path added: $fifo -> $switch_cell/$new_si"
}

if {!$already_open} { close_project }
puts "add_pq_record_path done"
