# Keeping the measurements on screen outside the tool (research, 2026-11-10)

Goal (user, 2026-11-10): the ruler's lines, and ideally their labels, stay up across tool
switches, as references while building. Perhaps the tool can also be used while another tool
is active. Research only, nothing built yet.

## Why they vanish now

- **The data:** the measurements live in `core.S`, and `core.stop()` empties it when the tool
  is popped (`ruler_tool.lua`, `definition.pop`).
- **The drawing:** both lines and labels belong to the tool's own action. The
  `EdgeRenderable` and the `FullScreenComponent` (the labels' `Overlay`) are children of the
  `ActionDescriptor` built in `actionFn`.
- **Rendering:** a 3D renderable only draws inside the active action's descriptor, and only
  one action is active at a time (network-wireframe's overlay header, Parallelism's overlay
  header).
- **What another tool does to ours:**
  - A tool pushed without `allowStacking` replaces ours, so our `pop` runs. The construction
    menu (`construction.tl:4867`), Finance, Company, statistics and the music player are pushed
    this way.
  - A tool pushed with `allowStacking = true` shelves ours (`shelve(ctx, param, true)`): our
    action goes, and the tool comes back when that one is popped. Entity windows
    (`view_manager.tl:511`), free camera and the pause menu are pushed this way.
  - The pushing tool decides which of the two happens, not we.
- **No tool active:** there is still an action, the default tool's (`__pinned__`, the entity
  inspector, `game.tl:463`).

## Lines: solved by the other mods

**network-wireframe** (prototype, its `network_wireframe_replace.script.lua` and
`_overlay.lua`):
- A `react-replacement-config` wraps `builtin.ActionDescriptor`, so every descriptor any tool
  builds gets an `EdgeRenderable` with the overlay's edges.
- The overlay keeps a version number. `injectInto` runs inside the action's recipe and calls
  `react.useState` and `react.onStep` there. That subscribes the active action, so a new edge
  list redraws whatever tool is active.
- Its two flaws:
  - It calls `originalRecipeFn`, not chained, which knocks out other mods' wrappers.
  - It rebuilds `children` without the named entries, which detached the line viewer.

**path-visualizer** (`path_visualizer_replace.script.lua`) is the correct, released version
of the same idea:
- It chains: `_react.recipeReplace[id]`, else `originalRecipeFn[id]`.
- It installs at order -1000, so its wrapper is the innermost.
- It keeps the named children and compacts the nil holes.
- It wraps `builtin.EdgeRenderable` too. Its lines are merged into an action's own
  EdgeRenderable, and a descriptor only gets a new one when it had none, since two are fatal.
- Confirmed: the lines show all the time, also with no tool or window open (CLAUDE.md,
  2026-10-24).

**Parallelism** (`parallelism_menu_patch.lua:1297` on, `parallelism_overlay.lua`) does the same
with field patches of `builtin.ActionDescriptor` / `builtin.EdgeRenderable`:
- It redraws as the camera moves.
- It records that drawing from a mod entry plugin instead crashed the game
  (`IsTransformWithContext`, 2026-10-09).
- It also records that a tool of the mod's own carrying the overlay ended when another tool
  took over (2026-10-10).
- Its known gap: it adds its EdgeRenderable without checking for one
  (`docs/design/2026-10-24_cross-mod-compatibility.md`).

**For the Ruler:**
1. Copy path-visualizer's replace script almost unchanged (new resource
   `ruler_replace.res.lua`, order -1000).
2. Keep the measurements after `pop`: `core.stop()` stops clearing `S.points` / `lines` /
   `circles`, and only the cursor, snap and live segment go.
3. The tool's own `actionFn` then draws only what exists while the tool is in use: the live
   segment, the cursor and snap markers. It hands them to the overlay rather than adding a
   second EdgeRenderable, since its descriptor gets the overlay's lines through the wrapper
   anyway.

Lines would then show in every tool and with none, until cleared.

What that raises:
- **Clearing outside the tool:** needs a way, e.g. a right-click on the HUD button, or a
  "Keep" option in the window so the old behaviour stays the default. To decide.
- **Living with Parallelism and path-visualizer:**
  - All three wrap the same builtins. Merge-aware slot wrappers chain safely (COMPATIBILITY.md
    section 2), and with two at order -1000 the second merges into the first's EdgeRenderable.
  - Parallelism's field patch sits outside all slot wrappers. Its own EdgeRenderable is built
    through `builtin.EdgeRenderable`, so it passes our merging wrapper: our lines go into it,
    and our descriptor wrapper then adds none. path-visualizer works alongside it this way.
    Parallelism's own gap (a second EdgeRenderable in an action that already has one) stays
    as it is, with or without us.
- **Savegame:** this is GUI state for the session only. Keeping the lines across a save
  reload would need a game script's state, and is not asked for.

## First build (2026-11-11)

- **The HUD buttons** (user's design): with the tool closed and measurements kept, two smaller
  buttons show below the HUD button. The eye shows or hides the measurements in other tools;
  the Ruler always shows them to itself. The X clears them. New lines are drawn by opening the
  Ruler.
  - Second round, the same day: the buttons now show on hover only, and stay while the mouse
    is over the button or them, plus 0.4 s. In the first round they sat in the plugin's column,
    which made the whole button row taller and pushed the other mods' buttons down to its
    middle. Next they hung below the button as an overflow `FloatingLayoutChild`, the way the
    layer button shows its key hints. They were drawn there, but got no mouse events outside
    the button area's rect: no clicks, no hover. Third try: a small window in the game's
    popover style, opened under the button the way path-visualizer opens its settings.
- **The overlay:** `ruler_overlay.lua` holds the drawing (moved out of `ruler_tool.lua`), and
  `lines()` / `subscribe()` / `Labels` serve the other actions.
- **The wrappers:** `ruler_replace.script.lua` is path-visualizer's wrapper plus one for
  `FullScreenComponent`. The labels go in as a FullScreenComponent in every action without one
  (way D below, without merging). Actions that have one show lines only.
- **Keeping the measurements:** `core.start()` / `stop()` no longer clear them. Shelving
  (another tool stacked on top) stops the tool the same way, so the measurements show there too.
- **Module look-up:** the wrappers look up the overlay module on every call, so that after a
  UI reload they don't keep using the modules loaded before it.

Found while building, which changes the table below:
- **B is out:** the mod button area is a horizontal `ScrollArea` with the vertical scroll bar
  off (`main_mod_button_area.tl`), so it clips whatever a plugin draws outside it.
- **D is less risky than it looked:** in the game's own code only the town window's layer
  legend (`town.tl:1095`) puts a FullScreenComponent in an action. `FullScreenComponent` is a
  builtin like `EdgeRenderable`, so `ReplaceRecipe` can wrap it to spot one being built.
- **A screen position is readable after all:** a node's screen position, as fractions, is
  `ref:get():getPosition(gx, gy)`, which `callout_container.tl` uses.
- **Pop-up height unknown:** whether the pop-up buttons get cut off by the scroll area's height
  is to be seen in game.

## Labels: no proven way yet

The labels are a 2D layer (a `FloatingLayout` placed by `world2Screen` every step) mounted
by the tool's `FullScreenComponent`. Outside the tool, something else has to mount them.

| Way | How | Risk / unknowns |
|---|---|---|
| A. Labels drawn as lines | Digits as strokes in the same EdgeRenderable (a simple stroke font, about 15 glyphs: `0-9 . , k m`), laid flat or facing the camera, sized by camera distance and redrawn when the zoom changes (Parallelism already redraws on camera change) | Rides on the proven line route, nothing new to mount. Unknown: readability at an angle and over busy ground; `ignoreDepth` keeps them on top. Cost: a few edges per character |
| B. From the HUD button's plugin | `ruler_button.script.lua` is mounted all session in the visible mod button area (unlike `ModEntryPointExtension` plugins, whose container has class `invisible`, `game.tl:578`). Its layout root could hold the labels' FloatingLayout, `mouseTransparent` | Untested whether a child there can cover the screen. The area is a BoxLayout in a `FloatingLayoutChild` at 0,0 that sizes to its content: a full-screen child may stretch the button ridge or take mouse focus. A quick test settles it |
| C. A full-screen window | A non-closable, title-less, `mouseTransparent` window from `getDefaultWindowContainer()` holding the FloatingLayout | Unknown whether Escape / right-click (`IA_CLOSE_TOPMOST_WINDOW`) close or skip it, whether it takes focus from other windows, and how the window frame draws with no title bar (hiding it broke the frame in path-visualizer, `docs/GUI.md`) |
| D. Injected `FullScreenComponent` | Add one to every descriptor, as with the lines | Two in one action are fatal (COMPATIBILITY.md) and vanilla actions do use one (town window, `town.tl:1095`). Merging would mean wrapping `builtin.FullScreenComponent` to mount ours alongside another's recipe: possible, but it changes other tools' components. Last resort |
| E. The callout container | `gameCtx.calloutContainerRef` (full-screen, `game.tl:913`; `open{ recipe, anchor, getPositionFn }`) | Made for one hover callout at a time, which the game opens and closes itself (construction menu lists): ours would fight them. No |

Suggested order: try B first (one test with a dummy label), fall back on A. A would also make
the labels consistent with the lines, drawn in the world rather than over it.

A middle ground with no label work: persistent lines only, and the labels only while the
tool is active. The user can reopen the Ruler to read a length.

## Using the tool while another is active

No clean way:
- The Ruler's input (left clicks to place, the right-button handling, the overlay holding the
  focus) is its own action's `Selector` and `FullScreenComponent`.
- Putting a Selector into another tool's action would compete with that tool's own picking,
  and the input handlers block the game's own handling while registered (CLAUDE.md, the
  right-click notes).
- What does work: with persistent measurements the two tools can be switched freely. Measure,
  open the road tool and build along the lines, open the Ruler again to add or adjust, and
  nothing is lost in between.

A finer step, if wanted:
- The Ruler's push could use `allowStacking = true`. The tool it covers, an open entity window
  say, would then be shelved rather than closed.
- It doesn't help the other way: the construction menu pushes without stacking and pops ours.
- A live readout while another tool is active, such as the cursor's distance from the last
  point, would need the cursor position from `api.gui.mouse.getTerrainPosition()` in the
  overlay's `onStep`. That is readable from any action, but it again raises the label
  question above.
