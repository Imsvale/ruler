# Ruler: investigation and design (2026-11-08)

A measuring tool: a button in the HUD's top left mod button area (ruler icon) starts a tool that measures on the map. The tool's options window opens with it.

## Requirements (user, 2026-11-08)

- Accurate to 1 m or better.
- Options window opens with the tool.
- A switch between measuring in XY (2D) and XYZ (3D), and an option to measure along the terrain's surface.
- Any number of points: a label on each segment in the world with its length, and the total.
- Radius mode: a click sets the origin, the next fixes the radius, and the radius is shown. A further click starts another circle, keeping the earlier ones.
- Snap to stations, industries and towns, at any point. Holding Shift or C turns snapping off.
- The measurement shows in a cursor tooltip and in a field in the window.
- Right-click undoes the last point, until none are left; right-click with no points exits the tool. Holding right-click for 1 s clears everything.
- The more precise builder tooltip length is left to Better Construction Tooltip (below).

## The game's own ruler: not reachable

The debug window's ruler is engine code. The exe has a C++ class `UI::Ruler` (built from a terrain pointer and its own render pass) and `MakeRuler` in the debug view, plus the strings "Ruler", "Toggle ruler" and "Distance:". The only Lua trace is its window style in `game-src/gui/main/debug.css.lua` (`Window!debug-ruler`). No Lua API, input action or recipe reaches it, and the debug window itself is `UI::DebugViewComp` (`docs/GUI.md`). The mod builds its own.

## Building blocks

| Need | How | Source |
|---|---|---|
| Top left button | `react-plugin ::MainModButtonAreaExtension`, a `builtin.ToggleButton` with an `ImageView` | path-visualizer `path_visualizer_button.*` |
| Start a tool from the button | `react.RegisterTool{ name, push, pop, shelve }`; push it with `(ug_require "::/gui/main/game_react_globals.tl").getDefaultToolStackApi().push(RulerTool, nil, param, false)`. `push` gets a `ToolStackContext` with `setActionFn` (installs our ActionDescriptor) and `popSelf` | `game.tl` pushes the Finance / Company tools this way; `selector_react_util.InspectorTool` is the closest model (a map-picking tool, push / pop / shelve) |
| Mouse on the map | `builtin.Selector` among the descriptor's children: `onProcessMouseEvent` (every move), `onSelect` (click), `onHover` (entity under the cursor); position from `api.gui.mouse.getTerrainPosition()` after `hasTerrainPosition()` | `../CLAUDE.md` picking notes |
| Draw lines and circles | `builtin.EdgeRenderable{ edges, ignoreDepth = true }`: straight `EdgeGeometry` pieces, `ARC` geometry for circles; `width` acts as a half width | Parallelism `parallelism_overlay.lua` (`makeStraightEdge`, `makeDisc`) |
| Segment labels in the world | `api.gui.camera.world2Screen(Vec3f)` → `Vec2i`, each label a `builtin.FloatingLayoutChild{ h = x, v = y, item = TextView }` in a full-screen `FloatingLayout`, moved in `react.onStep`; centred with an inline `anchorPoint = { 0.5, 0.5 }` | the callout container places its callouts this way (`callout_container.tl`, `FloatingLayoutChild` at pixel positions, recomputed every step). No game code calls `world2Screen`: whether its pixels match the layout's (UI scaling) is to check |
| Cursor tooltip | `builtin.ActionTooltip{ recipe, param }` among the descriptor's children; `construction_react_util.SimpleTooltipRecipe` with `{ message = { message = "1 234.5 m" } }`, or a recipe of our own | `construction_react_util.tl` 1357–1407 |
| Options window | `builtin.Window` through `getDefaultWindowApi()`: `addSingletonWindow` in the tool's `push`, `removeAllWindows` in `pop` (hidden on `shelve`), as `tool_react_util.prepareDefaultToolWithWindowDefinition` does | `docs/GUI.md`, Windows |
| Terrain height | `api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))` | `custom_entity_util.tl`, `ufo_util.tl` |
| Snap targets | `forEachEntityWithComponent` over `TOWN`, `INDUSTRY`, `STATION_GROUP` (all on the safe list); position from `ug_require "::/scripts/entity_util.tl"` `getPosition(entity)` | `town_util.getTownsToPositions` does this for towns |
| Shift held | `api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")`: that action is Shift alone (user's `settings_keys_v3.lua`) | `construction_react_util.tl` 1916 |
| C held | `react.useInputAction("constructNoSnap", react.iaHandlerExtended(fn))`: `data.status` is `Triggered` on press, `EndReleased` / `EndAborted` on release. `constructNoSnap` is C | `finances_charts.tl` 81 (hold detection) |
| Right-click, press and release | right mouse (`mouseButton = 3`) is bound to `IA_MENU_BACK` and `IA_BACK`; `iaHandlerExtended` on `IA_MENU_BACK` reports press and release | user's `settings_keys_v3.lua` |
| Time | `api.util.getApplicationTime()` (seconds) | `callout_container.tl` |
| Number formatting | `api.util.formatLength(metres, decimals, ?)`: engine-side, undocumented; follows the metric / imperial setting | used across the game's GUI |

Going through the game's input actions (not raw keys) means rebinding Shift, C or the back button carries over.

## Measurement

- **Accuracy:** terrain positions are 32-bit floats; at 10 km from the origin that's about 1 mm. Showing 0.1 m is honest.
- **Three ways to measure** (one setting, three buttons): **2D** (XY), **3D** (straight XYZ between the points), **Terrain** (along the ground between the points: sample about every metre, capped, z from `getHeightAt`, sum the 3D pieces). In Terrain mode the line is drawn from the same pieces; in 2D / 3D it's one straight piece per segment (an EdgeRenderable edge is linear in height, it doesn't drape by itself).
- **Point heights:** a point on open ground has the terrain height. A snapped point at the target's `getPosition` may sit above the ground (a bounding box centre): use the terrain height under it, at least for 3D. To see in game.
- **Radius:** measured per the mode (2D or 3D; Terrain radius is a surface distance from the origin, and its circle would be irregular, so Terrain may just count as 3D here). The circle is drawn level at the origin's height, or draped by sampling: to decide by looks.
- **Snapping:** start with the entity under the cursor (Selector `onHover` → its station group, industry or town), falling back to the nearest target within some distance for towns, where open ground has nothing under the cursor. A town's `entity_util.getPosition` is presumably its bounding box centre (`getBoundingVolumePosition` sits next to it), not the town hall: to check.

## Interaction

- **State:** a list of measurements, each a polyline (points) or a circle (origin, radius). The current mode decides what the next click starts. Switching mode keeps what's there.
- **Polyline:** each click adds a point; the segment from the last point to the cursor is live. Each segment carries its length as a label at its middle; the total shows in the tooltip and the window.
- **Radius:** click 1 origin, click 2 fixes the radius (label on the radius line); click 3 starts a new circle.
- **Right-click:** undo on release if held under 1 s (removes the last point, a fixed radius goes back to live, an origin goes away). Held for 1 s: everything is cleared at that moment, and the release does nothing more. With nothing placed: the release exits the tool (`ctx.popSelf()`). Undo therefore comes on release, not on press, so a hold can still become a clear.
- **Escape** shares `IA_MENU_BACK` with right-click (and gamepad B). Unless the Selector's mouse events tell them apart, Escape would undo too. Possibly fine; else Escape exits at once if a right-click can be told by its mouse event. To see in game, along with whether the right-click reaches the Selector at all.
- **One polyline** only, for a start (user, 2026-11-08; since 2026-11-09 polylines that end at a join are kept, below). Measurements are cleared when the tool closes.
- **Modes** (user, 2026-11-09): **Line** (the default: two points; a further click starts a new line, and undo brings the old one back), **Poly** (a polyline) and **Radius**.
- **Snapping to placed points** (user, 2026-11-09): any placed point (line points, circle origins and radius points) within 1.5 % of the camera distance (at least 1 m), ahead of stations and the rest.
- **Escape leaves the tool at once; right-click does the layered undo** (user, 2026-11-09). Both arrive as the same back actions, so the right button is followed through the Selector's mouse events (press, release, moves), and a back action with no right press within 0.2 s of it counts as Escape. A right hold clears only if neither the mouse (8 px) nor the camera moved: a right drag turns the camera.

## Builder tooltip length: Better Construction Tooltip

Decided 2026-11-08: the precise length goes in BCT, the mod that already wraps the builder tooltip. What was found:
- The "Length" line is the engine's (exe string `Length: {}`, filled with an already formatted value). `getProposalStringsFn` gets only `(proposal, proposalData)` and returns lines that the engine adds below its own; it never sees the engine's lines. So the precise value can't be appended to the game's line, only given a line of its own. A localization override (compiled `.mo`) could reword the engine's line but not make it more precise.
- The length is the drawn edges' arc length, from the proposal's added segments without the cut pieces (BCT's `splitEdges`). It must match the game's value (horizontal or 3D; bridges and tunnels), compared under 1 km where the game shows whole metres.

## Probe

`tools/probe_ruler.lua` (console) checks `formatLength`'s arguments and km switch, `entity_util` positions for towns / industries / station groups, `getHeightAt` under the cursor, the Shift test, and the tool stack API. The console has its own Lua state (`docs/GUI.md`), so the tool stack part may fail there; the mod is the real test of that.

## Mod layout (first build, 2026-11-08)

```
ruler\
  docs\design.md
  tools\probe_ruler.lua
  mod\                          linked into the staging area as imsvale_ruler (junction)
    mod.json                    modId imsvale_ruler; no params
    _metadata\modinfo.json
    content\gui\
      ruler@2x.tga              button icon, 48 x 48 grayscale like path-visualizer's
      imsvale_ruler.css.lua     window and label styles
      ruler\
        ruler_button.res.lua    MainModButtonAreaExtension
        ruler_button.script.lua the button; pushes / pops the tool
        ruler_tool.lua          the tool (RegisterTool), its action (Selector, EdgeRenderable, ActionTooltip),
                                the overlay (input actions, cursor, segment labels) and the options window
        ruler_core.lua          measurements, undo stack, snapping, sampling, formatting; no UI
```

A UI reload (Right Alt + Shift + R) picks up edits to all of these (user, 2026-11-09). Log lines are prefixed `[ruler]`.

Things the first build logs to settle in game: the snap target counts (and how many have a bounding box), the first back-button event's status, any other mouse button pressed, and the tool opening / closing / shelving.

First test (user, 2026-11-09), and the changes made:
- Right-click always closed the tool, and none of the overlay's back handlers fired. Right-click and Escape are also bound to `IA_CLOSE_TOPMOST_WINDOW`, which closed the options window, and its `onClose` ends the tool. Now the overlay takes the focus (`setForceFocusable`, `setRestrictMouseFocus`, `focus()` on mount, as the inspector tool and Nodeforming do) and handles `IA_CLOSE_TOPMOST_WINDOW`, `IA_MENU_BACK` and `IA_BACK` alike, which also stops the window from closing (the callout's trick, `callout_react_util.tl`).
- Fast clicks placed nothing: a quick second press arrives as `DoubleClicked`, not `Pressed`. Points are now placed on either, at the press. The click-versus-drag check is gone: the camera drags with the right button.
- Snapping worked (a test map with only some infrastructure: no towns or industries).
- Segment labels didn't show. The first projection is now logged (count, screen position, viewport size, error).
- The Mode and Measure rows showed only their names: `script_param_util.buildScriptParamCompSimple` with `uiType = Button` rendered no buttons here (why is unclear). The rows are now a `TextView` and a `builtin.ToggleButtonGroup` of our own.

Second test (user, 2026-11-09): right-click undo and exit worked; holding to clear didn't, possibly because the camera's right-button drag takes the input over. The log showed `IA_CLOSE_TOPMOST_WINDOW` reaching the overlay (status 0, Triggered) and the Selector seeing mouse button 2. The first label was projected to 883,671 on a 1920x1080 viewport. Changed: the right button is followed through the mouse events (above), Escape leaves at once, Line / Poly modes, snapping to placed points. The first 12 back and right-button events are logged.

Third test (user, 2026-11-09): labels still invisible; right-click exited at once. The log: right-click reached the overlay only as `IA_CLOSE_TOPMOST_WINDOW` (Triggered, then EndReleased), never as `IA_BACK` or as a Selector mouse event, so "no right press near it" took every right-click for Escape. Bindings (user's `settings_keys_v3.lua`): right mouse is `IA_BACK`, `IA_CLOSE_TOPMOST_WINDOW`, `IA_CONSTRUCTION_ACTION_CANCEL`, `IA_MENU_BACK`; Escape is those but `IA_BACK`, plus `IA_MENU` and `IA_SKIP_VOICEOVER_AND_CUTSCENE`. Changed:
- The labels' `FloatingLayoutChild` `h` / `v` were given in pixels; they are fractions of the layout (road-priority-yield's icon overlay divides `world2Screen` by `camera.getSize()`). The labels were placed far off screen.
- The back actions are the right button again (Triggered = down, EndReleased = up). Escape is taken as `IA_MENU` (Escape only), which leaves at once, if it reaches the overlay before `IA_CLOSE_TOPMOST_WINDOW` does.
- Every back action, mouse right event, release and clear is logged with the time since the tool opened (`[ruler]   1.234 s  …`), up to 40 per opening. The action's `onBack` only logs now.

Fourth test (user, 2026-11-09): labels show; right-click undo / exit, Line mode and point snapping work; hold to clear and Escape don't (Escape undid). The log:
- A right-click reaches the overlay only at release, as `IA_CLOSE_TOPMOST_WINDOW` Triggered (0) and EndReleased (3) in the same instant. About every other right press also came to the Selector as a mouse event (Pressed), about 0.08 s before; no mouse release ever did.
- Escape: `IA_CLOSE_TOPMOST_WINDOW` Triggered, then PressedStep (2) about every 10 ms while held. `IA_MENU` never arrived.
- A right hold left no trace that could be found.
Changed: a back action whose release comes in the same instant as its press is a right-click; one with PressedStep, or released later, is Escape and leaves the tool. Every right-button mouse event is logged by type, and a right press still down after 0.5 s.

Fifth test (user, 2026-11-09): Escape, right-click undo / exit and joins work; a right hold cleared nothing. The log: the Selector gets every right press, as `PressedOutside` (plus `DoubleClicked` on a quick second one), and the release as `Clicked`, never `Pressed` / `Released`. A press of about 0.08 s also sends the back action, at the `Clicked`. A 3 s hold sends only `PressedOutside` ... `Clicked`, no back action. Changed: the right button is followed by `PressedOutside` / `Clicked`; the hold clears at 1 s if neither mouse nor camera has moved; a release sooner undoes, with the back action that may come at the same instant ignored.

Sixth test (user, 2026-11-09): right hold clears, quick and slow clicks undo once, a right drag changes nothing. Input settled; the event logging is now behind `DEBUG_INPUT` in `ruler_tool.lua` (off). Also confirmed: 2D / 3D / Terrain measure as intended, Radius mode works, turning snapping off works (checkbox, Shift, C), and the window's field matches the tooltip.

**Polylines end at a join** (user, 2026-11-09): in Poly mode, a point snapped to a placed point (other than the polyline's own last one) ends the polyline there. It stays drawn (`S.lines`), and the next click starts another, which may start on a placed point. Undo reopens it. The window's total is the polyline being placed, or the last one ended.

No game script: nothing needs saving. `severityAdd` / `severityRemove` likely `None` (GUI only), to confirm by adding and removing it.
