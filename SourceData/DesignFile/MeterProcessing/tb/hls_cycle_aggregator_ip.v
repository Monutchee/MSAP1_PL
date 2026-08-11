// Non-project binding for the HLS cycle-aggregator IP customization.
//
// In the Vivado product project, module hls_cycle_aggregator_ip comes from
// the packaged-IP customization (SourceData/IP/hls_cycle_aggregator_ip).
// The non-project flows -- the xsim check scripts and the focused
// out-of-context synthesis checks -- compile the packaged RTL straight
// from SourceData/HLS_DesignFile/ip_repo instead, and this wrapper binds
// the customization's module name to the packaged top so both flows
// elaborate the identical netlist.
//
// Never add this file to the Vivado project: it would collide with the
// module the IP customization generates.
module hls_cycle_aggregator_ip (
    input          ap_clk,
    input          ap_rst_n,
    input  [807:0] s_basic_TDATA,
    input          s_basic_TVALID,
    output         s_basic_TREADY,
    output [967:0] m_aggregate_TDATA,
    output         m_aggregate_TVALID,
    input          m_aggregate_TREADY
);
  hls_cycle_aggregator core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_basic_TDATA(s_basic_TDATA),
      .s_basic_TVALID(s_basic_TVALID),
      .s_basic_TREADY(s_basic_TREADY),
      .m_aggregate_TDATA(m_aggregate_TDATA),
      .m_aggregate_TVALID(m_aggregate_TVALID),
      .m_aggregate_TREADY(m_aggregate_TREADY)
  );
endmodule
