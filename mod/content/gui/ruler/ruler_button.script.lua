-- Ruler: the button in the HUD's mod button area (top left). Pressing it starts the tool
-- (ruler_tool.lua) with its options window; pressing it again, or the
-- window's close button, ends it. The button follows the tool, also when something else ends it.
--
-- With the tool closed and measurements kept, hovering the button shows two smaller buttons
-- below it: the eye shows or hides the measurements in other tools (ruler_overlay.lua), the X
-- clears them. They stay while the mouse is over the button or them, and GRACE seconds after.
--
-- They're a window with no frame, background or title (imsvale_ruler.css.lua) opened under
-- the button. Tried first, 2026-11-11:
-- * in the plugin's own layout: the button row grew taller, and the other mods' buttons moved
--   down to its middle;
-- * hanging below the button as an overflow FloatingLayoutChild: drawn, but outside the button
--   area's rect they got no mouse events at all (no clicks, no hover).
--
-- A recipe placed among a layout's children must return a layout ("Recipe child must be a
-- layout": the game crashed on one returning a Component, 2026-11-11), as vanilla's hover
-- recipes do (the cargo filter's buttons: a FloatingLayout with onMouseEvent).

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl"
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl"
local core = ug_require "imsvale_ruler::/gui/ruler/ruler_core.lua"
local tool = ug_require "imsvale_ruler::/gui/ruler/ruler_tool.lua"

local S = core.S
local log = core.log
local BUTTON_ID = "imsvale_ruler.button"
local GRACE = 0.4 -- seconds
-- true logs where the pop-ups open: the plugin's position, the button's size
local DEBUG_POPUPS = false

local ICON_EYE = "::/gui/game_bar/icons/symbol_eye.tga"
local ICON_CLEAR = "::/gui/builtin/window/icons/symbol_close.tga"

-- the mouse over the button / over the pop-ups, and when it last left either
local hover = { button = false, popups = false, left = -1e9 }
local popupsOpen = false

local function icon(path)
	return builtin.ImageView{
		path = path,
		scaling = builtin.type.ImageViewScaling.AutoFit,
	}
end

local function hoverListener(field)
	return function(evt)
		local T = api.gui.mouse.Event.Type
		if evt.type == T.Entered then
			hover[field] = true
		elseif evt.type == T.Exited then
			hover[field] = false
			hover.left = core.now()
		end
		return false
	end
end

-- hovering the pop-ups counts only while they're open
local function popupsWanted()
	if tool.isActive() or not core.hasMeasurements() then
		return false
	end
	return hover.button or (popupsOpen and hover.popups) or core.now() - hover.left < GRACE
end

local Popups = react.RegisterRecipe("ImsvaleRulerPopups", function()
	react.onMouseEvent(hoverListener("popups"))
	local show = react.useState(S.show)
	react.onStep(function()
		if show:old() ~= S.show then
			show:set(S.show)
		end
	end)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			builtin.ToggleButton{
				meta = { tooltip = _("Show measurements") },
				value = show:old() and 1 or 0,
				onValueChange = function(value)
					core.setShow(value == 1)
				end,
				content = icon(ICON_EYE),
			},
			builtin.Button{
				meta = { tooltip = _("Clear measurements") },
				onClick = function()
					core.clear()
				end,
				content = icon(ICON_CLEAR),
			},
		},
	}
end)

local PopupsWindow = react.RegisterWrapperRecipe("ImsvaleRulerPopupsWindow", builtin.Window, function(params)
	return builtin.Window{
		-- A wrapper recipe's meta may only set class: a styleSheet there crashed the game
		-- ("Wrapper recipe must return child", then an engine assertion, 2026-11-11).
		meta = { class = "no-close-button, imsvale-ruler-popups-window" },
		initialX = params.initialX,
		initialY = params.initialY,
		closable = false,
		movable = false,
		autoFocusOnBecomingVisible = false,
		content = Popups{},
	}
end)

local function windowApi()
	local wc = nil
	pcall(function() wc = game_react_globals.getDefaultWindowContainer():get():getApi() end)
	return wc
end

-- pos: where the window's top middle goes (anchored there in imsvale_ruler.css.lua), as
-- fractions of the screen. That's what initialX / initialY take (vanilla's centred dialogs pass
-- 0.5, 0.5); passed as pixels, the window was pushed to the bottom right (2026-11-11). The window
-- container reads them from these params (builtin.lua, WindowContainer). (A StyleSheet has no
-- writable gravity, and a wrapper's meta takes only a class, so they're the only way.)
local function openPopups(pos)
	if DEBUG_POPUPS then
		log("popups: at %.4f, %.4f", pos.x, pos.y)
	end
	local wc = windowApi()
	if not wc then
		log("no window container")
		return
	end
	wc.removeAllWindows(PopupsWindow)
	wc.addSingletonWindow(PopupsWindow, { initialX = pos.x, initialY = pos.y })
	popupsOpen = true
end

local function closePopups()
	local wc = windowApi()
	if wc then
		pcall(function() wc.removeAllWindows(PopupsWindow) end)
	end
	popupsOpen = false
	hover.popups = false -- removed without an Exited
end

local ButtonArea = react.RegisterRecipe("ImsvaleRulerButtonArea", function(params)
	react.onMouseEvent(hoverListener("button"))
	return builtin.BoxLayout{
		children = {
			builtin.ToggleButton{
				meta = {
					id = BUTTON_ID,
					tooltip = _("Ruler"),
				},
				value = params.active and 1 or 0,
				onValueChange = function(value)
					if value == 1 then
						tool.open()
					else
						tool.close()
					end
				end,
				content = icon("imsvale_ruler::/gui/ruler.tga"),
			},
		},
	}
end)

local Button = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "ImsvaleRulerButton", function()
	local active = react.useState(tool.isActive())
	local selfRef = react.useSelfRef()

	react.onStep(function()
		local ok, err = pcall(function()
			if active:old() ~= tool.isActive() then
				active:set(tool.isActive())
			end
			local want = popupsWanted()
			if want and not popupsOpen then
				-- under the button, centred: the plugin's bottom middle. getPosition(gx, gy) gives
				-- that point of the node as fractions of the screen (0.059, 0.011 for its top
				-- left, 2026-11-11); byId.getSize on the button's id gave 0 x 0.
				local p = selfRef:get():getPosition(0.5, 1.0)
				openPopups({ x = p.x, y = p.y })
			elseif not want and popupsOpen then
				closePopups()
			end
		end)
		if not ok then
			log("button step: %s", tostring(err))
			popupsOpen = true -- no retry every frame
		end
	end)

	-- The root must be a layout, and a layout takes no margin: the margin is on the Component.
	return builtin.BoxLayout{
		children = {
			builtin.Component{
				meta = { class = "imsvale-ruler-button-area" },
				layout = builtin.BoxLayout{
					children = {
						ButtonArea{ active = active:old() },
					},
				},
			},
		},
	}
end)

function data()
	return { Button = Button }
end
