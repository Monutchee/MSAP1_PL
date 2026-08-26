// Non-project binding for the HLS ADC-simulator waveform engine IP
// customization.
//
// In the Vivado product project, module hls_sim_wave_engine_ip comes from
// the packaged-IP customization (SourceData/IP/hls_sim_wave_engine_ip).
// The non-project flows -- the xsim check scripts and the focused
// out-of-context synthesis checks -- compile the packaged RTL straight
// from SourceData/HLS_DesignFile/ip_repo instead, and this wrapper binds
// the customization's module name to the packaged top so both flows
// elaborate the identical netlist.
//
// Never add this file to the Vivado project: it would collide with the
// module the IP customization generates.
module hls_sim_wave_engine_ip (
    input           ap_clk,
    input           ap_rst_n,
    input  [1567:0] s_request_TDATA,
    input           s_request_TVALID,
    output          s_request_TREADY,
    output [263:0]  m_frame_TDATA,
    output          m_frame_TVALID,
    input           m_frame_TREADY
);
  hls_sim_wave_engine core (
      .ap_clk(ap_clk),
      .ap_rst_n(ap_rst_n),
      .s_request_TDATA(s_request_TDATA),
      .s_request_TVALID(s_request_TVALID),
      .s_request_TREADY(s_request_TREADY),
      .m_frame_TDATA(m_frame_TDATA),
      .m_frame_TVALID(m_frame_TVALID),
      .m_frame_TREADY(m_frame_TREADY)
  );
endmodule
