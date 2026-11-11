local ssu = require "::/gui/main/stylesheetutil.lua"

-- The options window (ruler_tool.lua): at the bottom right, where the construction menu's
-- Settings window sits (Window!construct-settings in ::/gui/construction/construction.css.lua). The segment labels: a full-screen floating layout, each label centred on its point.
-- padding / margin: { top, right, bottom, left }.

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	-- the HUD button: the mod button area puts the mods' buttons side by side with no space
	-- between; 2 px each side (path-visualizer's button has the same)
	a("R::Component!imsvale-ruler-button-area", {
		margin = { 0, 2, 0, 2 },
	})

	-- the eye and X below it: a window that is only a wrapper, its frame (surface, contour and
	-- shadow images: the Window rule in builtin.css.lua) made fully transparent and its title
	-- bar hidden (as the line manager's popovers hide theirs); the buttons smaller (the layer
	-- buttons are 32 px: ExpandableLayerButton)
	a("Window!imsvale-ruler-popups-window", {
		-- opened at the button's bottom middle (ruler_button.script.lua)
		anchorPoint = { 0.5, 0.0 },
		backgroundColor1 = { 0, 0, 0, 0 },
		borderColor = { 0, 0, 0, 0 },
		shadowColor = { 0, 0, 0, 0 },
	})
	a("Window!imsvale-ruler-popups-window Window::TitleBar", {
		visibility = "none",
	})
	-- 2 px above: the same gap as between the two buttons (inside the window, so the mouse
	-- crosses no gap on the way from the main button)
	a("Window!imsvale-ruler-popups-window Window::Content", {
		padding = { 2, 0, 0, 0 },
	})
	a([[Window!imsvale-ruler-popups-window ToggleButton,
		Window!imsvale-ruler-popups-window Button]], {
		size = { 22, 22 },
		padding = { 3, 3, 3, 3 },
		margin = { 0, 0, 2, 0 },
	})
	-- The X (a plain Button) as the eye looks off: every button has the same surface image, and
	-- only its tint differs, Invisible on a Button, BaseMedium on an unchecked ToggleButton
	-- (builtin.css.lua; the colours from the game's own table, as there). Pressed, too.
	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
	a("Window!imsvale-ruler-popups-window Button", {
		backgroundColor1 = colorDefault.BaseMedium,
	})
	a("Window!imsvale-ruler-popups-window Button:active", {
		backgroundColor1 = colorDefault.BaseDark,
	})

	a("Window!imsvale-ruler-window", {
		anchorPoint = { 1.0, 1.0 },
		gravity = { 1.0, 1.0 },
		margin = { 50, 20, 360, 0 },
	})
	a("Window!imsvale-ruler-window Window::Content", {
		padding = { 4, 12, 10, 12 },
	})
	a("Window!imsvale-ruler-window CheckBox", {
		margin = { 6, 0, 6, 0 },
	})
	a("BoxLayout!imsvale-ruler-row", {
		margin = { 4, 0, 4, 0 },
	})
	a("TextView!imsvale-ruler-row-label", {
		minSize = { 80, -1 },
	})
	a("BoxLayout!imsvale-ruler-result", {
		margin = { 6, 0, 0, 0 },
	})
	a("TextView!imsvale-ruler-result-label", {
		minSize = { 80, -1 },
	})

	-- without the gravity the layout collapses at the left edge (road-priority-yield's hover icons)
	a("FloatingLayout!imsvale-ruler-labels", {
		gravity = { -1, -1 },
	})
	-- road-priority-yield's form of the same rule, in case the class alone doesn't match
	a("R::ImsvaleRulerOverlay FloatingLayout", {
		gravity = { -1, -1 },
	})
	-- the same, for the labels outside the tool (ruler_overlay.lua)
	a("R::ImsvaleRulerLabels FloatingLayout", {
		gravity = { -1, -1 },
	})
	-- a colour alone draws nothing: it tints the background image (path-visualizer's swatch)
	a("TextView!imsvale-ruler-label", {
		anchorPoint = { 0.5, 0.5 },
		padding = { 1, 5, 1, 5 },
		backgroundImage1 = { fileName = "::/gui/menu/design/allwhite_main.tga" },
		backgroundColor1 = { 0.0, 0.0, 0.0, 0.6 },
		color = { 1.0, 1.0, 1.0, 1.0 },
	})

	return result
end
