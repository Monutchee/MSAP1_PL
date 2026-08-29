// Non-project binding for the packaged M18 FlickerEngine customization.
// Product builds obtain this module name from the tracked XCI; focused checks
// compile the packaged top directly and bind it through this wrapper.
module hls_flicker_engine_ip (
    input          ap_clk,
    input          ap_rst_n,
    input  [655:0] s_frame_TDATA,
    input          s_frame_TVALID,
    output         s_frame_TREADY,
    output [31:0]  m_flk_TDATA,
    output         m_flk_TVALID,
    input          m_flk_TREADY,
    output [3:0]   m_flk_TKEEP,
    output [3:0]   m_flk_TSTRB,
    output [0:0]   m_flk_TLAST
);
  hls_flicker_engine core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_frame_TDATA(s_frame_TDATA),
      .s_frame_TVALID(s_frame_TVALID),
      .s_frame_TREADY(s_frame_TREADY),
      .m_flk_TDATA(m_flk_TDATA),
      .m_flk_TVALID(m_flk_TVALID),
      .m_flk_TREADY(m_flk_TREADY),
      .m_flk_TKEEP(m_flk_TKEEP),
      .m_flk_TSTRB(m_flk_TSTRB),
      .m_flk_TLAST(m_flk_TLAST)
  );
endmodule
