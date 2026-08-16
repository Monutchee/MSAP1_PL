// Non-project binding for the HLS MTR2 engine IP customization.
//
// In the Vivado product project, module hls_mtr2_engine_ip comes from
// the packaged-IP customization (SourceData/IP/hls_mtr2_engine_ip).
// The non-project flows -- the xsim check scripts and the focused
// out-of-context synthesis checks -- compile the packaged RTL straight
// from SourceData/HLS_DesignFile/ip_repo instead, and this wrapper binds
// the customization's module name to the packaged top so both flows
// elaborate the identical netlist.
//
// Never add this file to the Vivado project: it would collide with the
// module the IP customization generates.
module hls_mtr2_engine_ip (
    input          ap_clk,
    input          ap_rst_n,
    input  [807:0] s_basic_TDATA,
    input          s_basic_TVALID,
    output         s_basic_TREADY,
    output [31:0]  m_axis_TDATA,
    output         m_axis_TVALID,
    input          m_axis_TREADY,
    output [3:0]   m_axis_TKEEP,
    output [3:0]   m_axis_TSTRB,
    output [0:0]   m_axis_TLAST
);
  hls_mtr2_engine core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_basic_TDATA(s_basic_TDATA),
      .s_basic_TVALID(s_basic_TVALID),
      .s_basic_TREADY(s_basic_TREADY),
      .m_axis_TDATA(m_axis_TDATA),
      .m_axis_TVALID(m_axis_TVALID),
      .m_axis_TREADY(m_axis_TREADY),
      .m_axis_TKEEP(m_axis_TKEEP),
      .m_axis_TSTRB(m_axis_TSTRB),
      .m_axis_TLAST(m_axis_TLAST)
  );
endmodule
