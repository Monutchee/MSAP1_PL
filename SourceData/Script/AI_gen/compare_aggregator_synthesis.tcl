# Side-by-side out-of-context synthesis of the two 150/180-cycle
# aggregator implementations at the metering clock (100 MHz):
#
#   rtl_engine  meter_cycle_aggregator via its zero-logic record shim
#               (meter_cycle_aggregator_tbshim; records cannot be
#               synthesis top-level ports)
#   hls_core    hls_cycle_aggregator, the HLS-generated core alone
#   hls_shimmed meter_cycle_aggregator_hls_shim wrapping the core: what
#               the trial actually costs inside MeterCore
#
# Prints one comparison table and writes the full utilization/timing
# reports to /tmp/msap1_aggregator_compare/.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set design_root [file join $project_root SourceData DesignFile]
set report_root [file join /tmp msap1_aggregator_compare]
file mkdir $report_root

set hls_aggregator_hdl [file join $project_root SourceData HLS_DesignFile \
  ip_repo CycleAggregator hdl verilog]
if {![file isdirectory $hls_aggregator_hdl]} {
  error "missing $hls_aggregator_hdl -- run make_HLS.sh or HLS_DesignFile/run_hls.sh first"
}

set_param general.maxThreads 2

set common_vhdl [list \
  [file join $design_root MeterCommon metering_pkg.vhd] \
  [file join $design_root MeterCommon grid_timing_pkg.vhd] \
  [file join $design_root MeterCommon measurement_record_bus_pkg.vhd]]

# name -> {vhdl_2008_sources verilog_sources top}
set candidates [list \
  rtl_engine [list \
    [concat $common_vhdl \
      [list [file join $design_root MeterProcessing meter_cycle_aggregator.vhd] \
            [file join $design_root MeterProcessing tb meter_cycle_aggregator_tbshim.vhd]]] \
    {} \
    meter_cycle_aggregator_tbshim] \
  hls_core [list \
    {} \
    [lsort [glob -directory $hls_aggregator_hdl *.v]] \
    hls_cycle_aggregator] \
  hls_shimmed [list \
    [concat $common_vhdl \
      [list [file join $design_root MeterProcessing meter_cycle_aggregator_hls_shim.vhd]]] \
    [concat \
      [lsort [glob -directory $hls_aggregator_hdl *.v]] \
      [list [file join $design_root MeterProcessing tb hls_cycle_aggregator_ip.v]]] \
    meter_cycle_aggregator_hls_shim]]

proc extract_used {report row} {
  foreach line [split $report "\n"] {
    if {[regexp "^\\|\\s*$row\\s*\\|" $line]} {
      set fields [split $line "|"]
      return [string trim [lindex $fields 2]]
    }
  }
  return "?"
}

set results {}
foreach {name spec} $candidates {
  lassign $spec vhdl_sources verilog_sources top
  create_project -in_memory -part xck26-sfvc784-2LV-c
  if {[llength $vhdl_sources] > 0} {
    read_vhdl -vhdl2008 $vhdl_sources
  }
  if {[llength $verilog_sources] > 0} {
    read_verilog $verilog_sources
  }
  synth_design -top $top -mode out_of_context
  set clock_port [get_ports -quiet aclk]
  if {[llength $clock_port] == 0} {
    set clock_port [get_ports -quiet ap_clk]
  }
  create_clock -name metering_aclk -period 10.000 $clock_port
  report_utilization -file [file join $report_root ${name}_utilization.rpt]
  set utilization [report_utilization -return_string]
  report_timing_summary -delay_type max \
    -file [file join $report_root ${name}_timing.rpt]
  set worst_slack [get_property SLACK [lindex \
    [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
  dict set results $name [dict create \
    lut  [extract_used $utilization {CLB LUTs\*?}] \
    ff   [extract_used $utilization {CLB Registers}] \
    dsp  [extract_used $utilization {DSPs}] \
    bram [extract_used $utilization {Block RAM Tile}] \
    wns  $worst_slack]
  close_project
}

puts ""
puts "150/180-cycle aggregator, out-of-context synthesis, xck26 @ 100 MHz"
puts [format "%-12s %8s %8s %6s %6s %10s" \
  implementation LUT FF DSP BRAM "WNS (ns)"]
foreach {name spec} $candidates {
  set r [dict get $results $name]
  puts [format "%-12s %8s %8s %6s %6s %10s" $name \
    [dict get $r lut] [dict get $r ff] [dict get $r dsp] \
    [dict get $r bram] [dict get $r wns]]
}
puts ""
puts "Full reports: $report_root"
puts "Aggregator synthesis comparison PASS"
