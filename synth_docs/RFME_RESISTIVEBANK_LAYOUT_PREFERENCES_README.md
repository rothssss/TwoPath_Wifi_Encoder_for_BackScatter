# RFME ResistiveBank Layout Preferences

Last updated: 2026-04-27

This note captures the preferred layout style for the resistive backscatter switch block used in `RFME/ResistiveBank`.

The goal is to prepare the block for clean manual routing later while preserving the intended resistor values, keeping the RF environment predictable, and making the array easy to inspect and debug.

## Scope

This README applies to the grounded resistive switch bank where each branch contains:

- one NMOS RF switch
- one `rphpoly` resistor load

and the full bank is a regular branch array driven by `CTRL0..CTRL15` with shared `rf` and `VSS`.

## Primary priorities

In order of importance, the layout should optimize for:

1. branch-to-branch uniformity
2. physically correct resistor realization
3. clean future routing access
4. readable RF and control structure
5. compactness only after the above are satisfied

This means a regular, slightly more spacious bank is better than an irregular compact one.

## Placement philosophy

### 1. Use one repeated branch template

Each active branch should follow the same physical ordering and orientation.

Preferred branch order:

- `switch -> resistor`

with all branches using the same topological reading order from the shared RF bus down to the shared ground side.

Do not alternate left-right styles unless there is a strong extracted-parasitic reason to do so.

### 2. Lock switches to a fixed transistor lattice

The switch array should read as one clean transistor row or matrix.

Specifically:

- all switch X positions should sit on a global pitch
- all switch Y positions should share a common baseline per row
- gate access should be uniform from branch to branch
- source/drain landing geometry should be kept as similar as possible

Do not let resistor length changes drag the switch locations around.

### 3. Lock resistors to a fixed resistor lattice

The resistor bank must also sit on a global placement grid.

Specifically:

- resistor anchor X positions should follow a fixed column plan
- resistor anchor Y positions should follow a fixed row plan
- longer resistors may grow inside their own slot, but should not destroy the global lattice

The branch grid should still look intentional even when resistor values vary by a large factor.

### 4. Preserve a real array pitch

This block should look like a true bank, not a pile of individually placed analog parts.

Preferred style:

- regular X pitch between branches
- regular Y pitch between rows
- shared global center
- easy-to-read active branch order

If one branch has to be distorted to make the array fit, the array strategy should be revisited.

## Switch implementation rules

### 1. All switches should remain physically consistent

The active switch devices should all keep the intended schematic sizing and finger structure.

For the current bank, preserve the live schematic intent:

- same device type across all branches
- same width / length / fingering strategy across all active branches
- same orientation unless a deliberate mirrored pattern is chosen everywhere

### 2. Gate access should be easy to route later

The `CTRL0..CTRL15` entries should not be buried.

Preferred control style:

- all gate pins exposed on one side or one clean edge convention
- uniform gate escape direction
- enough room for later top-metal fanout

### 3. Keep the RF node visually obvious

The RF side of the switches should read as one shared structure, not many ambiguous local stubs.

Preferred style:

- one shared RF bus
- uniform taps from each switch into that bus
- similar via strategy for every branch

## Resistor implementation rules

### 1. The physical resistor must match the intended value

It is not enough to set only the displayed `res` property.

For `rphpoly`, the layout must reflect the same physical realization intended by the corrected schematic fields:

- `w`
- `l`
- `sumW`
- `sumL`
- `connection`
- `segments`
- `prl`
- `srs`
- `ResCalc`

If these are inconsistent, layout can silently collapse distinct resistor values into the same physical implementation.

### 2. Preserve the corrected segmentation strategy

The current bank already has a good practical segmentation style:

- low-value resistors use parallel splitting
- mid-value resistors are preferably single-section when possible
- higher-value resistors use clean series segmentation

That strategy should be preserved in layout rather than replaced with arbitrary manual stretching.

### 3. Current preferred resistor realization

The present corrected bank uses:

- sheet resistance `Rs = 321.8 ohm/sq`
- resistor width `w = 2.0 um`
- segment lengths roughly kept in the `1..5 um` regime when possible

Representative current bank style:

- `R18 = 30.7811 ohm` as `6` parallel segments
- `R17 = 72.3384 ohm` as `3` parallel segments
- `R8 = 979.92 ohm` as `2` series segments
- `R12 = 2.88265 kohm` as `4` series segments
- `R15 = 13.8343 kohm` as `18` series segments

Those values are the reference intent and should drive the layout structure.

### 4. Keep resistor orientation uniform

Use one consistent resistor orientation across the bank so parasitics stay comparable.

Preferred current orientation:

- `R90`

unless there is a strong matching or routing reason to change the entire bank consistently.

## Dummy strategy

### 1. Resistors should get local resistor-context support

This bank is dominated by resistor correctness, so local resistor environment matters more than dense packing.

Preferred approach:

- add local resistor dummies where branch-edge context would otherwise be very different
- keep dummy style uniform at the array edges
- do not let perimeter branches see a wildly different neighborhood than center branches

### 2. Switches should see comparable neighborhood density

The switch row should not have isolated edge devices with very different surroundings.

Preferred approach:

- use device-edge regularization or dummy strategy if required by your process flow
- keep branch-edge transistor context visually and electrically similar

### 3. Prefer local consistency over only global rings

A single outer dummy frame is not enough if the local branch neighborhoods are inconsistent.

## Routing preferences

Routing is intentionally deferred until placement is approved, but the placement should be built to make routing easy.

### 1. Approve placement before routing

Preferred flow:

1. finalize switch placement
2. finalize resistor geometry and segmentation placement
3. check branch pitch and symmetry
4. only then route shared nets

### 2. Use one clean RF bus strategy

Preferred RF routing style:

- one visually dominant shared RF bus
- equal-looking branch taps into that bus
- enough width and via support for a low-ambiguity RF path

### 3. Keep control routing orthogonal and orderly

For later `CTRL` routing:

- reserve a control-side corridor
- keep `CTRL0..CTRL15` access points aligned
- do not weave control traces through the RF/resistor area if it can be avoided

### 4. Keep VSS shared and simple

Preferred ground style:

- one shared lower VSS structure
- resistor bottoms and switch source-side returns tie in cleanly
- body ties join the same common VSS network

### 5. Widen local landing areas before big via transitions

When lifting the RF bus or shared ground upward:

- widen first
- then place via arrays
- then move to upper routing metals

This is preferred over skinny local landings with abrupt via stacks.

## Visual quality rules

A good ResistiveBank layout should make the following obvious by eye:

- where the switch row or rows are
- where the resistor row or rows are
- which devices are active
- how the RF bus runs
- how the control pins escape
- how the resistor values are physically being realized

If the layout looks like correct parts placed independently rather than a designed macro, it should be improved.

## Preferred workflow in Virtuoso

### Placement stage

- place all active switches first
- place all active resistors second
- fix resistor geometry and segmentation before any detailed routing
- add local dummies after the active array is stable
- save in small logical steps

### Routing stage

- route RF and VSS first
- route control escapes second
- add noncritical cleanup last

### Automation stage

When scripting this block:

- separate geometry-correction scripts from placement scripts
- avoid mixing heavy routing edits into placement-only scripts
- prefer small transactions over one giant rewrite

## Verification checklist

Before calling the block layout-ready, verify all of the following:

- every resistor physical geometry matches the intended corrected schematic fields
- low-value branches really use the intended parallel segmentation
- high-value branches really use the intended series segmentation
- switch array pitch is uniform
- resistor array pitch is uniform
- resistor length variation does not move the switch lattice
- RF bus access is regular branch-to-branch
- VSS structure is shared and clean
- control access is exposed and orderly
- no accidental route leftovers remain in a placement-only snapshot

## Current preferred reference

The current reference implementation for `RFME/ResistiveBank` should be treated as:

- plain unbuffered bank architecture
- pins `CTRL0..CTRL15`, `rf`, `VSS`
- corrected physical `rphpoly` realization from the V95 geometry fix
- switch placement and resistor placement prepared first, with routing added afterward

## Bottom line

For this resistive bank:

- physically correct resistor realization beats cosmetic compactness
- fixed switch and resistor lattices beat value-driven wandering placement
- clean RF/VSS structure beats opportunistic routing
- local context control beats only outer dummying
- a layout that looks orderly by eye is much more likely to behave predictably after extraction
