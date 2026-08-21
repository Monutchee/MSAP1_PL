// Non-project binding for the HLS cycle-block aggregation engine IP
// customization.
//
// In the Vivado product project, module hls_aggregation_engine_ip comes from
// the packaged-IP customization (SourceData/IP/hls_aggregation_engine_ip).
// The non-project flows -- the xsim check scripts and the focused
// out-of-context synthesis checks -- compile the packaged RTL straight from
// SourceData/HLS_DesignFile/ip_repo instead, and this wrapper binds the
// customization's module name to the packaged top so both flows elaborate
// the identical netlist.
//
// Never add this file to the Vivado project: it would collide with the
// module the IP customization generates.
module hls_aggregation_engine_ip (
    input           ap_clk,
    input           ap_rst_n,
    input  [7391:0] s_result_TDATA,
    input           s_result_TVALID,
    output          s_result_TREADY,
    output [31:0]   m_basic_TDATA,
    output          m_basic_TVALID,
    input           m_basic_TREADY,
    output [3:0]    m_basic_TKEEP,
    output [3:0]    m_basic_TSTRB,
    output [0:0]    m_basic_TLAST,
    output [31:0]   m_agg_TDATA,
    output          m_agg_TVALID,
    input           m_agg_TREADY,
    output [3:0]    m_agg_TKEEP,
    output [3:0]    m_agg_TSTRB,
    output [0:0]    m_agg_TLAST
);
  hls_aggregation_engine core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_result_TDATA(s_result_TDATA),
      .s_result_TVALID(s_result_TVALID),
      .s_result_TREADY(s_result_TREADY),
      .m_basic_TDATA(m_basic_TDATA),
      .m_basic_TVALID(m_basic_TVALID),
      .m_basic_TREADY(m_basic_TREADY),
      .m_basic_TKEEP(m_basic_TKEEP),
      .m_basic_TSTRB(m_basic_TSTRB),
      .m_basic_TLAST(m_basic_TLAST),
      .m_agg_TDATA(m_agg_TDATA),
      .m_agg_TVALID(m_agg_TVALID),
      .m_agg_TREADY(m_agg_TREADY),
      .m_agg_TKEEP(m_agg_TKEEP),
      .m_agg_TSTRB(m_agg_TSTRB),
      .m_agg_TLAST(m_agg_TLAST)
  );
endmodule
