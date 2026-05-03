# RFME ReactiveBank Layout Preferences

Last updated: 2026-04-27

This note captures the preferred layout style for the reactive backscatter switch block used in `RFME/ReactiveBank`.

The goal is not just to make the block compact. The goal is to keep parasitics predictable, branch-to-branch behavior consistent, and the physical implementation easy to wire and debug later.

## Scope

This README applies to the branch-based backscatter load bank structure where each branch contains:

- an NMOS switch device
- a MIM capacitor
- a poly resistor

and the full bank is a regular array of those branches.

## Primary priorities

In order of importance, the layout should optimize for:

1. branch-to-branch symmetry
2. uniform parasitics
3. clean future routing access
4. easy visual inspection
5. compactness only after the above are satisfied

This means a slightly larger but uniform array is preferred over a denser but irregular one.

## Placement philosophy

### 1. Use a fixed branch template

Each branch should use the same high-level physical ordering, with mirrored halves across the array.

Preferred array pattern:

- left half: `M-C-R`
- right half: `R-C-M`

This gives a visually mirrored block and helps keep the overall RF environment balanced.

For the switch devices themselves, the mirror should be real, not just visual:

- left-half NMOS orientation: `R90`
- right-half NMOS orientation: also `R90` for the current preferred flow
- the current preferred choice is to repeat the left-column local flow on the right columns instead of enforcing geometric mirror symmetry

In other words, for the present ReactiveBank preference:

- keep the switch orientation the same across all four columns
- place the passives on the right of the switch in every column
- accept that the overall macro is not perfectly mirrored if that gives the cleaner working branch flow

### 2. Lock devices to fixed slots

Do not let device size determine global placement.

Specifically:

- transistor X positions must be on a fixed global grid
- resistor X positions must be on a fixed global grid
- row Y positions must be on a fixed global grid
- capacitor size must not shift the transistor or resistor lattice

Capacitors are allowed to vary inside their own slot, but they should not move the transistor and resistor columns.

### 3. Keep row baselines aligned

For visual uniformity and parasitic consistency:

- transistor rows should share a common baseline per row
- resistor rows should share a common baseline per row
- capacitor rows should sit in their assigned slots without pulling the rest of the row

If the branch looks straight in the abstract but the bottoms of the resistor or transistor cells do not line up, it is not good enough yet.

### 4. Preserve a regular array pitch

The bank should be laid out as a true 2-D grid, not a hand-packed cluster.

Current reference style:

- `4 x 4` array
- regular X pitch
- regular Y pitch
- global center preserved

The exact pitch can change as dummying changes, but the pitch should remain uniform across the bank.

## Resistor implementation rules

### 1. The physical resistor must match the intended value

It is not enough to set only the displayed `res` property in the schematic or layout.

For `rphpoly`, the implementation must also correctly reflect:

- `w`
- `l`
- `sumW`
- `sumL`
- `segments`
- `prl`
- `srs`
- `ResCalc`

Otherwise different branch resistors can collapse into the same physical device even if the displayed resistance values differ.

### 2. Prefer simple segmentation

Use:

- parallel splitting for low-value resistors when needed
- single branches for moderate and large values when possible

Avoid overly complicated mixed series-plus-parallel forms unless absolutely necessary.

### 3. Keep resistor orientation uniform

Use one consistent resistor orientation across the array so the branch parasitics stay comparable.

For the current bank, the preferred resistor orientation is `R90`.

## Capacitor placement rules

### 1. Treat the capacitor as the center of the RF load branch

The cap is the sensitive analog element. It should be physically readable and easy to route to later.

### 2. Do not surround the cap with more MIM caps

For this block, the preferred dummy environment around the cap is not capacitor dummying.

Preferred approach:

- surround each active MIM cap with poly resistor dummies
- use the largest resistor geometry used in the active schematic
- use multiple layers of those resistor dummies around the cap

### 3. Fully block in the cap edges

The cap should not just have sparse corner dummies.

Preferred cap surround:

- `3` layers of resistor dummies
- resistor dummies tiled along the top edge
- resistor dummies tiled along the bottom edge
- resistor dummies tiled along the left edge
- resistor dummies tiled along the right edge
- corners also covered

In other words, the cap should feel boxed in by a resistor wall, not loosely ringed.

## Dummy strategy

### 1. Resistors get local resistor cages

Each active resistor should have its own local resistor dummy environment.

Preferred current style:

- `2` dummy layers around each active resistor
- effectively a `5 x 5` style resistor cage around the center device

### 2. Capacitors get resistor-only shielding

Each active capacitor should have:

- `3` layers of max-size resistor dummies
- edge-filled dummy coverage
- no capacitor dummies by default

### 3. Dummying should be local, not only global

Do not rely only on a big perimeter dummy ring around the whole macro.

Local branch-level dummying is preferred because it better controls the neighborhood of each analog element.

## Routing preferences

Routing is secondary to placement, but when routing is added later, these are the preferred rules.

### 1. Approve placement before routing

Do not route while the placement and dummy strategy are still in flux.

Preferred flow:

1. finalize active placement
2. finalize dummying
3. inspect visual symmetry
4. then route

### 2. Use orthogonal top-metal routing

For shared routing, do not run both horizontal and vertical trunks on the same top layer.

Preferred convention:

- one top metal for long vertical trunks
- the adjacent top metal for long horizontal trunks
- change direction only through vias

Example good style:

- `M5` vertical
- `M6` horizontal

Avoid:

- horizontal and vertical shared nets overlapping on the same layer

### 3. Widen escape points before via stacks

When a transistor drain or source must be lifted upward:

- first widen the local native metal landing area
- then place large via arrays
- then transition to the global routing metals

This is especially important for the RF node and the source connection into the branch load.

### 4. Keep VSS shared and visually clean

Preferred ground style:

- one shared lower VSS network
- branch bottoms tie cleanly into it
- body ties should connect into that same VSS structure

### 5. Do not optimize the routing by making the placement worse

If a cleaner route requires skewing the device lattice, keep the lattice and fix the route another way.

### 6. Do not literal-mirror the routed branch style into the right half

The right-half routed columns are not a safe place for blind mirrored copies.

What to preserve:

- the source/VSS return structure must stay on the source side and should be treated as authoritative if it has been manually corrected
- the resistor landing must still be anchored to the actual resistor terminal geometry
- the cap-to-res connection must still stop/start at the real cap edge, not a copied edge

What to avoid:

- do not regenerate the right-half columns by simply copying the left-half local metal and flipping it with `MY`
- do not assume the RF trunk can use the same gutter as the left half
- do not let the RF trunk overlap the source/VSS stack or the next column's resistor space

Observed live issue from the `:95` edited layout on `2026-04-27`:

- after a naive mirrored RF regeneration, the right-half RF trunk overlapped the local source/VSS stack envelope
- the column-2 RF trunk also ran into the next column's resistor space

Practical regeneration rule:

- left-half columns may use translated local routing templates
- right-half columns should be regenerated from the left-column working flow without mirroring
- the passives should remain on the right of the switch

The current preferred strategy is:

- use the same `R90` switch orientation in all columns
- copy the left-column flow to the right columns by translation
- increase the last-column passive-side gutter as needed rather than trying to force a mirrored branch style

### 7. Right-half RF routing needs an explicit clearance budget

When routing the mirrored `R-C-M` half:

- reserve a dedicated RF gutter before drawing the RF trunk
- keep positive clearance between the RF trunk and the source/VSS stack
- keep positive clearance between the RF trunk and the next column's resistor area

If there is not enough room for both clearances:

- widen the inter-column gutter, or
- choose a narrower RF trunk slot

Do not "solve" the problem by pushing the RF trunk through the resistor neighborhood or by partially overlapping the source return metal.

## Visual quality rules

This block should look intentionally structured.

A good layout should make the following obvious by eye:

- where the rows are
- where the columns are
- which devices are active
- which devices are dummies
- where the mirrored halves begin

If the layout looks like a pile of correct parts instead of a designed macro, it should be improved.

## Preferred workflow in Virtuoso

Because this block can get heavy quickly, use an incremental workflow.

### Placement stage

- move active instances first
- correct resistor geometry next
- add local dummies last
- save after small logical steps

### Routing stage

- route only after placement is approved
- add global buses first
- add branch escapes next
- leave detailed cleanup for the end

### Automation stage

When scripting this block:

- prefer small transactions over one huge edit
- avoid expensive full-layout queries unless necessary
- separate placement-only scripts from routing scripts
- keep a machine-readable routing rule file for the current preferred style
- treat the live corrected VSS return path as the routing reference, not a disposable intermediate

## Verification checklist

Before calling the block “good”, verify all of the following:

- resistor physical geometry matches intended values
- transistor columns are uniformly aligned
- resistor columns are uniformly aligned
- capacitor size does not move the transistor/resistor grids
- row spacing is uniform
- left and right halves are mirrored as intended
- caps are boxed in by resistor dummies
- resistors have their local guard dummies
- no accidental route shapes remain in a placement-only version

## Current preferred reference

The current reference implementation is the placement-only `ReactiveBank` style with:

- mirrored `M-C-R / R-C-M` branch ordering
- uniform branch pitch
- resistor-correct physical `rphpoly` implementation
- `2` layers of resistor dummies around each active resistor
- `3` layers of edge-filled max-size resistor dummies around each active MIM cap
- routing deferred until after placement approval

## Bottom line

For this kind of backscatter switch block:

- symmetry beats density
- fixed slots beat size-driven placement
- local dummy control beats only perimeter dummying
- orthogonal routing beats opportunistic routing
- a visually clean array usually also has cleaner parasitics
