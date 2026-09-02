# Confirm Vivado IP Integrator recognizes the MeterCore module-reference
# boundary and its named AXI interfaces without modifying the product project.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set work_root [file join /tmp msap1_metering_module_reference]
file delete -force $work_root
file mkdir $work_root
cd $work_root

create_project -in_memory -part xck26-sfvc784-2LV-c
set_property source_mgmt_mode All [current_project]
set vhdl_2008_sources [list \
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root MeterCommon grid_timing_pkg.vhd] \
  [file join $design_root MeterCommon pq_event_pkg.vhd] \
  [file join $design_root MeterCommon measurement_record_bus_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_power_quality_protocol_pkg.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_pkg.vhd] \
  [file join $design_root Ad7771Capture ad7771_receiver.vhd] \
  [file join $design_root Ad7771Capture ad7771_axi_regs.vhd] \
  [file join $design_root Ad7771Capture ad7771_dclk_meter.vhd] \
  [file join $design_root Ad7771Capture ad7771_capture.vhd] \
  [file join $design_root AdcConversion adc_conversion_axi_regs.vhd] \
  [file join $design_root AdcConversion adc_conversion.vhd] \
  [file join $design_root MeterProcessing meter_frequency_pkg.vhd] \
  [file join $design_root MeterProcessing meter_processing_axi_regs.vhd] \
  [file join $design_root MeterProcessing meter_unsigned_divider.vhd] \
  [file join $design_root MeterProcessing meter_zero_crossing.vhd] \
  [file join $design_root MeterProcessing meter_frequency_estimator.vhd] \
  [file join $design_root MeterProcessing meter_frequency.vhd] \
  [file join $design_root MeterProcessing grid_cycle_timing.vhd] \
  [file join $design_root MeterProcessing record_word_tap.vhd] \
  [file join $design_root MeterProcessing meter_r5_aggregation_pkg.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_conditioner.vhd] \
  [file join $design_root MeterProcessing meter_frequency_10s_observer.vhd] \
  [file join $design_root MeterProcessing meter_r5_harmonic_pkg.vhd] \
  [file join $design_root MeterProcessing meter_r5_harmonic_export.vhd] \
  [file join $design_root MeterProcessing meter_axis_packet_arbiter_2to1.vhd] \
  [file join $design_root MeterProcessing meter_r5_fixed_packet_export.vhd] \
  [file join $design_root MeterProcessing meter_axis_packet_arbiter_5to1.vhd] \
  [file join $design_root MeterProcessing meter_r5_aggregation_export.vhd] \
  [file join $design_root MeterProcessing meter_voltage_sample_batcher.vhd] \
  [file join $design_root MeterCore adc_simulator_pkg.vhd] \
  [file join $design_root MeterCore adc_simulator.vhd] \
  [file join $design_root MeterCore adc_source_mux.vhd] \
  [file join $design_root MeterCore meter_waveform_axi_regs.vhd] \
  [file join $design_root MeterCore meter_time_control_axi_regs.vhd] \
  [file join $design_root MeterCore meter_waveform.vhd] \
  [file join $design_root MeterCore meter_core.vhd]]
set wrapper_sources [list \
  [file join $design_root MeterCore MeterCore_Wrapper.vhd]]

add_files -norecurse [concat $vhdl_2008_sources $wrapper_sources]
set_property FILE_TYPE {VHDL 2008} [get_files $vhdl_2008_sources]
update_compile_order -fileset sources_1
create_bd_design metering_module_reference_check

create_bd_cell -type module -reference MeterCore_Wrapper meter_core

set expected_interfaces [list \
  meter_core/S_AXI_CAPTURE meter_core/S_AXI_CONVERSION \
  meter_core/S_AXI_PROCESSING meter_core/S_AXI_WAVEFORM \
  meter_core/S_AXI_TIME \
  meter_core/S_AXI_SIMULATOR \
  meter_core/M_AXIS_PQ meter_core/M_AXIS_HARMONIC \
  meter_core/M_AXIS_SCYC \
  meter_core/M_AXIS_R5_AGG_INPUT \
  meter_core/M_AXIS_WAVEFORM \
  meter_core/M_AXIS_FFT_DATA meter_core/S_AXIS_FFT_DATA \
  meter_core/M_AXIS_FFT_CONFIG meter_core/S_AXIS_FFT_STATUS]
foreach interface_name $expected_interfaces {
  if {[llength [get_bd_intf_pins -quiet $interface_name]] != 1} {
    error "missing inferred interface $interface_name"
  }
}

foreach legacy_interface [list meter_core/M_AXIS_MTR1 meter_core/M_AXIS_MTR2] {
  if {[llength [get_bd_intf_pins -quiet $legacy_interface]] != 0} {
    error "retired interface $legacy_interface is still present"
  }
}

foreach event_pin [list \
    xfft_event_frame_started \
    xfft_event_tlast_unexpected \
    xfft_event_tlast_missing \
    xfft_event_status_channel_halt \
    xfft_event_data_in_channel_halt \
    xfft_event_data_out_channel_halt] {
  if {[llength [get_bd_pins -quiet meter_core/$event_pin]] != 1} {
    error "missing XFFT event pin meter_core/$event_pin"
  }
}

set meter_clock [get_bd_pins -quiet meter_core/aclk]
if {[llength $meter_clock] != 1} {
  error "missing inferred MeterCore clock pin"
}
if {[get_property CONFIG.FREQ_HZ $meter_clock] != 99999001} {
  error "MeterCore aclk FREQ_HZ metadata was not inferred as 99999001"
}
if {[get_property CONFIG.ASSOCIATED_BUSIF $meter_clock] ne \
    "S_AXI_CAPTURE:S_AXI_CONVERSION:S_AXI_PROCESSING:S_AXI_WAVEFORM:S_AXI_TIME:S_AXI_SIMULATOR:M_AXIS_PQ:M_AXIS_HARMONIC:M_AXIS_SCYC:M_AXIS_R5_AGG_INPUT:M_AXIS_WAVEFORM:M_AXIS_FFT_DATA:S_AXIS_FFT_DATA:M_AXIS_FFT_CONFIG:S_AXIS_FFT_STATUS"} {
  error "MeterCore aclk AXI interface associations were not inferred"
}

set meter_reset [get_bd_pins -quiet meter_core/aresetn]
if {[llength $meter_reset] != 1} {
  error "missing inferred MeterCore reset pin"
}
if {[get_property CONFIG.POLARITY $meter_reset] ne "ACTIVE_LOW"} {
  error "MeterCore aresetn polarity metadata was not inferred as ACTIVE_LOW"
}

puts "Metering module-reference interface inference PASS"
