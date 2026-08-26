# Read-only structural contract check for the compact meter-record transport.
# Run in Vivado batch mode while the GUI is closed, or source it in the GUI Tcl
# console after saving TopDesign. It deliberately does not update or save the
# block design.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set already_open [expr {[catch {current_project}] == 0}]
if {!$already_open} {
    open_project [file join $project_root vivado_gen MSAP1_PL.xpr] -quiet
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

proc require_property {description object property expected} {
    set actual [get_property $property $object]
    if {$actual ne $expected} {
        error "$description $property is '$actual', expected '$expected'"
    }
}

proc require_interface_connection {first_path second_path} {
    set first [require_one "interface pin $first_path" \
        [get_bd_intf_pins -quiet $first_path]]
    set second [require_one "interface pin $second_path" \
        [get_bd_intf_pins -quiet $second_path]]
    set first_nets [get_bd_intf_nets -quiet -boundary_type both \
        -of_objects $first]
    set second_nets [get_bd_intf_nets -quiet -boundary_type both \
        -of_objects $second]
    foreach net $first_nets {
        if {[lsearch -exact $second_nets $net] >= 0} {
            return
        }
    }
    error "Interfaces $first_path and $second_path are not connected"
}

proc require_scalar_connection {first_path second_path} {
    set first [require_one "pin $first_path" [get_bd_pins -quiet $first_path]]
    set second [require_one "pin $second_path" [get_bd_pins -quiet $second_path]]
    set first_nets [get_bd_nets -quiet -boundary_type both \
        -of_objects $first]
    set second_nets [get_bd_nets -quiet -boundary_type both \
        -of_objects $second]
    foreach net $first_nets {
        if {[lsearch -exact $second_nets $net] >= 0} {
            return
        }
    }
    error "Pins $first_path and $second_path are not connected"
}

proc require_address_offset {address_space segment_name expected} {
    set matches [list]
    foreach segment [get_bd_addr_segs -quiet -of_objects $address_space] {
        if {[get_property NAME $segment] eq $segment_name} {
            lappend matches $segment
        }
    }
    set segment [require_one "mapped address segment $segment_name" $matches]
    set actual [get_property OFFSET $segment]
    if {[expr {wide($actual)}] != [expr {wide($expected)}]} {
        error "$segment_name is mapped at $actual, expected $expected"
    }
}

set buffer /MeterLogic/MeterData_Buffer
set computation /MeterLogic/Data_Computation
set meter /MeterLogic/Data_Computation/MeterCore_Wrapper
set switch [require_one "MeterData_AXI_Switch" \
    [get_bd_cells -quiet $buffer/MeterData_AXI_Switch]]

foreach legacy_cell {MTR1_FIFO MTR2_FIFO} {
    if {[llength [get_bd_cells -quiet $buffer/$legacy_cell]] != 0} {
        error "Retired cell $buffer/$legacy_cell is still present"
    }
}
foreach legacy_pin {S_AXIS S_AXIS1} {
    if {[llength [get_bd_intf_pins -quiet $buffer/$legacy_pin]] != 0} {
        error "Retired hierarchy pin $buffer/$legacy_pin is still present"
    }
}
foreach legacy_port {M_AXIS_MTR1 M_AXIS_MTR2} {
    foreach parent [list $computation $meter] {
        if {[llength [get_bd_intf_pins -quiet $parent/$legacy_port]] != 0} {
            error "Retired interface $parent/$legacy_port is still present"
        }
    }
}

require_property "MeterData_AXI_Switch" $switch CONFIG.NUM_SI 4
require_property "MeterData_AXI_Switch" $switch CONFIG.NUM_MI 1
require_property "MeterData_AXI_Switch" $switch CONFIG.HAS_TLAST 1
require_property "MeterData_AXI_Switch" $switch CONFIG.ARB_ON_TLAST 1
require_property "MeterData_AXI_Switch" $switch CONFIG.ARB_ON_MAX_XFERS 0
require_property "MeterData_AXI_Switch" $switch CONFIG.ARB_ON_NUM_CYCLES 0
require_property "MeterData_AXI_Switch" $switch CONFIG.ARB_ALGORITHM 3
foreach retired_input {S04_AXIS S05_AXIS} {
    if {[llength [get_bd_intf_pins -quiet $switch/$retired_input]] != 0} {
        error "MeterData_AXI_Switch still exposes $retired_input with NUM_SI=4"
    }
}

set scyc_fifo [require_one "SCYC packet FIFO" \
    [get_bd_cells -quiet $buffer/SCYC_record_fifo]]
set pq_fifo [require_one "PQ packet FIFO" \
    [get_bd_cells -quiet $buffer/PQ_record_fifo]]
foreach fifo [list $scyc_fifo $pq_fifo] {
    require_property "Packet FIFO [get_property NAME $fifo]" \
        $fifo CONFIG.FIFO_MODE 2
    require_property "Packet FIFO [get_property NAME $fifo]" \
        $fifo CONFIG.FIFO_DEPTH 256
    require_property "Packet FIFO [get_property NAME $fifo]" \
        $fifo CONFIG.TDATA_NUM_BYTES 4
    require_property "Packet FIFO [get_property NAME $fifo]" \
        $fifo CONFIG.HAS_TKEEP 1
    require_property "Packet FIFO [get_property NAME $fifo]" \
        $fifo CONFIG.HAS_TLAST 1
}

set r5_fifo [require_one "R5 aggregation FIFO" \
    [get_bd_cells -quiet $buffer/R5_Aggregation_FIFO]]
require_property "R5 aggregation FIFO" $r5_fifo CONFIG.C_USE_TX_CTRL 0
require_property "R5 aggregation FIFO" $r5_fifo \
    CONFIG.C_USE_TX_CUT_THROUGH 0
require_property "R5 aggregation FIFO" $r5_fifo CONFIG.C_HAS_AXIS_TKEEP true

# MeterCore sits one hierarchy below MeterData_Buffer. Check both sides of the
# Data_Computation boundary explicitly; pins separated by two hierarchy
# boundaries never share one Vivado interface-net object.
foreach connection [list \
    [list M_AXIS_SCYC S_AXIS_SCYC] \
    [list M_AXIS_PQ S_AXIS_PQ] \
    [list M_AXIS_R5_AGG_INPUT AXI_STR_RXD] \
    [list M_AXIS_HARMONIC S_AXIS_HARMONIC]] {
    lassign $connection producer buffer_pin
    require_interface_connection $meter/$producer $computation/$producer
    require_interface_connection $computation/$producer $buffer/$buffer_pin
}

# A hierarchy pin has distinct inner and outer nets. Enter MeterData_Buffer before
# checking its inner connections so Vivado returns the intended side.
current_bd_instance $buffer
require_interface_connection S_AXIS_SCYC SCYC_record_fifo/S_AXIS
require_interface_connection S_AXIS_PQ PQ_record_fifo/S_AXIS
require_interface_connection AXI_STR_RXD R5_Aggregation_FIFO/AXI_STR_RXD
require_interface_connection SCYC_record_fifo/M_AXIS MeterData_AXI_Switch/S00_AXIS
require_interface_connection PQ_record_fifo/M_AXIS MeterData_AXI_Switch/S01_AXIS
require_interface_connection R5_Aggregation_FIFO/AXI_STR_TXD \
    MeterData_AXI_Switch/S02_AXIS
require_interface_connection S_AXIS_HARMONIC MeterData_AXI_Switch/S03_AXIS
require_interface_connection MeterData_AXI_Switch/M00_AXIS M00_AXIS

# Preserve all record-transport clock/reset and interrupt ownership inside the
# hierarchy before returning to the outer connections.
foreach cell_pin [list \
    MeterData_AXI_Switch/aclk \
    SCYC_record_fifo/s_axis_aclk \
    PQ_record_fifo/s_axis_aclk \
    R5_Aggregation_FIFO/s_axi_aclk] {
    require_scalar_connection aclk $cell_pin
}
foreach cell_pin [list \
    MeterData_AXI_Switch/aresetn \
    SCYC_record_fifo/s_axis_aresetn \
    PQ_record_fifo/s_axis_aresetn \
    R5_Aggregation_FIFO/s_axi_aresetn] {
    require_scalar_connection aresetn $cell_pin
}
require_scalar_connection R5_Aggregation_FIFO/interrupt interrupt

current_bd_instance /
require_interface_connection $buffer/M00_AXIS \
    /MeterLogic/Meter_DMA/S_AXIS_S2MM
require_scalar_connection $buffer/interrupt /MeterLogic/Interrupt_Concat/In2

set ps_space [require_one "PS data address space" \
    [get_bd_addr_spaces -quiet ZYNQ_System/zynq_ultra_ps_e_0/Data]]
require_address_offset $ps_space SEG_Meter_data_DMA_Reg 0xB0030000
require_address_offset $ps_space SEG_Waveform_DMA_Reg 0xB0060000
require_address_offset $ps_space SEG_R5_Aggregation_FIFO_Mem0 0xB0090000

puts "Compact four-input meter-record transport PASS"
if {!$already_open} {
    close_project
}
