// =============================================================================
// filelist.f : source list for the functional testbench.
//
// Usage (Cadence Xcelium):
//   xrun -sv -f tb/filelist.f +define+ASSERT_ON -top tb_multi_mode_tx_baseband
//
// Add `+define+WAVES` to enable VCD dumping.
// =============================================================================

// Default timescale for every RTL module in the filelist.  Listed first so
// the `timescale directive sticks for the whole compilation unit.
tb/timescale.v

// CDC / common
rtl/cdc/sync_2ff.v
rtl/cdc/pulse_sync.v
rtl/cdc/reset_sync.v
rtl/cdc/async_fifo.v

rtl/common/clock_mux_static.v
rtl/common/scrambler_x7x4.v
rtl/common/crc32_80211.v
rtl/common/crc16_80211_hec.v
rtl/common/phase_to_iq.v

// Path A
rtl/path_a/phy_a_rotator.v
rtl/path_a/mac_fsm_80211b.v

// Path B
rtl/path_b/mac_fsm_custom.v
rtl/path_b/phy_qam_custom.v

// Top
rtl/multi_mode_tx_baseband.v

// Testbench
tb/tb_multi_mode_tx_baseband.sv
