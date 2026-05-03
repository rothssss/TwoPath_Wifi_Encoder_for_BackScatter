# RFME APR Current Status

This is the short status file for the current working RFME digital APR flow as of **April 30, 2026**.

Use this file for:

- which post-APR OA cells are current
- which older cells should be ignored
- where the live RTL, synth, and APR artifacts are
- what the current PFD and divider states actually are

For the full procedure, use:

- [RFME_GOLDEN_RTL_SYNTH_APR_VIRTUOSO_FLOW_README.md](C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_GOLDEN_RTL_SYNTH_APR_VIRTUOSO_FLOW_README.md)

## Canonical flow

The working flow is:

1. real RTL in `verilog/<module>/<module>.v`
2. real DC synthesis in `synth/<module>`
3. Innovus APR in `apr/<module>`
4. `strm2oa` import into a raw lowercase RFME cell such as `RFME/pfd` or `RFME/div23511`
5. rebuild a fresh post-APR OA cell from the imported layout plus the latest `*.apr.pg.v`
6. if LVS counts extra physical-only decaps, mirror those counted decaps into the source schematic

Do not use the older semi-structural `ncverilog` gate-glue path as the source for APR.

## Server roots

- Verilog: `/rdf/VLSI/Projects/Naveed/RFME/verilog`
- Synthesis: `/rdf/VLSI/Projects/Naveed/RFME/synth`
- APR: `/rdf/VLSI/Projects/Naveed/RFME/apr`
- Virtuoso RFME lib: `/rdf/VLSI/Projects/Naveed/RFME/virtuoso/RFME`

## Current golden cells

### PFD

Current final OA cell:

- `RFME/PFD3`

Current source directories:

- RTL: `verilog/pfd`
- synth: `synth/pfd`
- APR: `apr/pfd`

Current latest APR artifacts on server:

- `/rdf/VLSI/Projects/Naveed/RFME/apr/pfd/pfd.gds` — `2026-04-30 14:02`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/pfd/pfd.apr.pg.v` — `2026-04-30 14:02`

Current OA timestamps:

- `RFME/PFD3/layout` — `2026-04-30 14:08`
- `RFME/PFD3/schematic` — `2026-04-30 14:08`
- `RFME/PFD3/symbol` — `2026-04-30 14:08`

Important current implementation details:

- this is the shortened reset-chain version
- post-APR reset chain is:
  - `u_clear_inv`
  - `u_clear_buf0`
- `u_clear_buf1` is intentionally gone
- source schematic includes the counted decap bank for LVS:
  - `1 x DCAP8BWP7T`
  - `5 x DCAP4BWP7T`
- current routed anti-backlash delay is about `0.211 ns`

Current top-level pins:

- `INPUT`
- `REF`
- `UP`
- `DOWN`
- `VDD`
- `VSS`

Use `PFD3`. Do not use `PFD` or `PFD2` as the current golden post-APR reference.

### Divider

Current final OA cell:

- `RFME/23511_POSTAPR6`

Current source directories:

- RTL: `verilog/div23511`
- synth: `synth/div23511`
- APR: `apr/div23511`

Current latest APR artifacts on server:

- `/rdf/VLSI/Projects/Naveed/RFME/apr/div23511/div23511.gds` — `2026-04-29 05:20`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/div23511/div23511.apr.pg.v` — `2026-04-29 05:20`

Current OA timestamps:

- `RFME/23511_POSTAPR6/layout` — `2026-04-29 10:05`
- `RFME/23511_POSTAPR6/schematic` — `2026-04-29 13:30`
- `RFME/23511_POSTAPR6/symbol` — `2026-04-29 10:05`

Important current implementation details:

- this is the fresh-cell divider path after the M1/pin/label fixes
- source schematic was patched to include the layout-counted decap bank for LVS:
  - `13 x DCAP8BWP7T`
  - `20 x DCAP4BWP7T`

Current top-level pins:

- `CLKIN`
- `DIVSEL0`
- `DIVSEL1`
- `BYPASS`
- `DIV23511OUT`
- `VDD`
- `VSS`

Use `23511_POSTAPR6`. Do not use `23511`, `23511_POSTAPR`, `23511_POSTAPR2`, `23511_POSTAPR3`, `23511_POSTAPR4`, or `23511_POSTAPR5` as the current final reference.

## Raw imported cells

These are the raw `strm2oa` import cells, not the final matched post-APR cells:

- `RFME/pfd`
- `RFME/div23511`

They are useful as import staging cells, but not the final source-of-truth cells for top-level use.

## Quick rules

- For PFD work, start from `RFME/PFD3`.
- For divider work, start from `RFME/23511_POSTAPR6`.
- If APR is rerun again, rebuild a fresh post-APR OA cell from the new `gds` and new `apr.pg.v`.
- If LVS instance counts look wrong, compare layout logic cells versus source logic cells first, then check whether counted decaps are missing from the source schematic.

## Current local helper files

Recent PFD refresh helpers:

- [\_tmp_build_pfd3_postapr_20260430_1402.il](C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_build_pfd3_postapr_20260430_1402.il)
- [\_tmp_build_pfd3_fresh_20260430_1402.il](C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_build_pfd3_fresh_20260430_1402.il)
- [\_tmp_run_pfd3_fresh_headless_20260430_1402.il](C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_run_pfd3_fresh_headless_20260430_1402.il)

Divider helpers still relevant to the current final cell:

- [\_tmp_build_23511_postapr5_20260429.il](C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_build_23511_postapr5_20260429.il)
- [\_tmp_build_23511_postapr6_20260429.il](C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_build_23511_postapr6_20260429.il)
- [\_tmp_finalize_23511_postapr_layout.il](C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_finalize_23511_postapr_layout.il)
