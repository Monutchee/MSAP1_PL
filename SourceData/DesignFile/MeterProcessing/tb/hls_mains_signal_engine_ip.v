// Non-project binding for the packaged M18 MainsSignalEngine customization.
// Product builds obtain this module name from the tracked XCI; focused checks
// compile the packaged top directly and bind it through this wrapper.
module hls_mains_signal_engine_ip (
    input          ap_clk,
    input          ap_rst_n,
    input  [695:0] s_frame_TDATA,
    input          s_frame_TVALID,
    output         s_frame_TREADY,
    output [31:0]  m_mcs_TDATA,
    output         m_mcs_TVALID,
    input          m_mcs_TREADY,
    output [3:0]   m_mcs_TKEEP,
    output [3:0]   m_mcs_TSTRB,
    output [0:0]   m_mcs_TLAST
);
  hls_mains_signal_engine core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_frame_TDATA(s_frame_TDATA),
      .s_frame_TVALID(s_frame_TVALID),
      .s_frame_TREADY(s_frame_TREADY),
      .m_mcs_TDATA(m_mcs_TDATA),
      .m_mcs_TVALID(m_mcs_TVALID),
      .m_mcs_TREADY(m_mcs_TREADY),
      .m_mcs_TKEEP(m_mcs_TKEEP),
      .m_mcs_TSTRB(m_mcs_TSTRB),
      .m_mcs_TLAST(m_mcs_TLAST)
  );
endmodule
