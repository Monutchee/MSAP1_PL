# Add the custom AD7771 receiver to AdcSubSystem.bd and connect its AXI Stream
# output to the existing S2MM-only AXI DMA in TopDesign.bd.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file normalize [file join $script_dir ../..]]
set project_file [file join $repo_dir vivado_gen MSAP1_PL.xpr]
set rtl_dir [file join $repo_dir SourceData DesignFile Ad7771Capture]

open_project $project_file

# Failed/retried BDC boundary updates can leave obsolete generated filesets.
# Remove and persist them before touching either source BD.
foreach stale_name {AdcSubSystem_inst_0 AdcSubSystem_inst_1} {
    set stale_fileset [get_filesets -quiet $stale_name]
    if {[llength $stale_fileset] != 0} {
        delete_fileset $stale_fileset
    }
}
close_project
open_project $project_file

set rtl_sources [list \
    [file join $rtl_dir ad7771_receiver.sv] \
    [file join $rtl_dir ad7771_axi_regs.sv] \
    [file join $rtl_dir ad7771_capture.sv] \
    [file join $rtl_dir Ad7771Capture_Wrapper.v]]

# The RTL is consumed through its packaged IP.  Remove any direct project
# references left by an interrupted/older integration attempt.
foreach rtl_source $rtl_sources {
    if {[llength [get_files -quiet $rtl_source]] != 0} {
        remove_files [get_files $rtl_source]
    }
}
set_property ip_repo_paths [list $rtl_dir] [current_project]
update_ip_catalog

# ---------------------------------------------------------------------------
# Child block design: control SPI + capture/data plane.
# ---------------------------------------------------------------------------
open_bd_design [get_files AdcSubSystem.bd]
current_bd_design AdcSubSystem

if {[llength [get_bd_cells -quiet ad7771_capture_0]] == 0} {
    create_bd_cell -type ip \
        -vlnv monutchee.com:user:ad7771_capture:1.0 ad7771_capture_0
} else {
    upgrade_bd_cells [get_bd_cells ad7771_capture_0]
}

set_property -dict [list CONFIG.NUM_MI {2}] [get_bd_cells smartconnect_0]

if {[llength [get_bd_intf_nets -quiet smartconnect_0_M01_AXI]] == 0} {
    connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M01_AXI] \
        [get_bd_intf_pins ad7771_capture_0/S_AXI]
}
if {[llength [get_bd_intf_ports -quiet M_AXIS_SAMPLES]] == 0} {
    make_bd_intf_pins_external [get_bd_intf_pins ad7771_capture_0/M_AXIS]
    set_property name M_AXIS_SAMPLES [get_bd_intf_ports M_AXIS_0]
}

if {[llength [get_bd_ports -quiet ADC_DCLK]] == 0} {
    create_bd_port -dir I -type clk -freq_hz 8192000 ADC_DCLK
    connect_bd_net [get_bd_ports ADC_DCLK] [get_bd_pins ad7771_capture_0/adc_dclk]
}
if {[llength [get_bd_ports -quiet ADC_DRDY_N]] == 0} {
    create_bd_port -dir I ADC_DRDY_N
    connect_bd_net [get_bd_ports ADC_DRDY_N] [get_bd_pins ad7771_capture_0/adc_drdy_n]
}
if {[llength [get_bd_ports -quiet ADC_DOUT]] == 0} {
    create_bd_port -dir I -from 3 -to 0 ADC_DOUT
    connect_bd_net [get_bd_ports ADC_DOUT] [get_bd_pins ad7771_capture_0/adc_dout]
}
if {[llength [get_bd_ports -quiet ADC_RESET_N]] == 0} {
    create_bd_port -dir O ADC_RESET_N
    connect_bd_net [get_bd_ports ADC_RESET_N] [get_bd_pins ad7771_capture_0/adc_reset_n]
}
if {[llength [get_bd_ports -quiet ADC_START_N]] == 0} {
    create_bd_port -dir O ADC_START_N
    connect_bd_net [get_bd_ports ADC_START_N] [get_bd_pins ad7771_capture_0/adc_start_n]
}
if {[llength [get_bd_ports -quiet ADC_CONVST_SAR]] == 0} {
    create_bd_port -dir O ADC_CONVST_SAR
    connect_bd_net [get_bd_ports ADC_CONVST_SAR] [get_bd_pins ad7771_capture_0/adc_convst_sar]
}

if {[llength [get_bd_nets -quiet -of_objects \
        [get_bd_pins ad7771_capture_0/s_axi_aclk]]] == 0} {
    connect_bd_net [get_bd_ports s_axi_aclk] \
        [get_bd_pins ad7771_capture_0/s_axi_aclk]
}
if {[llength [get_bd_nets -quiet -of_objects \
        [get_bd_pins ad7771_capture_0/s_axi_aresetn]]] == 0} {
    connect_bd_net [get_bd_ports s_axi_aresetn_0] \
        [get_bd_pins ad7771_capture_0/s_axi_aresetn]
}
set_property CONFIG.ASSOCIATED_BUSIF {S00_AXI_0:M_AXIS_SAMPLES} \
    [get_bd_ports s_axi_aclk]

if {[llength [get_bd_addr_segs -quiet S00_AXI_0/SEG_ad7771_capture_0_Reg]] == 0} {
    assign_bd_address -offset 0x44A10000 -range 64K \
        -target_address_space [get_bd_addr_spaces S00_AXI_0] \
        [get_bd_addr_segs ad7771_capture_0/S_AXI/Reg] -force
}

validate_bd_design
save_bd_design
close_project

# Reopening causes the BDC instance boundary to be refreshed from its source.
open_project $project_file
open_bd_design [get_files TopDesign.bd]
current_bd_design TopDesign

# A non-DFX BDC instance caches the child boundary.  Vivado 2025.2 does not
# offer an in-place boundary refresh for this BDC type, so recreate only this
# container instance when its new stream port is not present.  The BD source,
# surrounding platform IP, and external ports are left untouched.
if {[llength [get_bd_intf_pins -quiet AdcSubSystem_0/M_AXIS_SAMPLES]] == 0} {
    delete_bd_objs [get_bd_cells AdcSubSystem_0]
    create_bd_cell -type container -reference AdcSubSystem AdcSubSystem_0

    connect_bd_intf_net [get_bd_intf_ports EXT_ADC_SPI] \
        [get_bd_intf_pins AdcSubSystem_0/ADC_SPI]
    connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M01_AXI] \
        [get_bd_intf_pins AdcSubSystem_0/S00_AXI_0]
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
        [get_bd_pins AdcSubSystem_0/ext_spi_clk_0] \
        [get_bd_pins AdcSubSystem_0/s_axi_aclk]
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
        [get_bd_pins AdcSubSystem_0/s_axi_aresetn_0]
}

connect_bd_intf_net [get_bd_intf_pins AdcSubSystem_0/M_AXIS_SAMPLES] \
    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

if {[llength [get_bd_ports -quiet ADC_DCLK]] == 0} {
    create_bd_port -dir I -type clk -freq_hz 8192000 ADC_DCLK
    connect_bd_net [get_bd_ports ADC_DCLK] [get_bd_pins AdcSubSystem_0/ADC_DCLK]
}
if {[llength [get_bd_ports -quiet ADC_DRDY_N]] == 0} {
    create_bd_port -dir I ADC_DRDY_N
    connect_bd_net [get_bd_ports ADC_DRDY_N] [get_bd_pins AdcSubSystem_0/ADC_DRDY_N]
}
if {[llength [get_bd_ports -quiet ADC_DOUT]] == 0} {
    create_bd_port -dir I -from 3 -to 0 ADC_DOUT
    connect_bd_net [get_bd_ports ADC_DOUT] [get_bd_pins AdcSubSystem_0/ADC_DOUT]
}
if {[llength [get_bd_ports -quiet ADC_RESET_N]] == 0} {
    create_bd_port -dir O ADC_RESET_N
    connect_bd_net [get_bd_ports ADC_RESET_N] [get_bd_pins AdcSubSystem_0/ADC_RESET_N]
}
if {[llength [get_bd_ports -quiet ADC_START_N]] == 0} {
    create_bd_port -dir O ADC_START_N
    connect_bd_net [get_bd_ports ADC_START_N] [get_bd_pins AdcSubSystem_0/ADC_START_N]
}
if {[llength [get_bd_ports -quiet ADC_CONVST_SAR]] == 0} {
    create_bd_port -dir O ADC_CONVST_SAR
    connect_bd_net [get_bd_ports ADC_CONVST_SAR] [get_bd_pins AdcSubSystem_0/ADC_CONVST_SAR]
}

assign_bd_address -offset 0xB0010000 -range 64K \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs AdcSubSystem_0/axi_quad_spi_0/AXI_LITE/Reg] -force
assign_bd_address -offset 0xB0020000 -range 64K \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs AdcSubSystem_0/ad7771_capture_0/S_AXI/Reg] -force

validate_bd_design
save_bd_design
set_property top TopDesign_wrapper [current_fileset]
update_compile_order -fileset sources_1
close_project
