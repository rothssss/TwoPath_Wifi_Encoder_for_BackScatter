# RFME End-To-End Synth/APR/Virtuoso Flow

Last validated: 2026-04-26

Validated examples:
- `notch_width_decoder_1024`
- `pfd`
- `div23511`

This is the practical RFME digital-block flow from local source to server to APR to Virtuoso layout import.

It covers:
- staging Verilog and flow files from this Windows workspace
- regenerating synthesis on the real RFME server
- running Innovus APR
- importing the finished GDS back into the `RFME` Virtuoso library
- making the imported layout usable for top-level assembly and LVS

Use this as the main handoff README for digital standard-cell blocks.

## 1. Source of truth

Local workspace root:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME`

Real server roots:

- Verilog: `/rdf/VLSI/Projects/Naveed/RFME/verilog`
- Synth: `/rdf/VLSI/Projects/Naveed/RFME/synth`
- APR: `/rdf/VLSI/Projects/Naveed/RFME/apr`
- Virtuoso library area: `/rdf/VLSI/Projects/Naveed/RFME/virtuoso`

Do not invent alternate project roots.

## 2. Two supported entry points

There are two clean ways into APR:

### A. RTL -> DC synth -> APR

Use this for normal behavioral RTL.

Expected local source:

- `verilog/<module>/<module>.v`

Expected APR input:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/<module>/<module>.nl.v`
- or, if power-pin patching was done later:
- `/rdf/VLSI/Projects/Naveed/RFME/synth/<module>/<module>.nl.v.pre_vddvss.bak`

### B. Structural std-cell Verilog -> ncverilog -> APR

Use this for blocks that are already written as YAN standard-cell instances and should preserve exact cell choices.

Typical local collateral:

- `verilog/<module>/<module>.v`
- `verilog/<module>/<module>_nc_tb.v`
- `verilog/<module>/<module>_nc.f`

This was the pattern used for:

- `pfd`
- `div23511`

In this path, `ncverilog` is the functional gate-level check, and APR consumes the same structural netlist or a copied `synth/<module>/<module>.nl.v`.

## 3. Direct bridge rule

For live Virtuoso work, use the direct bridge fallback, not the SSH tunnel flow.

Source-of-truth note:

- [RFME_VIRTUOSO_BRIDGE_DIRECT_FALLBACK_README.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_VIRTUOSO_BRIDGE_DIRECT_FALLBACK_README.md)

Direct public port map:

| Display | Session | Port |
|---|---|---:|
| `:96` | default | `5950` |
| `:95` | `V95` | `5951` |
| `:23` | `V23` | `5952` |
| `:21` | `V21` | `5953` |

Healthy check:

```powershell
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe `
  C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py `
  --host opus.ece.rice.edu --port 5951 "1+2"
```

Expected output:

- `3`

Important:

- keep the VNC/Virtuoso session open
- use `RBStop()`, not `RBStopAll()`
- keep one unique `59xx` port per session

## 4. Local mirror convention

Keep a local mirror before pushing to the server:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\<module>.v`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\synth\<module>\`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\apr\<module>\`

Strict naming rule:

- folder name = module name
- source filename = `<module>.v`
- top module name = `<module>`

If the final OA cell should be distinct from the original schematic cell, use a distinct post-APR name such as:

- `PFD2`
- `23511_POSTAPR`

## 5. Push the design to the server

When SSH is healthy, use `scp` and `ssh` for file staging.

Example:

```powershell
$module = "myblock"

ssh opus-vb "mkdir -p /rdf/VLSI/Projects/Naveed/RFME/verilog/$module"
ssh opus-vb "mkdir -p /rdf/VLSI/Projects/Naveed/RFME/synth/$module"
ssh opus-vb "mkdir -p /rdf/VLSI/Projects/Naveed/RFME/apr/$module"

scp "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\$module\$module.v" `
    "opus-vb:/rdf/VLSI/Projects/Naveed/RFME/verilog/$module/$module.v"
```

Recommended verification:

```powershell
ssh opus-vb "sed -n '1,40p' /rdf/VLSI/Projects/Naveed/RFME/verilog/$module/$module.v"
```

## 6. Synthesis setup

The live synth template is:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/blankexample`

Create a new synth folder by cloning it:

```powershell
$module = "myblock"
ssh opus-vb "cp -r /rdf/VLSI/Projects/Naveed/RFME/synth/blankexample /rdf/VLSI/Projects/Naveed/RFME/synth/$module"
ssh opus-vb "cd /rdf/VLSI/Projects/Naveed/RFME/synth/$module && if [ -f clocking.tcl ]; then mv clocking.tcl $module.tcl; fi"
```

Retarget the synth folder so it points at:

- `TOP_LEVEL=<module>`
- `read_verilog "../../verilog/<module>/<module>.v"`

At minimum verify:

- `Makefile`
- `<module>.tcl`
- clock name
- clock port

Run synthesis:

```powershell
ssh opus-vb "cd /rdf/VLSI/Projects/Naveed/RFME/synth/$module && make syn"
```

Expected outputs:

- `<module>.nl.v`
- `<module>.dc.rpt`
- `<module>.dc.sdf`
- `<module>.sdc`

## 7. Clean APR netlist rule

APR should consume a clean netlist without top-level `vdd` and `vss`.

If the main `.nl.v` was later patched for schematic/layout integration, prefer:

- `<module>.nl.v.pre_vddvss.bak`

That backup is the clean APR input.

Short rule:

- clean synth netlist in
- power-aware APR netlist out

## 8. Optional ncverilog step

For structural standard-cell blocks, run `ncverilog` before APR.

Typical filelist contents:

- standard-cell Verilog models
- `<module>.v`
- `<module>_nc_tb.v`

This is the right place to validate:

- divide ratios for a divider
- PFD pulse behavior
- mux/bypass/control behavior

For these RFME blocks, `ncverilog` was used as the functional check for:

- `pfd`
- `div23511`

## 9. APR folder structure

Use this structure:

```text
apr/<module>/
  Makefile
  <module>.tcl
  power.tcl
  sroute.tcl
  scripts/
    init.tcl
    floorplan.tcl
    viewDefinition.tcl
```

Important `init.tcl` pattern:

```tcl
set init_netlist "${syn_dir}/${my_toplevel}.nl.v"
set init_netlist_prepg "${syn_dir}/${my_toplevel}.nl.v.pre_vddvss.bak"
if {[file exists $init_netlist_prepg]} {
    set init_verilog $init_netlist_prepg
} else {
    set init_verilog $init_netlist
}
```

## 10. Constraint and floorplan guidance

Set the intended clock target in both synth and APR constraints.

Examples:

- `100 MHz` -> `10.000 ns`
- `160 MHz` -> `6.250 ns`
- `300 MHz` -> `3.333 ns`

Scale uncertainty with the target instead of leaving stale values behind.

Important divider nuance:

- static config pins such as `DIVSEL0`, `DIVSEL1`, and `BYPASS` should usually be false-pathed
- derived clock outputs should not be constrained like ordinary synchronous data outputs

Important Innovus cleanup:

- do not apply `set_max_transition` or `set_max_fanout` blindly to `[get_pins *]`

That generates noisy nonfatal errors on illegal pin objects.

For pin placement, the most robust recent pattern was:

- inputs on one edge
- outputs on the opposite edge
- use side spreading instead of center clustering

Example pattern in `floorplan.tcl`:

```tcl
editPin -pin [list ...] -spreadType SIDE -edge 3 -layer M3
editPin -pin [list ...] -spreadType SIDE -edge 1 -layer M3
```

That is what was used to re-space the `pfd` and `div23511` edge pins evenly.

## 11. APR launch

When the live environment matters, use the absolute Innovus binary:

- `/opt/rice/cadence/DDIEXPORT22/INNOVUS221/tools.lnx86/bin/innovus`

Example:

```bash
cd /rdf/VLSI/Projects/Naveed/RFME/apr/<module>
/opt/rice/cadence/DDIEXPORT22/INNOVUS221/tools.lnx86/bin/innovus -64 -init <module>.tcl
```

Expected useful outputs:

- `<module>.def`
- `<module>.lef`
- `<module>.gds`
- `<module>.apr.v`
- `<module>.apr.pg.v`
- `<module>.spef`
- `<module>.apr.sdf`
- `<module>.util.rpt`
- `timingReports/`
- `routed.enc`

Expected useful checks:

- `<module>.conn.rpt`
- `<module>.geom.rpt`
- `<module>.antenna.rpt`

## 12. Import the GDS back into Virtuoso

The clean pattern is:

1. Stream the APR GDS into the `RFME` library as a temporary/import cell.
2. Rebind imported standard-cell instances to `tcb018gbwp7t_YAN/layout`.
3. Copy that imported layout into the intended final OA cell.
4. Recreate top-level OA nets, terms, and pins.
5. Save the cell and reopen the layout window if it was already open.

Create a ref-lib list on the server:

- `/rdf/VLSI/Projects/Naveed/RFME/virtuoso/rfme_apr_reflib.list`

Contents:

```text
tcb018gbwp7t_YAN
```

Example `strm2oa` import:

```bash
/opt/rice/cadence/IC618/tools/bin/strm2oa \
  -lib RFME \
  -gds /rdf/VLSI/Projects/Naveed/RFME/apr/<module>/<module>.gds \
  -libDefFile /rdf/VLSI/Projects/Naveed/RFME/virtuoso/cds.lib \
  -refLibList /rdf/VLSI/Projects/Naveed/RFME/virtuoso/rfme_apr_reflib.list \
  -view layout \
  -overwrite \
  -layerMap /opt/vlsida/PDK_NEW/TSMC180_MS_RF_G/PDK/Cadence_OA/t018cmsp018k3_1_0a/pdk/tsmc18/tsmc18.layermap
```

Important import nuance:

- the GDS import may preserve signal labels on `METAL3/drawing` instead of creating proper `METAL3/pin` figures
- the imported top cell can look visually correct but still be unusable until OA terms and pins are recreated

So after `strm2oa`, do not stop at "the layout opened."

You still need to:

- resolve any imported unresolved masters
- create OA pins from the imported signal rectangles
- create OA power pins on the rings
- create matching OA terms/nets

## 13. Post-import finalization pattern

The recent working pattern was:

- import into lowercase temporary cells such as `RFME/pfd` or `RFME/div23511`
- copy that layout into the final matched cell such as `RFME/PFD2` or `RFME/23511_POSTAPR`
- rebuild the top-level layout pins and terms with small SKILL helpers

For `PFD2`, the final usable top-level terms are:

- `INPUT`
- `REF`
- `UP`
- `DOWN`
- `VDD`
- `VSS`

For `23511_POSTAPR`, the final usable top-level terms are:

- `CLKIN`
- `DIVSEL0`
- `DIVSEL1`
- `BYPASS`
- `DIV23511OUT`
- `VDD`
- `VSS`

Reopen the cell view after refresh if the layout was already open in Virtuoso.

## 14. Recommended short workflow

For a new block `<module>`:

1. Create or update local source in `verilog/<module>/<module>.v`.
2. If the block is already structural standard-cell logic, also create an `ncverilog` testbench and filelist.
3. Push the source to `/rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v`.
4. Clone `synth/blankexample` to `synth/<module>` and retarget it.
5. Run `make syn` if the block is going through DC.
6. Use the clean `.nl.v` or `.nl.v.pre_vddvss.bak` as APR input.
7. Create or retarget `apr/<module>/`.
8. Run Innovus and check timing, connectivity, DRC, antenna, and utilization.
9. Import `<module>.gds` into the `RFME` Virtuoso library with `strm2oa`.
10. Rebind std-cell layout masters and recreate top-level OA pins/terms.
11. Copy the imported layout into the final post-APR OA cell if it should stay distinct from the original schematic cell.

## 15. Known pitfalls

- Do not use fake server paths; always use `/rdf/VLSI/Projects/Naveed/RFME/...`.
- Do not assume the synth template TCL is already named after the module; it may still be `clocking.tcl`.
- Do not feed APR a power-patched `.nl.v` when a clean `.pre_vddvss.bak` exists.
- Do not trust a GDS import just because the cell opens visually; check OA terminals and unresolved masters.
- Do not leave stale frequency constraints in place when retargeting a block.
- Do not constrain static control pins like synchronous data paths.
- Do not use `RBStopAll()` unless you really mean to kill every live bridge session.

## 16. Use this README with

- [RFME_VIRTUOSO_VERILOG_SYNTH_DEPLOY_README.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_VIRTUOSO_VERILOG_SYNTH_DEPLOY_README.md)
- [RFME_DIRECT_BRIDGE_SYNTH_APR_FLOW_README.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_DIRECT_BRIDGE_SYNTH_APR_FLOW_README.md)
- [RFME_VIRTUOSO_BRIDGE_DIRECT_FALLBACK_README.md](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/RFME_VIRTUOSO_BRIDGE_DIRECT_FALLBACK_README.md)

If those three older notes disagree with this file, prefer this file for the current end-to-end operational flow.
