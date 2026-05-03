# RFME Server Verilog/Synth/Netlist Patch README

This note documents the practical RFME server flow we have been using:

- access the real RFME server tree
- create `verilog/` and `synth/` module folders
- push flat Verilog sources
- clone and retarget the synth template
- run synthesis
- patch synthesized netlists with explicit `vdd`/`vss` using `netlistwork.py`

## 1. Server access

The server alias used from this Windows workspace is:

- `opus-vb`

Basic connectivity checks:

```powershell
ssh opus-vb "hostname"
ssh opus-vb "pwd"
ssh opus-vb "ls /rdf/VLSI/Projects/Naveed/RFME"
```

Basic file transfer checks:

```powershell
scp "C:\Users\nav\Box\Student-Naveed\Paper\RFME\somefile.txt" "opus-vb:/tmp/somefile.txt"
ssh opus-vb "ls -l /tmp/somefile.txt"
```

## 2. Real RFME server paths

The actual RFME project tree on the server is:

- Verilog root: `/rdf/VLSI/Projects/Naveed/RFME/verilog`
- Synth root: `/rdf/VLSI/Projects/Naveed/RFME/synth`

For a module named `<module>`, the normal target paths are:

- Verilog source: `/rdf/VLSI/Projects/Naveed/RFME/verilog/<module>/<module>.v`
- Synth folder: `/rdf/VLSI/Projects/Naveed/RFME/synth/<module>/`

Example for `resistiveqamhrr`:

- `/rdf/VLSI/Projects/Naveed/RFME/verilog/resistiveqamhrr/resistiveqamhrr.v`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/resistiveqamhrr/Makefile`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/resistiveqamhrr/resistiveqamhrr.tcl`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/resistiveqamhrr/resistiveqamhrr.nl.v`

## 3. Local workspace layout

Keep matching local folders in this workspace:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\synth\<module>\`

That makes it easy to keep local and remote layouts aligned.

## 4. Create the local module folders

```powershell
$module = "resistiveqamhrr"
New-Item -ItemType Directory -Force "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\$module" | Out-Null
New-Item -ItemType Directory -Force "C:\Users\nav\Box\Student-Naveed\Paper\RFME\synth\$module" | Out-Null
```

Put the flat Verilog source at:

```text
C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\<module>\<module>.v
```

Mirror it into the local synth folder:

```powershell
Copy-Item `
  "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\$module\$module.v" `
  "C:\Users\nav\Box\Student-Naveed\Paper\RFME\synth\$module\$module.v" `
  -Force
```

## 5. Create the remote `verilog/` and `synth/` folders

```powershell
$module = "resistiveqamhrr"
ssh opus-vb "mkdir -p /rdf/VLSI/Projects/Naveed/RFME/verilog/$module"
ssh opus-vb "mkdir -p /rdf/VLSI/Projects/Naveed/RFME/synth/$module"
```

## 6. Push the Verilog source to the server

Use `scp` from Windows PowerShell:

```powershell
$module = "resistiveqamhrr"
scp "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\$module\$module.v" `
    "opus-vb:/rdf/VLSI/Projects/Naveed/RFME/verilog/$module/$module.v"

scp "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\$module\$module.v" `
    "opus-vb:/rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.v"
```

The second copy is optional if the synth TCL reads the Verilog directly from the `verilog/` tree, but keeping a mirrored copy in the synth folder is convenient.

## 7. Create the synth folder from the real template

The live RFME synth template currently is:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/blankexample`

It currently contains:

- `Makefile`
- `clocking.tcl`

Clone it on the server:

```powershell
$module = "resistiveqamhrr"
ssh opus-vb "cp -r /rdf/VLSI/Projects/Naveed/RFME/synth/blankexample /rdf/VLSI/Projects/Naveed/RFME/synth/$module"
```

Rename the template TCL to the module name:

```powershell
$module = "resistiveqamhrr"
ssh opus-vb "mv /rdf/VLSI/Projects/Naveed/RFME/synth/$module/clocking.tcl /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.tcl"
```

## 8. Edit the synth files

Update the remote `Makefile` so it uses the new top level:

```makefile
TOP_LEVEL=resistiveqamhrr
```

Update the remote TCL file so it uses the right top module and source path:

```tcl
set top_level "resistiveqamhrr"
read_verilog "../../verilog/resistiveqamhrr/resistiveqamhrr.v"
```

Set the clock name/port to match the design. For `resistiveqamhrr`, the input clock is:

```tcl
set clk_name "clk_if"
set clk_port "clk_if"
```

Example quick-edit commands:

```powershell
$module = "resistiveqamhrr"
ssh opus-vb "sed -i 's/^TOP_LEVEL=.*/TOP_LEVEL=$module/' /rdf/VLSI/Projects/Naveed/RFME/synth/$module/Makefile"
ssh opus-vb "sed -i 's/set top_level \".*\"/set top_level \"$module\"/' /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.tcl"
ssh opus-vb "sed -i 's#read_verilog \".*\"#read_verilog \"../../verilog/$module/$module.v\"#' /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.tcl"
ssh opus-vb "sed -i 's/set clk_name \".*\"/set clk_name \"clk_if\"/' /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.tcl"
ssh opus-vb "sed -i 's/set clk_port \".*\"/set clk_port \"clk_if\"/' /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.tcl"
```

## 9. Verify the pushed server files

Always hash-check the server file against the local source:

```powershell
$module = "resistiveqamhrr"
$local = (Get-FileHash "C:\Users\nav\Box\Student-Naveed\Paper\RFME\verilog\$module\$module.v" -Algorithm SHA256).Hash.ToLower()
$remote = ssh opus-vb "sha256sum /rdf/VLSI/Projects/Naveed/RFME/verilog/$module/$module.v"
Write-Output "LOCAL=$local"
Write-Output "REMOTE=$remote"
```

Quick content checks:

```powershell
$module = "resistiveqamhrr"
ssh opus-vb "sed -n '1,40p' /rdf/VLSI/Projects/Naveed/RFME/verilog/$module/$module.v"
ssh opus-vb "sed -n '1,80p' /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.tcl"
ssh opus-vb "sed -n '1,40p' /rdf/VLSI/Projects/Naveed/RFME/synth/$module/Makefile"
```

## 10. Run synthesis

From PowerShell:

```powershell
ssh opus-vb "cd /rdf/VLSI/Projects/Naveed/RFME/synth/resistiveqamhrr && make syn"
```

Or from a remote shell / Virtuoso terminal:

```bash
cd /rdf/VLSI/Projects/Naveed/RFME/synth/resistiveqamhrr
make syn
```

Expected output artifacts in the synth folder include:

- `<module>.log`
- `<module>.dc.rpt`
- `<module>.dc.sdf`
- `<module>.sdc`
- `<module>.nl.v`

## 11. Patch synthesized netlists with `vdd` and `vss`

The local patch script is:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\netlistwork.py`

It now accepts explicit input and output file paths, so it can be used on any synthesized netlist.

Power-pin behavior:

- adds `vdd, vss` to user module headers
- adds `input vdd, vss;` declarations
- adds `.VDD(vdd), .VSS(vss)` to std-cell instances
- preserves a clean hierarchical patch for synthesized helper modules too

### Local patch usage

```powershell
& "C:\Users\nav\AppData\Local\Programs\Python\Python312\python.exe" `
  "C:\Users\nav\Box\Student-Naveed\Paper\RFME\netlistwork.py" `
  "C:\Users\nav\Box\Student-Naveed\Paper\RFME\input.nl.v" `
  "C:\Users\nav\Box\Student-Naveed\Paper\RFME\output_vddvss.nl.v"
```

### Full server patch flow

Example for a synthesized module:

```powershell
$module = "resistiveqamhrr"

scp "opus-vb:/rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.nl.v" `
    "C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_$module.nl.v"

& "C:\Users\nav\AppData\Local\Programs\Python\Python312\python.exe" `
  "C:\Users\nav\Box\Student-Naveed\Paper\RFME\netlistwork.py" `
  "C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_$module.nl.v" `
  "C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_${module}_vddvss.nl.v"

ssh opus-vb "cp /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.nl.v /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.nl.v.pre_vddvss.bak"

scp "C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_${module}_vddvss.nl.v" `
    "opus-vb:/rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.nl.v"
```

### Verify the patched netlist

```powershell
$module = "resistiveqamhrr"
$local = (Get-FileHash "C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_${module}_vddvss.nl.v" -Algorithm SHA256).Hash.ToLower()
$remote = ssh opus-vb "sha256sum /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.nl.v"
Write-Output "LOCAL=$local"
Write-Output "REMOTE=$remote"

ssh opus-vb "sed -n '1,24p' /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.nl.v"
ssh opus-vb "ls -l /rdf/VLSI/Projects/Naveed/RFME/synth/$module/$module.nl.v.pre_vddvss.bak"
```

### Modules already patched this way

We have already used this flow successfully on:

- `resistiveqamhrr`
- `imagecancelcontrol`

## 12. Common mistakes to avoid

- Do not use a fake path like `~/projects/naveed/rfme`; the real tree is under `/rdf/VLSI/Projects/Naveed/RFME`.
- Do not assume the synth template TCL is named after the folder; the live `blankexample` currently contains `clocking.tcl`.
- Do not skip the SHA-256 check after `scp`.
- Do not overwrite the synthesized `.nl.v` without first making a `.pre_vddvss.bak`.
- If synthesis looks wrong, verify the TCL `read_verilog` path and the clock port settings first.

## 13. Recommended minimum flow

For a new module `<module>`:

1. Create local `verilog/<module>/` and `synth/<module>/`
2. Put the flat Verilog at `verilog/<module>/<module>.v`
3. Mirror it to local `synth/<module>/<module>.v`
4. `mkdir -p` the real remote `verilog/` and `synth/` folders
5. `scp` the Verilog file to the server
6. Copy remote `synth/blankexample` to `synth/<module>`
7. Rename `clocking.tcl` to `<module>.tcl`
8. Update `Makefile` and `<module>.tcl`
9. Hash-check the server copy
10. Run `make syn`
11. Pull `<module>.nl.v`, run `netlistwork.py`, back up the original netlist, and push the patched netlist back
