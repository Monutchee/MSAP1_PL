// Non-project binding for the packaged M16 HarmonicEngine customization.
// Product synthesis gets this module name from the tracked XCI; focused
// xsim checks compile the packaged RTL and bind it here.
module hls_harmonic_engine_ip (
    input           ap_clk,
    input           ap_rst_n,
    input  [575:0]  s_context_TDATA,
    input           s_context_TVALID,
    output          s_context_TREADY,
    input  [47:0]   s_fft_TDATA,
    input           s_fft_TVALID,
    output          s_fft_TREADY,
    input  [23:0]   s_fft_TUSER,
    input  [0:0]    s_fft_TLAST,
    output [31:0]   m_records_TDATA,
    output          m_records_TVALID,
    input           m_records_TREADY,
    output [3:0]    m_records_TKEEP,
    output [3:0]    m_records_TSTRB,
    output [0:0]    m_records_TLAST
);
  hls_harmonic_engine core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_context_TDATA(s_context_TDATA),
      .s_context_TVALID(s_context_TVALID),
      .s_context_TREADY(s_context_TREADY),
      .s_fft_TDATA(s_fft_TDATA),
      .s_fft_TVALID(s_fft_TVALID),
      .s_fft_TREADY(s_fft_TREADY),
      .s_fft_TUSER(s_fft_TUSER),
      .s_fft_TLAST(s_fft_TLAST),
      .m_records_TDATA(m_records_TDATA),
      .m_records_TVALID(m_records_TVALID),
      .m_records_TREADY(m_records_TREADY),
      .m_records_TKEEP(m_records_TKEEP),
      .m_records_TSTRB(m_records_TSTRB),
      .m_records_TLAST(m_records_TLAST)
  );
endmodule
