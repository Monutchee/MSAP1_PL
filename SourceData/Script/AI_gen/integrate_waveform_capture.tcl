# Add the independent waveform-capture DMA path to the maintained TopDesign.
#
# This script intentionally extends the existing control and DDR SmartConnect
# instances instead of creating a second platform infrastructure island.  The
# meter-result DMA and all existing address assignments remain unchanged.
#
# Address map added by this script:
#   0xB0060000  Waveform AXI DMA control registers
#   0xB0070000  MeterCore waveform/time-correlation registers

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../../..]]
set project_file [file join $repo_dir vivado_gen MSAP1_PL.xpr]

proc require_one {description objects} {
    if {[llength $objects] != 1} {
        error "Expected one $description, found [llength $objects]"
    }
    return [lindex $objects 0]
}

proc connect_intf_once {source destination} {
    set src [require_one "interface $source" [get_bd_intf_pins -quiet $source]]
    set dst [require_one "interface $destination" [get_bd_intf_pins -quiet $destination]]
    if {[llength [get_bd_intf_nets -quiet -of_objects $dst]] == 0} {
        connect_bd_intf_net $src $dst
    }
}

proc connect_pin_once {source destination} {
    set src [require_one "pin $source" [get_bd_pins -quiet $source]]
    set dst [require_one "pin $destination" [get_bd_pins -quiet $destination]]
    if {[llength [get_bd_nets -quiet -of_objects $dst]] == 0} {
        connect_bd_net $src $dst
    }
}

open_project $project_file
open_bd_design [get_files TopDesign.bd]
current_bd_design TopDesign

# Refresh the module reference so the new waveform AXI interfaces are visible
# before creating hierarchy boundary pins.
set meter_ip [require_one "MeterCore module-reference IP" \
    [get_ips -quiet TopDesign_MeterCore_Wrapper_0]]
update_module_reference $meter_ip

# MeterLogic hierarchy: expose the Linux-owned AXI-Lite register bank. The
# waveform stream remains local because MeterCore and the Meter_DMA hierarchy
# are siblings.
current_bd_instance /MeterLogic
if {[llength [get_bd_intf_pins -quiet S_AXI_WAVEFORM]] == 0} {
    create_bd_intf_pin -mode Slave \
        -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_WAVEFORM
}
connect_intf_once S_AXI_WAVEFORM MeterCore_Wrapper/S_AXI_WAVEFORM

# Meter_DMA hierarchy: add one independent SG-enabled S2MM engine. Both of its
# memory masters share the existing HP0 memory-path SmartConnect.
current_bd_instance /MeterLogic/Meter_DMA
if {[llength [get_bd_intf_pins -quiet S_AXIS_S2MM1]] == 0} {
    create_bd_intf_pin -mode Slave \
        -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_S2MM1
}
if {[llength [get_bd_intf_pins -quiet S_AXI_LITE1]] == 0} {
    create_bd_intf_pin -mode Slave \
        -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_LITE1
}
if {[llength [get_bd_cells -quiet Waveform_DMA]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 Waveform_DMA
}
set waveform_dma [get_bd_cells Waveform_DMA]
set_property -dict [list \
    CONFIG.c_include_mm2s {0} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_include_sg {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_addr_width {32} \
    CONFIG.c_sg_length_width {16} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_include_s2mm_dre {0}] $waveform_dma

set memory_smc [require_one "DMA memory SmartConnect" \
    [get_bd_cells -quiet adc_dma_mem_smc]]
set_property CONFIG.NUM_SI 4 $memory_smc

connect_intf_once S_AXIS_S2MM1 Waveform_DMA/S_AXIS_S2MM
connect_intf_once S_AXI_LITE1 Waveform_DMA/S_AXI_LITE
connect_intf_once Waveform_DMA/M_AXI_S2MM adc_dma_mem_smc/S03_AXI
connect_intf_once Waveform_DMA/M_AXI_SG adc_dma_mem_smc/S02_AXI
connect_pin_once m_axi_s2mm_aclk Waveform_DMA/s_axi_lite_aclk
connect_pin_once m_axi_s2mm_aclk Waveform_DMA/m_axi_s2mm_aclk
connect_pin_once m_axi_s2mm_aclk Waveform_DMA/m_axi_sg_aclk
connect_pin_once aresetn Waveform_DMA/axi_resetn

# Preserve the existing meter DMA interrupt as vector bit zero. The waveform
# DMA is the new bit one, so generated Linux IRQ numbering remains stable.
if {[llength [get_bd_cells -quiet ilconcat_0]] == 0} {
    set hierarchy_irq [get_bd_pins -quiet s2mm_introut]
    set old_irq_net [get_bd_nets -quiet -of_objects $hierarchy_irq]
    if {[llength $old_irq_net] != 0} {
        delete_bd_objs [lindex $old_irq_net 0]
    }
    create_bd_cell -type ip \
        -vlnv xilinx.com:inline_hdl:ilconcat:1.0 ilconcat_0
}
connect_pin_once Meter_data_DMA/s2mm_introut ilconcat_0/In0
connect_pin_once Waveform_DMA/s2mm_introut ilconcat_0/In1
connect_pin_once ilconcat_0/dout s2mm_introut

# Top-level stream/control connectivity.
current_bd_instance /MeterLogic
connect_intf_once MeterCore_Wrapper/M_AXIS_WAVEFORM Meter_DMA/S_AXIS_S2MM1

# Export two additional control masters from the Zynq-system hierarchy.
current_bd_instance /ZYNQ_System
set control_smc [require_one "PS control SmartConnect" \
    [get_bd_cells -quiet smartconnect_0]]
set_property CONFIG.NUM_MI 8 $control_smc
foreach index {06 07} {
    set pin_name M${index}_AXI
    if {[llength [get_bd_intf_pins -quiet $pin_name]] == 0} {
        create_bd_intf_pin -mode Master \
            -vlnv xilinx.com:interface:aximm_rtl:1.0 $pin_name
    }
    connect_intf_once smartconnect_0/$pin_name $pin_name
}

current_bd_instance /
connect_intf_once ZYNQ_System/M06_AXI MeterLogic/S_AXI_WAVEFORM
connect_intf_once ZYNQ_System/M07_AXI MeterLogic/S_AXI_LITE1

# Preserve the existing map and place only the two new AXI-Lite endpoints.
set ps_space [require_one "PS data address space" \
    [get_bd_addr_spaces -quiet ZYNQ_System/zynq_ultra_ps_e_0/Data]]
set dma_regs [require_one "waveform DMA register segment" \
    [get_bd_addr_segs -quiet MeterLogic/Meter_DMA/Waveform_DMA/S_AXI_LITE/Reg]]
set waveform_regs [require_one "waveform control register segment" \
    [get_bd_addr_segs -quiet MeterLogic/MeterCore_Wrapper/S_AXI_WAVEFORM/reg0]]
assign_bd_address -offset 0xB0060000 -range 64K \
    -target_address_space $ps_space $dma_regs -force
assign_bd_address -offset 0xB0070000 -range 64K \
    -target_address_space $ps_space $waveform_regs -force

# Both SG descriptors and sample blocks must target low DDR only.
set ddr_low [require_one "HP0 low-DDR segment" \
    [get_bd_addr_segs -quiet ZYNQ_System/zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW]]
set non_ddr_segments [list \
    [require_one "HP0 high-DDR segment" \
        [get_bd_addr_segs -quiet ZYNQ_System/zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_HIGH]] \
    [require_one "HP0 OCM segment" \
        [get_bd_addr_segs -quiet ZYNQ_System/zynq_ultra_ps_e_0/SAXIGP2/HP0_LPS_OCM]] \
    [require_one "HP0 QSPI segment" \
        [get_bd_addr_segs -quiet ZYNQ_System/zynq_ultra_ps_e_0/SAXIGP2/HP0_QSPI]]]
foreach space_name {Data_S2MM Data_SG} {
    set dma_space [require_one "waveform DMA $space_name address space" \
        [get_bd_addr_spaces -quiet MeterLogic/Meter_DMA/Waveform_DMA/$space_name]]
    assign_bd_address -offset 0x00000000 -range 2G \
        -target_address_space $dma_space $ddr_low -force
    foreach non_ddr $non_ddr_segments {
        exclude_bd_addr_seg -target_address_space $dma_space $non_ddr
    }
}

validate_bd_design
save_bd_design
close_project
