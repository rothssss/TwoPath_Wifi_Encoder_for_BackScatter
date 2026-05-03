# RFME Direct-Bridge Synthesis + APR Flow

Last validated: 2026-04-24

Validated example:
- `notch_width_decoder_1024`

This README distills the most reliable recent flow for:

- regenerating a clean synthesized netlist with no top-level `vdd` or `vss`
- running Innovus APR on that clean netlist
- using the direct public bridge port instead of relying on SSH tunnel forwarding

The source of truth for the bridge method is:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\RFME_VIRTUOSO_BRIDGE_DIRECT_FALLBACK_README.md`

## 1. Reliability rules

Use these rules every time:

- keep the target Virtuoso/VNC session open on `opus.ece.rice.edu`
- load the RAMIC bridge in that live CIW and bind it to a unique public `59xx` port
- do not use `RBStopAll()` unless you want to kill every bridge session
- use direct host/port bridge mode because SSH forwarding was the flaky part
- after any restamp or netlist/layout update, rerun checks or sims instead of trusting stale results

Healthy direct bridge check:

```powershell
C:\Users\nav\Documents\virtuoso-bridge-lite\.venv\Scripts\python.exe `
  C:\Users\nav\Box\Student-Naveed\Paper\RFME\rfme_virtuoso_bridge_exec.py `
  --host opus.ece.rice.edu --port <direct_port> "1+2"
```

Expected output:

- `3`

## 2. Bridge port map

Use one unique public port per session:

| Display | Profile | Direct bridge port |
|---|---|---:|
| `:96` | default | `5950` |
| `:95` | `V95` | `5951` |
| `:23` | `V23` | `5952` |
| `:21` | `V21` | `5953` |

For `:95`, the CIW bring-up is:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73_V95/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5951
RBStart()
```

For `:96`, the CIW bring-up is:

```skill
load("/home/na73/.cache/virtuoso_bridge_na73/virtuoso_bridge/virtuoso_setup.il")
RBStop()
RBLocal=nil
RBPort=5950
RBStart()
```

## 3. Real RFME paths

Remote server roots:

- Verilog root: `/rdf/VLSI/Projects/Naveed/RFME/verilog`
- Synth root: `/rdf/VLSI/Projects/Naveed/RFME/synth`
- APR root: `/rdf/VLSI/Projects/Naveed/RFME/apr`

Recommended local mirror roots:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\synth`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\apr`

One-to-one naming rule:

- folder name = top module name
- RTL filename = `<module>.v`
- synth folder = `<module>`
- APR folder = `<module>`

## 4. Regenerate a clean synthesized netlist

APR should consume a clean synthesized netlist with no top-level `vdd` or `vss`.

The clean source RTL should live at:

- local: `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\<module>.v`
- remote: `/rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v`

The synth folder should live at:

- remote: `/rdf/VLSI/Projects/Naveed/RFME/synth/<module>`

### Recommended synthesis regeneration flow

1. Confirm the RTL file is the plain logic version with no top-level power pins.
2. Push or verify the server RTL at:
   - `/rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v`
3. Confirm the synth folder exists and is retargeted to:
   - top level `<module>`
   - `read_verilog "../../verilog/<module>/<module>.v"`
4. Run synthesis:

```bash
cd /rdf/VLSI/Projects/Naveed/RFME/synth/<module>
make syn
```

Expected clean synthesis outputs:

- `<module>.nl.v`
- `<module>.sdc`
- `<module>.dc.rpt`
- `<module>.dc.sdf`

### Important note about patched netlists

In this project, some synthesized netlists were later patched with explicit `vdd` and `vss` for other downstream uses.

If the current synth output was patched already, look for:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/<module>/<module>.nl.v.pre_vddvss.bak`

That backup is the clean pre-patch APR input and is preferred over the patched `.nl.v`.

For `notch_width_decoder_1024`, the clean APR input was:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/notch_width_decoder_1024/notch_width_decoder_1024.nl.v.pre_vddvss.bak`

## 5. APR deck structure

Use this folder structure:

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

The working local example created in this workspace is:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\apr\notch_width_decoder_1024`

The server copy is:

- `/rdf/VLSI/Projects/Naveed/RFME/apr/notch_width_decoder_1024`

### APR input rule

`scripts/init.tcl` should prefer the clean pre-patch netlist when it exists:

```tcl
set init_netlist "${syn_dir}/${my_toplevel}.nl.v"
set init_netlist_prepg "${syn_dir}/${my_toplevel}.nl.v.pre_vddvss.bak"
if {[file exists $init_netlist_prepg]} {
    set init_verilog $init_netlist_prepg
} else {
    set init_verilog $init_netlist
}
```

### Safe starter floorplan

For a first pass with no hard area target:

- inputs on left
- outputs on right
- `aspect_ratio = 1.0`
- `density = 0.6`

That worked reasonably for `notch_width_decoder_1024`.

## 6. Important APR deck cleanup

One issue found in the first APR pass:

- `set_max_transition 5 [get_pins *]`
- `set_max_fanout 6 [get_pins *]`

These generate many nonfatal Innovus errors because they hit hierarchical pins and input pins.

Typical errors:

- `TCLCMD-419`: cannot apply `set_max_transition` on hierarchical pins
- `TCLCMD-1171`: `set_max_fanout` not allowed on input pins

Recommendation:

- do not apply these constraints to `[get_pins *]`
- constrain legal top-level ports, clocks, or selected objects only

The first pass still completed and produced valid outputs, but the deck should be cleaned up before future reruns.

## 7. Launch APR through the direct bridge

The reliable method is:

1. Keep the live `:95` or `:96` VNC session open.
2. In that CIW, start RAMIC on the direct public port.
3. Verify the direct bridge returns `3`.
4. Launch Innovus from the direct bridge session environment.

### Why this is more reliable

Plain non-interactive SSH shells did not always have `innovus` on `PATH`.

The live direct bridge session did have the right environment, including:

- `/opt/rice/cadence/DDIEXPORT22/INNOVUS221/tools.lnx86/bin`

### Reliable Innovus binary

Use the absolute binary path:

- `/opt/rice/cadence/DDIEXPORT22/INNOVUS221/tools.lnx86/bin/innovus`

### Example launch pattern through direct `:95`

Launch from:

- `/rdf/VLSI/Projects/Naveed/RFME/apr/<module>`

Example command that was used for the validated run:

```bash
/opt/rice/cadence/DDIEXPORT22/INNOVUS221/tools.lnx86/bin/innovus -64 -init <module>.tcl
```

When launching in the background, useful files are:

- `apr_direct95.log`
- `apr_direct95.pid`

## 8. APR output checklist

After a successful run, expect:

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

High-value verification reports:

- `<module>.conn.rpt`
- `<module>.geom.rpt`
- `<module>.antenna.rpt`

Quick meanings:

- `conn.rpt`: connectivity check
- `geom.rpt`: DRC geometry check
- `antenna.rpt`: antenna check
- `util.rpt`: utilization and density

## 9. Validated APR result: notch_width_decoder_1024

Validated on:

- 2026-04-24

APR folder:

- `/rdf/VLSI/Projects/Naveed/RFME/apr/notch_width_decoder_1024`

Generated outputs observed:

- `notch_width_decoder_1024.def`
- `notch_width_decoder_1024.lef`
- `notch_width_decoder_1024.gds`
- `notch_width_decoder_1024.apr.pg.v`
- `notch_width_decoder_1024.spef`
- `notch_width_decoder_1024.apr.sdf`
- `notch_width_decoder_1024.util.rpt`
- `timingReports/`

Verification results:

- `notch_width_decoder_1024.conn.rpt`: found no problems or warnings
- `notch_width_decoder_1024.geom.rpt`: no DRC violations
- `notch_width_decoder_1024.antenna.rpt`: no violations found

Utilization:

- Core utilization: `63.211951`
- Design density: about `0.619`

Important nuance:

- `innovus.log` showed a large final message count, but the observed errors were dominated by the nonfatal bad-constraint pattern described above
- the physical outputs and verification reports were still clean and usable

## 10. Power-pin behavior across the flow

Keep the distinction clear:

- synthesis regeneration for APR input should be clean and have no top-level `vdd` or `vss`
- APR input should use the clean `.nl.v` or `.nl.v.pre_vddvss.bak`
- Innovus export of `<module>.apr.pg.v` is expected to include power and ground connectivity

So:

- clean synth netlist in
- power-aware APR netlist out

## 11. Recommended short workflow

For a new block `<module>`:

1. Write or verify clean RTL in `verilog/<module>/<module>.v`
2. Push it to `/rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v`
3. Regenerate synthesis with `make syn`
4. Use the clean `.nl.v` or `.nl.v.pre_vddvss.bak` as APR input
5. Create `apr/<module>/` deck files
6. Bring up the correct live direct bridge session, usually `:95` or `:96`
7. Verify the bridge with `1+2 -> 3`
8. Launch Innovus from the live direct bridge environment
9. Check `.def`, `.lef`, `.gds`, `.apr.pg.v`, `.spef`, `.apr.sdf`
10. Read `conn.rpt`, `geom.rpt`, `antenna.rpt`, and `util.rpt`
11. Clean up deck constraints before the next rerun if Innovus logged nonfatal constraint errors

