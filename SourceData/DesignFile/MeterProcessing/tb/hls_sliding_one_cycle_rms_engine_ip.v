// Non-project binding for the HLS sliding one-cycle RMS / PQ event
// engine IP customization.
//
// In the Vivado product project this module comes from the packaged-IP
// customization (SourceData/IP/hls_sliding_one_cycle_rms_engine_ip). The
// non-project flows -- the xsim check scripts and the focused
// out-of-context synthesis checks -- compile the packaged RTL straight
// from SourceData/HLS_DesignFile/ip_repo instead, and this wrapper binds
// the customization's module name to the packaged top so both flows
// elaborate the identical netlist.
//
// Never add this file to the Vivado project: it would collide with the
// module the IP customization generates.
module hls_sliding_one_cycle_rms_engine_ip (
    input          ap_clk,
    input          ap_rst_n,
    input  [863:0] s_frame_TDATA,
    input          s_frame_TVALID,
    output         s_frame_TREADY,
    output [31:0]  m_axis_TDATA,
    output         m_axis_TVALID,
    input          m_axis_TREADY,
    output [3:0]   m_axis_TKEEP,
    output [3:0]   m_axis_TSTRB,
    output [0:0]   m_axis_TLAST
);
  hls_sliding_one_cycle_rms_engine core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_frame_TDATA(s_frame_TDATA),
      .s_frame_TVALID(s_frame_TVALID),
      .s_frame_TREADY(s_frame_TREADY),
      .m_axis_TDATA(m_axis_TDATA),
      .m_axis_TVALID(m_axis_TVALID),
      .m_axis_TREADY(m_axis_TREADY),
      .m_axis_TKEEP(m_axis_TKEEP),
      .m_axis_TSTRB(m_axis_TSTRB),
      .m_axis_TLAST(m_axis_TLAST)
  );
endmodule
