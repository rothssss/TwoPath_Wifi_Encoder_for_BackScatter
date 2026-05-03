# RFME Current Synth And APR Findings

Last updated: **May 2, 2026**

This is the short current-state summary for the RFME digital flow findings.

Scope:

- `pfd`
- `div23511`

This file is intentionally about the **current findings**, not the ideal flow.  
For the longer procedural flow, see:

- [RFME_GOLDEN_RTL_SYNTH_APR_VIRTUOSO_FLOW_README.md](C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_GOLDEN_RTL_SYNTH_APR_VIRTUOSO_FLOW_README.md)

## 1. Current source roots

Server roots:

- Verilog: `/rdf/VLSI/Projects/Naveed/RFME/verilog`
- Synth: `/rdf/VLSI/Projects/Naveed/RFME/synth`
- APR: `/rdf/VLSI/Projects/Naveed/RFME/apr`
- Virtuoso OA: `/rdf/VLSI/Projects/Naveed/RFME/virtuoso/RFME`

## 2. Current final OA cells

Current post-APR OA cells in use:

- `RFME/PFD3`
- `RFME/23511_POSTAPR6`

Important distinction:

- `23511_POSTAPR6` is the current divider post-APR OA target
- `PFD3` is the current PFD OA target
- but `PFD3` has an important source-of-truth caveat described below

## 3. Synthesis findings

### 3.1 `pfd`

Current synth files:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/pfd/pfd.tcl` — `2026-04-30 14:00`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/pfd/pfd.nl.v` — `2026-04-30 14:01`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/pfd/pfd.dc.rpt` — `2026-04-30 14:01`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/pfd/pfd.dc.sdf` — `2026-04-30 14:01`

Current synth constraints:

- `INPUT` clock period: `3.333 ns`
- `REF` clock period: `3.333 ns`
- clock uncertainty: `0.067 ns`
- clock transition: `0.067 ns`

Current synth netlist content:

- `u_clear_inv`
- `u_clear_buf0`
- `down_latched_reg`
- `up_latched_reg`
- `U4`
- `U5`

Current synth report findings:

- cells: `6`
- combinational cells: `4`
- sequential cells: `2`
- buf/inv count: `2`
- total cell area: `138.297600`

Interpretation:

- the **current synth result for `pfd` is the shortened one-buffer reset-chain version**
- that synthesized source contains only one `BUFFD3BWP7T`

### 3.2 `div23511`

Current synth files:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/div23511/div23511.tcl` — `2026-04-29 01:44`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/div23511/div23511.nl.v` — `2026-04-29 01:44`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/div23511/div23511.dc.rpt` — `2026-04-29 01:44`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/div23511/div23511.dc.sdf` — `2026-04-29 01:44`

Current synth constraints:

- `CLKIN` clock period: `3.333 ns`
- clock uncertainty: `0.267 ns`
- clock transition: `0.267 ns`

Current synth report findings:

- ports: `5`
- nets: `70`
- cells: `64`
- combinational cells: `54`
- sequential cells: `10`
- buf/inv count: `16`
- total cell area: `1044.915197`

Interpretation:

- the divider synthesis state is internally coherent
- this is the real RTL-derived `300 MHz` synth result currently feeding APR

## 4. APR findings

### 4.1 `pfd`

Current APR files:

- `/rdf/VLSI/Projects/Naveed/RFME/apr/pfd/pfd.gds` — `2026-04-30 14:02`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/pfd/pfd.apr.pg.v` — `2026-04-30 14:02`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/pfd/pfd.apr.v` — `2026-04-30 14:02`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/pfd/pfd.def` — `2026-04-30 14:02`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/pfd/pfd.apr.sdf` — `2026-04-30 14:02`

Current APR report findings:

- geometry: `No DRC violations were found`
- connectivity: `Found no problems or warnings`
- antenna: clean report present
- density: `0.543`
- pin density: `0.1641`

Current APR timing findings:

- post-route setup summary:
  - `WNS = 2.689 ns`
  - `TNS = 0.000 ns`
- post-route hold summary:
  - `WNS = 0.093 ns`
  - `TNS = 0.000 ns`

Current APR text-artifact interpretation:

- `pfd.apr.v`, `pfd.apr.pg.v`, and `pfd.def` all describe the **shortened** reset chain
- that textual APR view contains:
  - `u_clear_inv`
  - `u_clear_buf0`
- it does **not** contain `u_clear_buf1`

### 4.2 `div23511`

Current APR files:

- `/rdf/VLSI/Projects/Naveed/RFME/apr/div23511/div23511.gds` — `2026-04-29 05:20`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/div23511/div23511.apr.pg.v` — `2026-04-29 05:20`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/div23511/div23511.apr.v` — `2026-04-29 05:20`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/div23511/div23511.def` — `2026-04-29 05:20`
- `/rdf/VLSI/Projects/Naveed/RFME/apr/div23511/div23511.apr.sdf` — `2026-04-29 05:20`

Current APR report findings:

- geometry: `No DRC violations were found`
- connectivity: `Found no problems or warnings`
- antenna: clean report present
- density: `0.596`
- pin density: `0.2336`

Current APR timing findings:

- post-route setup summary:
  - `WNS = 0.014 ns`
  - `TNS = 0.000 ns`
- post-route hold summary:
  - `WNS = -0.055 ns`
  - `TNS = -0.110 ns`

Interpretation:

- the current divider APR database is physically clean in Innovus geometry/connectivity/antenna
- but the current stored post-route hold summary is **not** clean
- so the current divider APR state should be treated as:
  - DRC/connectivity-clean
  - timing-near-closure on setup
  - small remaining hold issue in the saved summary files

## 5. Virtuoso findings

### 5.1 `PFD3`

Current OA timestamps:

- `RFME/PFD3/layout` — `2026-04-30 14:08`
- `RFME/PFD3/schematic` — updated after later repair work in-session
- `RFME/PFD3/symbol` — current with the rebuilt schematic

Important current finding:

- the **current imported `PFD3` layout extracts as a two-buffer reset-chain layout**
- specifically, `RFME/pfd/layout` and `RFME/PFD3/layout` currently count:
  - `BUFFD3BWP7T = 2`
- this does **not** match the April 30 synth/APR textual artifacts, which count:
  - `BUFFD3BWP7T = 1`

This is the main current `pfd` inconsistency.

To keep the OA source and layout aligned for LVS work, `PFD3/schematic` was rebuilt to match the **layout-extracted** cell mix:

- `u_clear_inv`
- `u_clear_buf0`
- `u_clear_buf1`
- `down_latched_reg`
- `up_latched_reg`
- `U4`
- `U5`
- `1 x DCAP8BWP7T`
- `5 x DCAP4BWP7T`

So the current status is:

- **APR text artifacts** say one-buffer chain
- **imported OA layout** extracts as two-buffer chain
- **current `PFD3` OA schematic** was realigned to the two-buffer layout for LVS consistency

Bottom line:

- `PFD3` is the current usable OA post-APR PFD cell
- but the `pfd` flow currently has a split source of truth between:
  - textual synth/APR outputs
  - imported OA physical result

### 5.2 `23511_POSTAPR6`

Current OA timestamps:

- `RFME/23511_POSTAPR6/layout` — `2026-04-29 10:05`
- `RFME/23511_POSTAPR6/schematic` — `2026-04-29 13:30`
- `RFME/23511_POSTAPR6/symbol` — `2026-04-29 10:05`

Current divider OA finding:

- the divider OA flow is much more coherent than the PFD flow
- the source schematic was patched to include counted physical-only decaps for LVS:
  - `13 x DCAP8BWP7T`
  - `20 x DCAP4BWP7T`

Bottom line:

- `23511_POSTAPR6` is the current final OA divider cell
- the main caveat on the divider is the saved APR hold summary, not OA source/layout identity

## 6. Current conclusions

### 6.1 Strongest current block

`div23511` is the cleaner overall flow from a source-of-truth perspective:

- synth is coherent
- APR reports are coherent
- OA post-APR cell naming is settled
- main remaining finding is a small stored hold violation in APR timing summaries

### 6.2 Most important current PFD caveat

`pfd` currently has the most important unresolved flow inconsistency:

- synth/APR text outputs say the reset chain is shortened to one buffer
- imported OA layout still extracts as a two-buffer chain

So if a future session wants one clean single source of truth for `pfd`, the right next task is:

1. regenerate or re-import the `pfd` physical result until GDS/layout extraction agrees with `pfd.apr.pg.v`
2. then rebuild `PFD3` again from that converged source

## 7. Recommended current usage

Use these cells today:

- `RFME/PFD3`
- `RFME/23511_POSTAPR6`

But keep these caveats in mind:

- for `PFD3`, trust the **current OA cell contents** more than the April 30 textual APR netlist
- for `23511_POSTAPR6`, trust the OA cell and physical cleanliness, but remember the current APR timing summaries still show a small hold issue

