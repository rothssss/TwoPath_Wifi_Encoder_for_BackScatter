// =============================================================================
// filelist_mac_fsm_80211b_checks.f : focused Path A regression bench.
//
// Usage (Cadence Xcelium):
//   xrun -sv -f tb/filelist_mac_fsm_80211b_checks.f -top tb_mac_fsm_80211b_checks
// =============================================================================

tb/timescale.v

rtl/common/crc32_80211.v
rtl/common/crc16_80211_hec.v
rtl/path_a/mac_fsm_80211b.v

tb/tb_mac_fsm_80211b_checks.sv
