#ifndef MSAP1_HARMONIC_ENGINE_HPP
#define MSAP1_HARMONIC_ENGINE_HPP

#ifndef AP_INT_MAX_W
#define AP_INT_MAX_W 8192
#endif

#include "measurement_record.hpp"

#include <ap_axi_sdata.h>
#include <ap_int.h>
#include <hls_stream.h>

// Vivado handoff contract for an AMD/Xilinx FFT v9.1 configured as:
//   transform length       4096
//   input/output width     24-bit fixed point, complex
//   scaling                block floating point
//   output ordering        bit reversed (XK_INDEX makes ordering irrelevant)
//   TUSER fields           XK_INDEX then BLK_EXP, byte padded
//   TLAST                  asserted on bin 4095 of every channel frame
// The FFT TDATA layout is {imag[23:0], real[23:0]}.  TUSER[11:0] is XK_INDEX,
// TUSER[12] is MeterCore's structural-fault marker, TUSER[15:13] is padding,
// TUSER[20:16] is the five-bit BLK_EXP, and
// TUSER[23:21] is padding.  hls::axis_data keeps the HLS port free of
// TKEEP/TSTRB, matching the FFT's native AXIS interface.
typedef hls::axis_data<ap_uint<48>, AXIS_ENABLE_LAST | AXIS_ENABLE_USER, 24>
    harmonic_fft_axis_t;
typedef hls::stream<harmonic_fft_axis_t> harmonic_fft_axis_stream_t;

static const int HARMONIC_FFT_LENGTH = 4096;
static const int HARMONIC_FFT_INDEX_LSB = 0;
static const int HARMONIC_FFT_FAULT_BIT = 12;
static const int HARMONIC_FFT_EXPONENT_LSB = 16;
static const int HARMONIC_FFT_EXPONENT_BITS = 5;

// One context beat precedes the seven FFT frames belonging to a spectrum.
// It is packed by SpectralFrontend after a whole grid-synchronous window is
// closed.  All reserved bits must be zero.
//   [31:0]    configuration generation
//   [63:32]   source sample rate, frames/s
//   [95:64]   source frames covered by the window
//   [103:96]  active channel mask
//   [111:104] frontend flags (below)
//   [119:112] nominal grid frequency (50 or 60)
//   [127:120] cycles in the window (10 or 12)
//   [135:128] qualified maximum order
//   [143:136] filter/resampler profile identifier
//   [159:144] reserved zero
//   [191:160] measured fundamental frequency, millihertz
//   [255:192] first source-sample index
//   [287:256] records dropped after this engine
//   [319:288] complete source windows dropped before this engine
//   [543:320] seven Q16.16 micro-unit/count calibration scales
//   [575:544] reserved zero
static const int HARMONIC_CONTEXT_BITS = 576;
typedef ap_uint<HARMONIC_CONTEXT_BITS> harmonic_context_t;
typedef hls::stream<harmonic_context_t> harmonic_context_stream_t;

static const int HARMONIC_CTX_GENERATION_LSB = 0;
static const int HARMONIC_CTX_SAMPLE_RATE_LSB = 32;
static const int HARMONIC_CTX_SAMPLE_COUNT_LSB = 64;
static const int HARMONIC_CTX_VALID_MASK_LSB = 96;
static const int HARMONIC_CTX_FLAGS_LSB = 104;
static const int HARMONIC_CTX_NOMINAL_HZ_LSB = 112;
static const int HARMONIC_CTX_CYCLE_COUNT_LSB = 120;
static const int HARMONIC_CTX_QUALIFIED_MAX_LSB = 128;
static const int HARMONIC_CTX_FILTER_PROFILE_LSB = 136;
static const int HARMONIC_CTX_MEASURED_MILLIHZ_LSB = 160;
static const int HARMONIC_CTX_FIRST_SAMPLE_LSB = 192;
static const int HARMONIC_CTX_EMIT_DROPS_LSB = 256;
static const int HARMONIC_CTX_RESULT_DROPS_LSB = 288;
static const int HARMONIC_CTX_SCALE_LSB = 320;

static const int HARMONIC_CTX_GRID_LOCKED_BIT = 0;
static const int HARMONIC_CTX_CONDITIONER_VALID_BIT = 1;
static const int HARMONIC_CTX_FIRST_AFTER_DISCONTINUITY_BIT = 2;
static const int HARMONIC_CTX_RATE_LIMITED_BIT = 3;

void hls_harmonic_engine(harmonic_context_stream_t &s_context,
                         harmonic_fft_axis_stream_t &s_fft,
                         record_axis_stream_t &m_records);

#endif  // MSAP1_HARMONIC_ENGINE_HPP
