-- Ruler: the tool on the game's tool stack, its action (what the map shows and takes while it's
-- active) and its options window.
--
-- The tool is pushed from the HUD button (ruler_button.script.lua) through the game's default
-- tool stack, as game.tl pushes the Finance and Company tools. Its push installs the action with
-- the ToolStackContext's setActionFn and opens the window; pop closes the window. The
-- measurements stay until cleared, shown in other tools by ruler_overlay.lua. The drawing itself
-- (lines, labels) is built there too. The action function runs as a recipe: a version counter
-- in its state, checked every step, re-renders it when the measurements change, rebuilding its
-- EdgeRenderable and tooltip (Parallelism's overlay.subscribe does the same).
--
-- Mouse: a Selector that hovers nothing; its onProcessMouseEvent places a point on a left press.
-- Right-click and Escape are both bound to IA_CLOSE_TOPMOST_WINDOW (and others), which would close
-- the options window and with it the tool: the overlay holds the focus and takes it. A right-click
-- arrives only on release, Triggered and EndReleased in the same instant: it undoes the last point
-- (or exits with none placed). Escape comes as Triggered on the key going down, then PressedStep
-- while it's held, and EndReleased later: it leaves the tool at once. IA_MENU (Escape alone) never
-- reached the overlay (2026-11-09). The Selector sees the right button as PressedOutside and
-- Clicked: held still (neither mouse nor camera moving) for a second, it clears; released sooner,
-- it undoes, whether or not a back action comes (a longer press sends none).
-- C held (constructNoSnap) and Shift held (IA_PRECISION_MODE) turn snapping off.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl"
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl"
local core = ug_require "imsvale_ruler::/gui/ruler/ruler_core.lua"
local overlay = ug_require "imsvale_ruler::/gui/ruler/ruler_overlay.lua"

local S = core.S
local log = core.log
local tool = {}

local TOOL_NAME = "ImsvaleRuler"
local ACTION_KEY = "imsvale_ruler"
local HOLD_TO_CLEAR = 1.0 -- seconds
-- How far a right-click may drag and still undo: the mouse this many pixels, the camera (eye or
-- centre) this share of the camera distance. Beyond either, it's a camera drag.
local DRAG_SLOP = 12
local CAMERA_SLOP = 0.02
-- true logs every back action and right-button event (up to BACK_LOG_MAX per tool opening), with
-- the time since the tool opened: how the input above was worked out
local DEBUG_INPUT = false
local BACK_LOG_MAX = 80
local SAME_INSTANT = 0.004 -- seconds: a back action's press and release this close are a right-click

local ui = {
	ctx = nil, -- the ToolStackContext while the tool is on the stack
	windowOpen = false,
	lastPlace = nil,
	right = nil, -- the right button down: { t, x, y, drag, cleared }
	backLogged = 0,
	openedAt = 0,
	zoomStep = nil,
}

--------------------------------------------------------------------------------
-- drawing

-- where the camera is, to tell a right-button camera drag from a hold even if the mouse
-- events stop during the drag
local function cameraNow()
	local k = nil
	pcall(function()
		local e, c = api.gui.camera.getEye(), api.gui.camera.getCenter()
		k = { e.x, e.y, e.z, c.x, c.y, c.z }
	end)
	return k
end

-- the camera has moved since `from` by more than the slop
local function cameraMoved(from)
	local now = cameraNow()
	if not from or not now then
		return false
	end
	local dist = math.sqrt((from[1] - from[4]) ^ 2 + (from[2] - from[5]) ^ 2 + (from[3] - from[6]) ^ 2)
	local limit = math.max(dist, 1) * CAMERA_SLOP
	for i = 0, 3, 3 do
		local d = math.sqrt((now[i + 1] - from[i + 1]) ^ 2 + (now[i + 2] - from[i + 2]) ^ 2 + (now[i + 3] - from[i + 3]) ^ 2)
		if d > limit then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- leaving the tool

local function exitTool()
	if ui.ctx then
		ui.ctx.popSelf()
	end
end

-- a right-click: in Poly mode with a polyline being placed, end it there (the next click starts a
-- new one); else undo, or leave the tool when nothing's left to undo
local function backTap()
	if S.mode == core.MODE_POLY and #S.points > 0 then
		core.detach()
		return
	end
	if not core.undo() then
		exitTool()
	end
end

-- logged with the time since the tool opened
local function backLog(fmt, ...)
	if DEBUG_INPUT and ui.backLogged < BACK_LOG_MAX then
		ui.backLogged = ui.backLogged + 1
		log("%7.3f s  " .. fmt, core.now() - ui.openedAt, ...)
	end
end

-- the right button went down (from a back action or the mouse event)
-- (a new press replaces one whose release never came)
local function rightDown(source)
	ui.right = { t = core.now(), camera = cameraNow(), drag = false, cleared = false, source = source }
end

-- the right button came up (from the mouse event, or the back action's release)
local function rightUp()
	local r = ui.right
	ui.right = nil
	if r then
		local what = r.cleared and "nothing (cleared)" or r.drag and "nothing (drag)" or "undo"
		backLog("right up after %.3f s (from %s): %s", core.now() - r.t, r.source, what)
		if not r.drag and not r.cleared then
			backTap()
		end
	end
end

--------------------------------------------------------------------------------
-- the overlay: input actions, the per-frame cursor, and the segment labels

local Overlay = react.RegisterRecipe("ImsvaleRulerOverlay", function()
	react.setMouseTransparent(true)
	-- Focused, so the back actions reach this component before the window container's own
	-- IA_CLOSE_TOPMOST_WINDOW closes the options window (and with it the tool). The inspector
	-- tool focuses its selector the same way; Nodeforming keeps its focus with these two.
	react.setForceFocusable(true)
	react.setRestrictMouseFocus(true)
	local selfRef = react.useSelfRef()
	react.onMount(function()
		local ok, err = pcall(function() selfRef:get():focus() end)
		if not ok then
			log("focus: %s", tostring(err))
		end
	end)

	local labels = react.useState({ key = "", list = {} })

	local Status = api.gui.inputAction.InvokeData.Status

	-- the back actions: a right-click, or Escape (told apart by timing, see the top)
	local function escape(why)
		backLog("escape (%s): leaving", why)
		ui.back = nil
		exitTool()
	end
	local function backHandler(name)
		return react.iaHandlerExtended(function(data)
			local ok, err = pcall(function()
				backLog("%s status %s", name, tostring(data.status))
				local now = core.now()
				local b = ui.back
				if data.status == Status.Triggered then
					ui.back = { t = now }
				elseif data.status == Status.PressedStep or data.status == Status.Repeat then
					if b then
						escape("held")
					end
				elseif data.status == Status.EndReleased then
					ui.back = nil
					if b and now - b.t > SAME_INSTANT then
						escape("released later")
					elseif b then
						if ui.right then
							rightUp()
						elseif not (ui.rightUpAt and now - ui.rightUpAt < 0.05) then
							backTap() -- unless the mouse release just did
						end
					end
				elseif data.status == Status.EndAborted then
					ui.back = nil
				end
			end)
			if not ok then
				log("back action: %s", tostring(err))
			end
		end)
	end
	react.useInputAction("IA_CLOSE_TOPMOST_WINDOW", backHandler("IA_CLOSE_TOPMOST_WINDOW"))
	react.useInputAction("IA_MENU_BACK", backHandler("IA_MENU_BACK"))
	react.useInputAction("IA_BACK", backHandler("IA_BACK"))
	react.useInputAction("IA_MENU", react.iaHandler(function()
		backLog("IA_MENU")
	end))

	react.useInputAction("constructNoSnap", react.iaHandlerExtended(function(data)
		if data.status == Status.Triggered then
			S.noSnapKey = true
		elseif data.status == Status.EndReleased or data.status == Status.EndAborted then
			S.noSnapKey = false
		end
	end))

	react.onStep(function()
		local ok, err = pcall(function()
			if not S.active then
				return
			end
			core.updateCursor()
			-- lines are drawn wider zoomed out: redraw when the zoom has changed by a quarter
			local step = overlay.zoomStep()
			if step ~= ui.zoomStep then
				ui.zoomStep = step
				core.changed()
			end
			local now = core.now()
			local r = ui.right
			if r and not r.drag and cameraMoved(r.camera) then
				r.drag = true
				backLog("right drag (camera moved)")
			end
			if r and not r.logged and now - r.t >= 0.5 then
				r.logged = true
				backLog("right still down after 0.5 s (drag %s)", tostring(r.drag))
			end
			if r and not r.drag and not r.cleared and now - r.t >= HOLD_TO_CLEAR then
				r.cleared = true
				backLog("held: clearing")
				core.clear()
			end

			local list = overlay.screenLabels(S.view)
			local key = overlay.labelsKey(list)
			if key ~= labels:old().key then
				labels:set({ key = key, list = list })
			end
		end)
		if not ok and not ui.loggedStepError then
			ui.loggedStepError = true
			log("overlay step: %s", tostring(err))
		end
	end)

	return overlay.labelsLayout(labels:old().list)
end)

--------------------------------------------------------------------------------
-- the action

local function onMouse(evt)
	local T = api.gui.mouse.Event.Type
	local pressed = evt.type == T.Pressed or evt.type == T.DoubleClicked
	-- the right button: not consumed, the camera drags with it
	if DEBUG_INPUT and evt.button == 2 and evt.type ~= T.Moved then
		local names = {}
		for _, n in ipairs({ "Pressed", "Released", "Clicked", "DoubleClicked", "PressedOutside", "Wheel", "Entered", "Exited" }) do
			if evt.type == T[n] then
				names[#names + 1] = n
			end
		end
		backLog("mouse button 2 %s at %d,%d", table.concat(names, "/"), evt.x, evt.y)
	end
	-- the right button comes as PressedOutside (DoubleClicked too when quick) and Clicked; a
	-- long hold sends no back action, only these (2026-11-09)
	if evt.button == 2 then
		if pressed or evt.type == T.PressedOutside then
			rightDown("mouse")
			ui.right.x, ui.right.y = evt.x, evt.y
		elseif evt.type == T.Clicked or evt.type == T.Released then
			if ui.right then
				ui.rightUpAt = core.now()
				rightUp()
			end
		end
		return false
	end
	local r = ui.right
	if r and r.x and evt.type == T.Moved and not r.drag and math.abs(evt.x - r.x) + math.abs(evt.y - r.y) > DRAG_SLOP then
		r.drag = true
		backLog("right drag (mouse moved)")
	end
	-- a point on the left press; a quick second press comes as DoubleClicked instead of Pressed
	if not pressed or evt.button ~= 0 then
		return false
	end
	local now = core.now()
	if ui.lastPlace and now - ui.lastPlace < 0.05 then
		return true -- the same press reported twice
	end
	ui.lastPlace = now
	core.updateCursor()
	core.place()
	return true
end

local function actionFn()
	local seen = react.useState(S.version)
	react.onStep(function()
		if seen:old() ~= S.version then
			seen:set(S.version)
		end
	end)

	local view = S.view
	local children = {
		builtin.FullScreenComponent{ recipe = Overlay, param = {} },
		builtin.Selector{
			filter = function() return false end,
			onSelect = function() return false end,
			onProcessMouseEvent = function(evt)
				local ok, consumed = pcall(onMouse, evt)
				if not ok then
					log("mouse: %s", tostring(consumed))
					return false
				end
				return consumed
			end,
		},
	}
	if view and view.tooltip then
		children[#children + 1] = builtin.ActionTooltip{
			recipe = construction_react_util.SimpleTooltipRecipe,
			param = { message = { message = view.tooltip } },
		}
	end
	if view then
		local ok, edges = pcall(overlay.buildEdges, view)
		if ok and #edges > 0 then
			children[#children + 1] = builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
		elseif not ok then
			log("drawing: %s", tostring(edges))
		end
	end
	return builtin.ActionDescriptor{
		children = children,
		terrainCirclePolicy = "Never",
		onBack = function()
			backLog("action onBack")
		end,
	}
end

--------------------------------------------------------------------------------
-- the options window

-- a label and a row of toggle buttons, one of them pressed (indices from 1). Built directly: the
-- script param helper showed only the label here.
local ButtonsRow = react.RegisterRecipe("ImsvaleRulerButtonsRow", function(params)
	local selected = react.useState(params.get())
	react.onStep(function()
		local want = params.get()
		if selected:old() ~= want then
			selected:set(want)
		end
	end)
	local buttons = {}
	for i, text in ipairs(params.values) do
		buttons[i] = {
			meta = { tooltip = params.tooltips and params.tooltips[i] or nil },
			content = builtin.TextView{ meta = { class = "font-scale-body" }, text = text },
		}
	end
	return builtin.BoxLayout{
		meta = { class = "imsvale-ruler-row" },
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.TextView{ meta = { class = "imsvale-ruler-row-label" }, text = params.name },
			builtin.ToggleButtonGroup{
				buttons = buttons,
				selected = selected:old(),
				onValueChange = function(index)
					local ok, err = pcall(params.set, index)
					if not ok then
						log("%s: %s", params.name, tostring(err))
					end
					selected:set(params.get())
				end,
			},
		},
	}
end)

-- the measurement: the polyline's total in Line mode, the radius in Radius mode
local Result = react.RegisterRecipe("ImsvaleRulerResult", function()
	local function current()
		local view = S.view
		if S.mode == core.MODE_RADIUS then
			return _("Radius"), view and view.radius and core.format(view.radius) or "–"
		end
		return _("Total"), view and view.total and core.format(view.total) or "–"
	end
	local label, value = current()
	local state = react.useState(label .. "\n" .. value)
	react.onStep(function()
		local l, v = current()
		if state:old() ~= l .. "\n" .. v then
			state:set(l .. "\n" .. v)
		end
	end)
	return builtin.BoxLayout{
		meta = { class = "imsvale-ruler-result" },
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.TextView{ meta = { class = "imsvale-ruler-result-label" }, text = label },
			builtin.TextView{ meta = { class = "imsvale-ruler-result-value" }, text = value },
		},
	}
end)

local WindowContent = react.RegisterRecipe("ImsvaleRulerWindowContent", function()
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			ButtonsRow{
				name = _("Mode"),
				values = { _("Line"), _("Poly"), _("Radius") },
				tooltips = { _("Two points"), _("Polyline"), _("Radius") },
				get = function() return S.mode end,
				set = function(i) core.setMode(i) end,
			},
			ButtonsRow{
				name = _("Measure"),
				values = { "2D", "3D", _("Terrain") },
				tooltips = { _("Horizontal (XY)"), _("Straight (XYZ)"), _("Along the ground") },
				get = function() return S.metric end,
				set = function(i) core.setMetric(i) end,
			},
			builtin.CheckBox{
				label = _("Snap"),
				initialValue = S.snap and 1 or 0,
				onValueChange = function(value) core.setSnap(value == 1) end,
			},
			Result{},
		},
	}
end)

local RulerWindow = react.RegisterWrapperRecipe("ImsvaleRulerWindow", builtin.Window, function(params)
	return builtin.Window{
		meta = { class = "imsvale-ruler-window" },
		title = _("Ruler"),
		closable = true,
		movable = false, -- placed by its style, as the construction menu's Settings window
		onClose = function()
			log("window closed")
			exitTool()
		end,
		content = WindowContent{},
	}
end)

local function openWindow()
	local wc = game_react_globals.getDefaultWindowApi()
	if not wc then
		log("no window container: no options window")
		return
	end
	wc.removeAllWindows(RulerWindow)
	wc.addSingletonWindow(RulerWindow, {})
	ui.windowOpen = true
end

local function closeWindow()
	local wc = game_react_globals.getDefaultWindowApi()
	if wc then
		wc.removeAllWindows(RulerWindow)
	end
	ui.windowOpen = false
end

--------------------------------------------------------------------------------
-- the tool

local function activate(ctx)
	ui.ctx = ctx
	ui.right, ui.back, ui.zoomStep, ui.backLogged, ui.openedAt = nil, nil, nil, 0, core.now()
	ctx.setActionFn(actionFn, ACTION_KEY)
	openWindow()
end

local definition = {
	name = TOOL_NAME,
	push = function(ctx, param)
		local ok, err = pcall(function()
			core.start()
			activate(ctx)
			log("tool opened")
		end)
		if not ok then
			log("open: %s", tostring(err))
		end
	end,
	pop = function(ctx, param)
		pcall(closeWindow)
		pcall(function() ctx.setActionFn(nil, nil) end)
		core.stop()
		ui.ctx = nil
		log("tool closed")
	end,
	shelve = function(ctx, param, shelve)
		if shelve then
			pcall(closeWindow)
			pcall(function() ctx.setActionFn(nil, nil) end)
			core.stop()
			log("tool shelved")
		else
			pcall(core.start)
			pcall(activate, ctx)
			log("tool back")
		end
	end,
}

-- A tool name can be registered only once (RegisterTool errors on a second time), and React's
-- registry may outlive a UI reload, so it's checked before every use: registered if missing, and
-- an existing entry (from before a reload) updated in place.
tool.definition = definition

local function ensureRegistered()
	local existing = nil
	pcall(function() existing = _react.tools[TOOL_NAME] end)
	if existing then
		if existing ~= definition then
			for k, v in pairs(definition) do
				existing[k] = v
			end
		end
		tool.definition = existing
		return
	end
	local ok, err = pcall(react.RegisterTool, definition)
	if not ok then
		log("register: %s", tostring(err))
	end
	tool.definition = definition
end

local function toolStack()
	return game_react_globals.getDefaultToolStackApi()
end

function tool.open()
	ensureRegistered()
	local ts = toolStack()
	if not ts then
		log("no tool stack")
		return
	end
	ts.push(tool.definition, nil, {}, false)
end

function tool.close()
	local ts = toolStack()
	if ts and S.active then
		ts.pop(tool.definition, nil)
	end
end

function tool.isActive()
	return S.active
end

return tool
