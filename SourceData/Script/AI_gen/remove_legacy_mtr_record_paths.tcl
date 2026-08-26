# Remove the retired MeterCore MTR1/MTR2 record paths and compact the meter
# AXI4-Stream switch to the four authoritative producers. This is a maintained,
# idempotent TopDesign migration; source it in the Vivado GUI Tcl console when
# that GUI owns the project, or run it in batch only while the GUI is closed.
#
# Final switch order:
#   S00_AXIS <- SCYC_record_fifo/M_AXIS
#   S01_AXIS <- PQ_record_fifo/M_AXIS
#   S02_AXIS <- R5_Aggregation_FIFO/AXI_STR_TXD
#   S03_AXIS <- MeterData_Buffer/S_AXIS_HARMONIC

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set already_open [expr {[catch {current_project}] == 0}]
if {!$already_open} {
    open_project [file join $project_root vivado_gen MSAP1_PL.xpr]
}

set bd [get_files -quiet TopDesign.bd]
if {[llength $bd] != 1} {
    error "Expected one TopDesign.bd, found [llength $bd]"
}
open_bd_design $bd
current_bd_design TopDesign
current_bd_instance /

proc require_one {description objects} {
    if {[llength $objects] != 1} {
        error "Expected one $description, found [llength $objects]"
    }
    return [lindex $objects 0]
}

proc delete_interface_nets {pin_path} {
    set pin [get_bd_intf_pins -quiet $pin_path]
    if {[llength $pin] == 0} {
        return
    }
    set nets [get_bd_intf_nets -quiet -boundary_type both -of_objects $pin]
    if {[llength $nets] != 0} {
        delete_bd_objs $nets
    }
}

proc connect_interface_once {source_path sink_path} {
    set source [require_one "interface pin $source_path" \
        [get_bd_intf_pins -quiet $source_path]]
    set sink [require_one "interface pin $sink_path" \
        [get_bd_intf_pins -quiet $sink_path]]
    set source_nets [get_bd_intf_nets -quiet -boundary_type both \
        -of_objects $source]
    set sink_nets [get_bd_intf_nets -quiet -boundary_type both \
        -of_objects $sink]
    foreach source_net $source_nets {
        if {[lsearch -exact $sink_nets $source_net] >= 0} {
            return
        }
    }
    if {[llength $sink_nets] != 0} {
        error "Interface $sink_path is already connected to an unexpected net"
    }
    # A hierarchy boundary pin can legitimately retain its outer net while
    # this call creates the independent inner net, so never delete source_nets.
    connect_bd_intf_net $source $sink
}

set buffer /MeterLogic/MeterData_Buffer
set computation /MeterLogic/Data_Computation
set switch [require_one "meter record AXIS switch" \
    [get_bd_cells -quiet $buffer/MeterData_AXI_Switch]]

# Disconnect both obsolete paths before refreshing the module reference. This
# lets Vivado remove the deleted HDL interfaces without leaving dangling nets.
foreach legacy_port {M_AXIS_MTR1 M_AXIS_MTR2} {
    delete_interface_nets \
        /MeterLogic/Data_Computation/MeterCore_Wrapper/$legacy_port
    delete_interface_nets $computation/$legacy_port
}
foreach legacy_pin {S_AXIS S_AXIS1} {
    delete_interface_nets $buffer/$legacy_pin
}

# Normalize all switch inputs before reducing NUM_SI so no connection is lost
# implicitly when Vivado removes S04/S05.
current_bd_instance $buffer
foreach legacy_pin {S_AXIS S_AXIS1} {
    delete_interface_nets $legacy_pin
}
foreach index {00 01 02 03 04 05} {
    delete_interface_nets MeterData_AXI_Switch/S${index}_AXIS
}

foreach legacy_cell {MTR1_FIFO MTR2_FIFO} {
    set cell [get_bd_cells -quiet $legacy_cell]
    if {[llength $cell] != 0} {
        delete_bd_objs $cell
    }
}
foreach legacy_pin {S_AXIS S_AXIS1} {
    set pin [get_bd_intf_pins -quiet $legacy_pin]
    if {[llength $pin] != 0} {
        delete_bd_objs $pin
    }
}
current_bd_instance /

# The parent Data_Computation hierarchy used to forward both retired module
# outputs. Remove those now-orphaned boundary pins as well as the module pins.
foreach legacy_port {M_AXIS_MTR1 M_AXIS_MTR2} {
    set pin [get_bd_intf_pins -quiet $computation/$legacy_port]
    if {[llength $pin] != 0} {
        delete_bd_objs $pin
    }
}

set meter_ip [require_one "MeterCore module-reference IP" \
    [get_ips -quiet TopDesign_MeterCore_Wrapper_0]]
update_module_reference $meter_ip

foreach legacy_port {M_AXIS_MTR1 M_AXIS_MTR2} {
    foreach parent [list $computation \
            /MeterLogic/Data_Computation/MeterCore_Wrapper] {
        if {[llength [get_bd_intf_pins -quiet $parent/$legacy_port]] != 0} {
            error "$parent still exposes retired $legacy_port"
        }
    }
}

set_property -dict [list \
    CONFIG.NUM_SI {4} \
    CONFIG.NUM_MI {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.ARB_ON_TLAST {1} \
    CONFIG.ARB_ON_MAX_XFERS {0} \
    CONFIG.ARB_ON_NUM_CYCLES {0} \
    CONFIG.ARB_ALGORITHM {3}] $switch

current_bd_instance $buffer
connect_interface_once SCYC_record_fifo/M_AXIS MeterData_AXI_Switch/S00_AXIS
connect_interface_once PQ_record_fifo/M_AXIS MeterData_AXI_Switch/S01_AXIS
connect_interface_once R5_Aggregation_FIFO/AXI_STR_TXD \
    MeterData_AXI_Switch/S02_AXIS
connect_interface_once S_AXIS_HARMONIC MeterData_AXI_Switch/S03_AXIS
current_bd_instance /

validate_bd_design
save_bd_design

if {!$already_open} {
    close_project
}
puts "Legacy MTR1/MTR2 paths removed; MeterData_AXI_Switch compacted to four inputs"
