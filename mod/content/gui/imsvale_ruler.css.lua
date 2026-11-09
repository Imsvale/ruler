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
