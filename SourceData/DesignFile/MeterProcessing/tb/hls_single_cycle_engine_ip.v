// Non-project binding for the HLS single-cycle measurement engine IP
// customization. The product project
// gets this module from SourceData/IP/hls_single_cycle_engine_ip, while
// the xsim/OOC check flows compile the packaged RTL from
// SourceData/HLS_DesignFile/ip_repo and bind the name here. Never add
// this file to the Vivado project.
module hls_single_cycle_engine_ip (
    input           ap_clk,
    input           ap_rst_n,
    input  [31:0]   s_sample_TDATA,
    input           s_sample_TVALID,
    output          s_sample_TREADY,
    output [31:0]   m_axis_TDATA,
    output          m_axis_TVALID,
    input           m_axis_TREADY,
    output [3:0]    m_axis_TKEEP,
    output [3:0]    m_axis_TSTRB,
    output [0:0]    m_axis_TLAST,
    output [31:0]   m_result_TDATA,
    output          m_result_TVALID,
    input           m_result_TREADY
);
  hls_single_cycle_engine core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_sample_TDATA(s_sample_TDATA),
      .s_sample_TVALID(s_sample_TVALID),
      .s_sample_TREADY(s_sample_TREADY),
      .m_axis_TDATA(m_axis_TDATA),
      .m_axis_TVALID(m_axis_TVALID),
      .m_axis_TREADY(m_axis_TREADY),
      .m_axis_TKEEP(m_axis_TKEEP),
      .m_axis_TSTRB(m_axis_TSTRB),
      .m_axis_TLAST(m_axis_TLAST),
      .m_result_TDATA(m_result_TDATA),
      .m_result_TVALID(m_result_TVALID),
      .m_result_TREADY(m_result_TREADY)
  );
endmodule
