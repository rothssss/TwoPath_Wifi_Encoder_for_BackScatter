# RFME SPI_TX Import Note

Last validated: 2026-04-27

Imported source block:

- Yiwei WPDT project: `/rdf/VLSI/Projects/Yiwei_WPDT/verilog/SPI_TX/SPI_TX.v`

Why this block was chosen:

- it is the only clear SPI RTL block in the Yiwei WPDT Verilog tree
- it already exists in Yiwei's `verilog/`, `syn/`, and `apr/` flows
- that makes it a stronger reuse candidate than a filename-only match

## 1. What the block is

`SPI_TX` is a small SPI slave register interface.

Interface summary:

- SPI inputs: `SCLK`, `CS`, `MOSI`
- SPI output: `MISO`
- write-side output bus: `DW_REG`
- read-side input bus: `UP_REG`
- async reset: `rst_n`

Behavior summary:

- the SPI address is shifted in on `MOSI`
- writes land in the internal write register bank and are exposed on `DW_REG`
- reads come from `UP_REG` and are shifted back out on `MISO`

Default parameters in the imported source:

- `ADDR_WIDTH = 4`
- `DATA_WIDTH = 8`
- `SPI_WR_REG_DEPTH = 11`
- `SPI_RD_REG_DEPTH = 1`

That means the default RFME import is an 11-byte writable bank plus 1 byte of readback data.

## 2. RFME local mirror

Local source mirror:

- [SPI_TX.v](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/verilog/SPI_TX/SPI_TX.v)

Local RFME synth collateral:

- [Makefile](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/synth/SPI_TX/Makefile)
- [SPI_TX.tcl](/C:/Users/nav/Box/Student-Naveed/Paper/RFME/synth/SPI_TX/SPI_TX.tcl)

## 3. RFME server paths

RFME server source:

- `/rdf/VLSI/Projects/Naveed/RFME/verilog/SPI_TX/SPI_TX.v`

RFME server synth folder:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/SPI_TX`

Generated RFME synth outputs:

- `/rdf/VLSI/Projects/Naveed/RFME/synth/SPI_TX/SPI_TX.nl.v`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/SPI_TX/SPI_TX.sdc`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/SPI_TX/SPI_TX.dc.rpt`
- `/rdf/VLSI/Projects/Naveed/RFME/synth/SPI_TX/SPI_TX.dc.sdf`

## 4. RFME synthesis settings

The imported RFME synth TCL uses:

- `read_sverilog` for the original `.v` source
- clock port: `SCLK`
- clock period: `100.0 ns`
- clock uncertainty: `0.5 ns`
- clock transition: `0.5 ns`

Why `read_sverilog` was used:

- the source uses parameterized arrays and `$clog2`

## 5. Validation status

The block was successfully synthesized in the RFME TSMC180/YAN flow.

Confirmed:

- the RFME netlist is mapped to YAN standard cells
- outputs were generated under `RFME/synth/SPI_TX`

Observed compile-time source warnings:

- forward reference to `spi_wr_reg`
- signed-to-unsigned conversion warnings

These did not stop synthesis.

## 6. Controller integration notes

This is best thought of as an SPI slave register front-end, not a complete controller subsystem.

Practical meaning:

- connect `DW_REG` into the RFME controller's writable configuration bank
- drive `UP_REG` from the controller's readable status/data bank

Important assumptions/caveats:

- the logic behaves like an SPI mode-0 style interface
- `UP_REG` should be stable while being read out during an SPI transaction
- if a wider readback space is needed, increase `SPI_RD_REG_DEPTH`
- if a wider write bank is needed, increase `SPI_WR_REG_DEPTH` and, if necessary, `ADDR_WIDTH`

## 7. Good next steps

If this block is going to become the RFME controller SPI front end, the next useful tasks are:

1. define the RFME register map that should sit on `DW_REG` and `UP_REG`
2. decide whether to keep the imported top name `SPI_TX` or wrap/rename it to an RFME-specific module
3. add a small RFME-local testbench around the imported source
4. create an APR folder for it if physical implementation is wanted next
