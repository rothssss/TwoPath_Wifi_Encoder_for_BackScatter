# RFME Golden RTL -> Synth -> APR -> Virtuoso Flow

Last validated: 2026-04-29

Validated clean-path blocks:
- `pfd`
- `div23511`

Validated imported post-APR cells:
- `RFME/PFD3`
- `RFME/23511_POSTAPR5`

This is the source-of-truth flow for taking a small RFME digital block from real RTL to real synthesis to Innovus APR to a usable Virtuoso layout cell.

This README exists because earlier partial flows were misleading. The clean result came only after following these rules:

- start from real RTL, not semi-manual structural gate glue
- synthesize with real DC constraints
- run a simple APR flow that preserves the synthesized logic
- validate against the real DRC result, not just Innovus geometry
- import the fresh GDS into a fresh OA cell when old RVE markers become stale

Use this flow for future RFME controller-scale digital blocks unless there is a strong reason not to.

## 1. Source of truth paths

Local workspace root:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME`

Remote RFME roots:

- Verilog: `/rdf/VLSI/Projects/Naveed/RFME/verilog`
- Synth: `/rdf/VLSI/Projects/Naveed/RFME/synth`
- APR: `/rdf/VLSI/Projects/Naveed/RFME/apr`
- Virtuoso project: `/rdf/VLSI/Projects/Naveed/RFME/virtuoso`

Do not invent alternate roots.

## 2. Bridge and access rules

For live Virtuoso work, use the direct bridge fallback flow.

Primary references:

- [RFME_VIRTUOSO_BRIDGE_DIRECT_FALLBACK_README.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_VIRTUOSO_BRIDGE_DIRECT_FALLBACK_README.md)
- [RFME_VIRTUOSO_BRIDGE_ACCESS_README.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_VIRTUOSO_BRIDGE_ACCESS_README.md)

Known session map:

| Display | Session | Port |
|---|---|---:|
| `:96` | default | `5950` |
| `:95` | `V95` | `5951` |
| `:23` | `V23` | `5952` |
| `:21` | `V21` | `5953` |

Healthy bridge check:

```powershell
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe `
  C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py `
  --host opus.ece.rice.edu --port 5951 "1+2"
```

Expected output:

- `3`

Important bridge rules:

- keep the Virtuoso/VNC session open
- use `RBStop()`, not `RBStopAll()`
- heavy Cadence jobs should be launched headless, not held open through the live bridge
- never load a SKILL file containing `exit()` directly into the live bridge session
- if the bridge becomes busy or appears stale, do not trust the old DRC window; use a fresh imported cell or rerun headless

## 3. Naming rules

Normal naming:

- folder name = module name
- RTL filename = `<module>.v`
- top module name = `<module>`

Examples:

- `verilog/pfd/pfd.v`
- `verilog/div23511/div23511.v`

When importing a post-APR layout back into Virtuoso, do not overwrite the original schematic cell unless that is explicitly desired.

Use a distinct post-APR cell:

- `PFD3`
- `23511_POSTAPR5`

Fresh names are useful when old DRC result databases are still attached to earlier cells.

Historical note:

- `PFD2` was an intermediate repair cell and is not the final golden reference
- `PFD3` is the fresh-cell rebuild that matched the final clean DRC/LVS result

## 4. The winning high-level flow

The working sequence is:

1. Write or clean real RTL.
2. Functionally verify the RTL.
3. Push RTL to the RFME server tree.
4. Synthesize with Design Compiler.
5. Run Innovus APR from the synthesized netlist.
6. Check Innovus geometry, connectivity, antenna, and timing.
7. If signoff DRC still fails, fix the actual recurring geometry cause and rerun APR.
8. Import the fresh GDS into `RFME`.
9. Build a fresh matched post-APR OA cell with `schematic`, `symbol`, and `layout`.
10. Run DRC on the fresh post-APR cell, not on stale results.

Do not skip step 2 or step 10.

## 5. RTL requirements

### 5.1 `pfd`

The clean RTL is:

- [verilog/pfd/pfd.v](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/verilog/pfd/pfd.v)

Key behavior requirements:

- `UP` is active-low
- `DOWN` is active-high
- there is a deliberate reset delay path after both latches assert

This delay is essential for PLL use.

The implementation that worked:

- `RTL_SIM` uses `assign #(RESET_DELAY)` for fast functional simulation
- synthesis uses a preserved chain:
  - `INVD1BWP7T`
  - `BUFFD3BWP7T`
  - `BUFFD3BWP7T`

These delay cells are protected in synthesis by `set_dont_touch`.

### 5.2 `div23511`

The clean RTL is:

- [verilog/div23511/div23511.v](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/verilog/div23511/div23511.v)

Behavior requirements:

- `BYPASS` passes `CLKIN`
- divide-by-2, 3, 5, and 11 all work
- steady-state output is 50% duty cycle

The working RTL uses:

- one posedge domain for mode/config and main division state
- one negedge process for odd-divider half-cycle shaping
- XOR of `odd_pos_q` and `odd_neg_q` for 50% duty odd division

## 6. Functional verification before synth

Do this before APR.

Local testbenches:

- `pfd`: [verilog/pfd/pfd_rtl_tb.v](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/verilog/pfd/pfd_rtl_tb.v)
- `div23511`: [verilog/div23511/div23511_rtl_tb.v](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/verilog/div23511/div23511_rtl_tb.v)

Minimum checks:

- `pfd`
  - input leads -> `UP`
  - ref leads -> `DOWN`
  - delayed reset returns to idle
- `div23511`
  - bypass mode
  - `/2`
  - `/3`
  - `/5`
  - `/11`
  - duty-cycle sanity in steady state

Do not rely on old structural `ncverilog` glue as the golden source for these blocks.

## 7. Push to server

Use the RFME server roots directly.

Example:

```powershell
$module = "div23511"

ssh opus-vb "mkdir -p /rdf/VLSI/Projects/Naveed/RFME/verilog/$module"
scp "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\$module\$module.v" `
    "opus-vb:/rdf/VLSI/Projects/Naveed/RFME/verilog/$module/$module.v"
```

Verify what is actually on the server before synth.

## 8. Synthesis setup

The proven synth templates are the current RFME folders:

- [synth/pfd/pfd.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/synth/pfd/pfd.tcl)
- [synth/div23511/div23511.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/synth/div23511/div23511.tcl)

Use the RFME `blankexample` structure only as a starting scaffold. Then retarget the Tcl fully.

### 8.1 `pfd` synth constraints

Working settings:

- `3.333 ns` clocks on `INPUT` and `REF`
- `0.067 ns` uncertainty
- `0.067 ns` transition
- async clock groups between `INPUT_CLK` and `REF_CLK`
- delay-chain cells marked `dont_touch`

### 8.2 `div23511` synth constraints

Working settings:

- `3.333 ns` clock on `CLKIN`
- `0.267 ns` uncertainty
- `0.267 ns` transition
- static control pins false-pathed:
  - `DIVSEL0`
  - `DIVSEL1`
  - `BYPASS`
- output false-pathed as synchronous data:
  - `DIV23511OUT`

This is important. `DIV23511OUT` is a derived clock-style output, not ordinary synchronous data against `CLKIN`.

### 8.3 Synthesis run

Run:

```bash
cd /rdf/VLSI/Projects/Naveed/RFME/synth/<module>
make syn
```

Expected outputs:

- `<module>.nl.v`
- `<module>.dc.rpt`
- `<module>.dc.sdf`
- `<module>.sdc`

## 9. APR deck rules

The proven APR top scripts are:

- [apr/pfd/pfd.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/pfd/pfd.tcl)
- [apr/div23511/div23511.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/div23511/div23511.tcl)

The important philosophy is simple:

- keep APR close to the synthesized logic
- do not encourage aggressive logic explosion
- do not use experimental physical-only recipes unless signoff evidence requires them

### 9.1 Common APR settings that worked

- `setOptMode -restruct false`
- checkerboard taps:
  - `addWellTap -cell {TAPCELLBWP7T} -prefix WELLTAP -cellInterval 50 -checkerBoard`
- place first, then route
- add tie cells after placement:
  - `addTieHiLo -cell {TIEHBWP7T TIELBWP7T} -prefix TIE`
- use normal filler insertion after routing
- export `def`, `lef`, `apr.v`, `apr.pg.v`, `gds`, `spef`, and `apr.sdf`

### 9.2 Common APR checks that must pass

- `${my_toplevel}.geom.rpt`
- `${my_toplevel}.conn.rpt`
- `${my_toplevel}.antenna.rpt`

You want:

- geometry clean
- connectivity clean
- antenna clean

## 10. Floorplan and pin-placement rules

### 10.1 `pfd`

Working floorplan:

- [apr/pfd/scripts/floorplan.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/pfd/scripts/floorplan.tcl)

Important choices:

- utilization target `0.50`
- `INPUT` and `REF` on the left
- `UP` and `DOWN` on the right
- power pins on top
- signal pins on `METAL3`
- power pins on `METAL4`

### 10.2 `div23511`

Working floorplan:

- [apr/div23511/scripts/floorplan.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/div23511/scripts/floorplan.tcl)

Important choices:

- utilization target `0.55`
- preferred PLL-facing pin order:
  - `CLKIN`
  - `DIVSEL0`
  - `DIVSEL1`
  - `BYPASS`
  - `DIV23511OUT`
- power pins on top
- use fixed IO file when present:
  - `apr/div23511/scripts/pll_compat.io`

If pin placement falls off the design space or routing is missing, do not trust the cell. Fix the floorplan or IO template and rerun.

## 11. The crucial divider DRC fix

This was the real final blocker for `div23511`.

The remaining signoff failure was not random long metal. It was recurring singular `M1.S.1` spacing hotspots where NanoRoute terminated horizontal M1 access near filler/tap/DCAP metal and VIA12 access geometry.

The successful fix is:

- keep the clean RTL/synth/APR flow
- block M1 routing in the exact repeated hotspot windows
- force routing up to safer geometry

The hotspot file is:

- [apr/div23511/scripts/m1_drc_hotspots.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/div23511/scripts/m1_drc_hotspots.tcl)

It is sourced in:

- [apr/div23511/div23511.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/div23511/div23511.tcl)

This is not a generic first-step recommendation for every block. It is the proven block-specific fix for `div23511`.

One very important success criterion from the fresh rerun:

- Innovus reported routed `METAL1 = 0 um`

That is exactly what you want for this repaired divider implementation.

## 12. APR launch

Run APR from the server tree, not from ad hoc local copies.

Typical run:

```bash
cd /rdf/VLSI/Projects/Naveed/RFME/apr/<module>
innovus -overwrite -no_gui -init <module>.tcl > run.log 2>&1
```

For headless launch from the bridge environment, use `system("bash -lc '...innovus...'")` or a separate shell, not a long interactive bridge transaction.

## 13. APR success criteria

Do not call the run good until all of these are true:

- synth netlist is from the clean RTL
- geometry report is clean
- connectivity report is clean
- antenna report is clean
- timing is acceptable for the target frequency
- imported layout terminals match the schematic terminals
- signoff DRC agrees

For the validated `300 MHz` settings:

- `pfd`: `3.333 ns` clocks, `0.067 ns` uncertainty
- `div23511`: `3.333 ns` clock, `0.267 ns` uncertainty

## 14. Import back into Virtuoso

Use `strmin` into the RFME library.

The proven pattern is:

```bash
/opt/rice/cadence/IC618/bin/strmin \
  -library RFME \
  -strmFile /rdf/VLSI/Projects/Naveed/RFME/apr/div23511/div23511.gds \
  -runDir /rdf/VLSI/Projects/Naveed/RFME/apr/div23511/oa_import \
  -logFile div23511_strmin_20260429_m1fix.log \
  -topCell div23511 \
  -view layout \
  -case Preserve \
  -layerMap /opt/vlsida/PDK_NEW/TSMC180_MS_RF_G/PDK/Cadence_OA/t018cmsp018k3_1_0a/pdk/tsmc18/tsmc18.layermap \
  -summaryFile div23511_strmin_20260429_m1fix.sum \
  -refLibList /rdf/VLSI/Projects/Naveed/RFME/apr/div23511/oa_import/reflib.list
```

Raw imported cells:

- `RFME/pfd/layout`
- `RFME/div23511/layout`

These are not yet the final matched project cells.

## 15. Build a fresh post-APR OA cell

For top-level assembly and later LVS, create a distinct RFME cell with:

- `schematic`
- `symbol`
- `layout`

Examples:

- `RFME/PFD3`
- `RFME/23511_POSTAPR5`

The general pattern is:

1. Rebuild the schematic from the latest `<module>.apr.pg.v`.
2. Regenerate or refresh the symbol from that schematic.
3. Copy the imported layout from the raw imported APR cell.
4. Rebuild signal pins and power pins in OA with the minimum necessary touch-up.
5. Save as a fresh cell name if old DRC or LVS windows are stale.

Do not keep mutating one old post-APR cell if LVS is already confused. The final clean `PFD` result came from a fresh-cell rebuild (`PFD3`), not from continued surgery on `PFD2`.

For the divider, the working helper pattern is captured in:

- [\_tmp_finalize_23511_postapr_layout.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_finalize_23511_postapr_layout.il)
- [\_tmp_build_23511_postapr5_20260429.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_build_23511_postapr5_20260429.il)
- [\_tmp_run_23511_postapr5_headless_20260429.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_run_23511_postapr5_headless_20260429.il)

For the final clean `PFD` rebuild, the working helper pattern is:

- [\_tmp_build_pfd3_postapr_20260429_0611.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_build_pfd3_postapr_20260429_0611.il)
- [\_tmp_finalize_pfd3_layout_dividerstyle_20260429.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_finalize_pfd3_layout_dividerstyle_20260429.il)

### Very important

Do not load a file with `exit()` directly through the live bridge. If a build script needs `exit()`, call it from a tiny headless wrapper file.

## 16. Headless Virtuoso rule

For heavy OA build steps, run headless Virtuoso separately and set the Cadence log path first.

This avoids failures like:

- `Failed to lock log file: /home/na73/CDS.log.9`

Working environment preamble:

```bash
mkdir -p "$HOME/.cache/cdslogs"
export CDS_LOG_PATH="$HOME/.cache/cdslogs"
export CDS_LOG_VERSION=pid
```

Then run headless Virtuoso:

```bash
/opt/rice/cadence/IC618/tools.lnx86/dfII/bin/virtuoso \
  -nograph \
  -restore /tmp/_tmp_run_23511_postapr5_headless_20260429.il \
  > /rdf/VLSI/Projects/Naveed/RFME/virtuoso/build_23511_postapr5_20260429.log 2>&1
```

## 17. DRC and LVS truth rules

This part matters.

Do not assume:

- a clean Innovus geometry report means signoff is done
- an old open RVE window automatically reflects new geometry
- an updated cell name means an old result DB is still attached correctly

When the DRC window appears inconsistent with the visible layout:

1. assume the result DB is stale
2. build a fresh post-APR cell with a new name
3. rerun DRC on that new cell

That is why the divider ended at `23511_POSTAPR5`, not by repeatedly mutating one old post-APR cell.

### 17.1 The final `PFD` LVS lesson

This is the important experience to preserve for future sessions.

The final `PFD` failure was not caused by:

- wrong RTL behavior
- wrong synth logic
- wrong APR logic mapping

The logic cells in source and layout actually matched.

The real mismatch was that the layout contained physical-only decap devices that the source schematic did not include:

- `1 x DCAP8BWP7T`
- `5 x DCAP4BWP7T`

That is why LVS initial counts looked bad even though the top-level pins and logic cells were correct.

When LVS shows a transistor-count mismatch like this:

1. compare source logic-cell masters against layout logic-cell masters
2. separate true logic mismatches from physical-only cells
3. inspect whether the layout includes decaps, taps, fillers, or custom via cells
4. mirror the physical-only cells in the source schematic only if the signoff deck is counting them

For `PFD`, the correct fix was:

- keep the clean 7-cell post-APR logic schematic
- add the extracted decap bank to the source schematic
- rebuild as a fresh cell (`PFD3`)

There was also a separate OA port-generation trap on `PFD`:

- imported signal ports could exist only as `METAL3 pin` shapes
- the real routed conductor under them was a separate `METAL3 drawing` path
- LVS then reported unattached labels or unattached ports even though the edge pin looked visually reasonable

The safe fix was:

- keep the edge `METAL3 pin` rectangle
- add a matching `METAL3 drawing` stub under that same pin box
- place the terminal label on that rebuilt pin location in the fresh cell

Do not assume every extra layout instance belongs in the source:

- fillers and taps are usually not the source-side answer
- custom via helper cells may appear in OA layout instance lists but are not necessarily the LVS source mismatch

The winning `PFD` source included:

- the 7 logic cells from `pfd.apr.pg.v`
- `1 x DCAP8BWP7T`
- `5 x DCAP4BWP7T`

That is the version that matched the final passing layout path.

### 17.2 Why divider passed faster

`23511_POSTAPR5` passed faster because its flow stayed much closer to the clean pattern:

- fresh post-APR cell names
- less in-place OA mutation
- no hidden missing physical-only bank in the source schematic

`PFD2` drifted into a bad state because it accumulated:

- repeated in-place layout restamps
- repeated label surgery
- stale result databases
- a source schematic that did not yet reflect the extracted decap content

If a future block starts feeling like `PFD2`, stop and rebuild the post-APR OA cell fresh instead of continuing to patch it in place.

## 18. What not to do

Do not do these again:

- do not start from ad hoc structural gate glue if real RTL is possible
- do not treat `ncverilog` as if it performs synthesis
- do not let APR explode the synthesized netlist with unnecessary logic churn
- do not trust old RVE markers after a cell has materially changed
- do not run long heavy Cadence jobs directly inside the live bridge if headless is available
- do not load a SKILL script with `exit()` into the live bridge session
- do not claim success from Innovus alone when the real question is Calibre signoff

## 19. Minimal checklist for future sessions

For a new RFME digital block, follow this exact checklist:

1. Write real RTL.
2. Verify function locally.
3. Push RTL to `/rdf/VLSI/Projects/Naveed/RFME/verilog/<module>`.
4. Clone or retarget synth files.
5. Set real timing constraints in `synth/<module>/<module>.tcl`.
6. Run `make syn`.
7. Build a simple APR deck under `apr/<module>`.
8. Keep APR close to the synthesized logic.
9. Fix only the actual recurring signoff issue if one appears.
10. Re-run APR.
11. Import GDS with `strmin`.
12. Build a fresh post-APR OA cell with rebuilt pins.
13. Rebuild the schematic from the latest `apr.pg.v`, not from an older intermediate post-APR cell.
14. If LVS counts look wrong, compare source logic cells vs layout logic cells and check for counted physical-only cells such as decaps.
15. Run DRC and LVS on that fresh cell.
16. If the DRC or LVS window looks stale, use a new cell name and rerun.

## 20. Final validated outputs from this flow

Clean-path outputs now in RFME:

- `RFME/PFD3`
- `RFME/23511_POSTAPR5`

Key APR source files:

- [apr/pfd/pfd.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/pfd/pfd.tcl)
- [apr/pfd/scripts/floorplan.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/pfd/scripts/floorplan.tcl)
- [apr/div23511/div23511.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/div23511/div23511.tcl)
- [apr/div23511/scripts/floorplan.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/div23511/scripts/floorplan.tcl)
- [apr/div23511/scripts/m1_drc_hotspots.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/apr/div23511/scripts/m1_drc_hotspots.tcl)

Key post-APR OA build files:

- [\_tmp_build_pfd3_postapr_20260429_0611.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_build_pfd3_postapr_20260429_0611.il)
- [\_tmp_finalize_pfd3_layout_dividerstyle_20260429.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_finalize_pfd3_layout_dividerstyle_20260429.il)
- [\_tmp_build_23511_postapr5_20260429.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_build_23511_postapr5_20260429.il)
- [\_tmp_finalize_23511_postapr_layout.il](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/_tmp_finalize_23511_postapr_layout.il)

Key synth source files:

- [synth/pfd/pfd.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/synth/pfd/pfd.tcl)
- [synth/div23511/div23511.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/synth/div23511/div23511.tcl)

Key RTL source files:

- [verilog/pfd/pfd.v](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/verilog/pfd/pfd.v)
- [verilog/div23511/div23511.v](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/verilog/div23511/div23511.v)

If a future session follows this README instead of the older partial shortcuts, it should land on the same clean result much faster.
