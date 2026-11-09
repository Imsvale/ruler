-- Ruler probe: answers the open questions in docs/design.md. Read-only, changes nothing in the save.
-- Paste into the in-game console (it has no dofile). Output goes to the game log (stdout.txt), lines "[ruler-probe]".
-- Hold Shift while pressing Enter in the console to see whether IA_PRECISION_MODE reads as active.

local function p(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
	print("[ruler-probe] " .. table.concat(parts, " "))
end

local function section(name, fn)
	local ok, err = pcall(fn)
	if not ok then p(name .. " failed: " .. tostring(err)) end
end

-- 1. The engine's length formatter: which arguments it takes, when it switches to km, how many decimals.
section("formatLength", function()
	for _, v in ipairs({ 12.345, 999.6, 1000, 1234.567, 12345.678 }) do
		local a = api.util.formatLength(v)
		local b, c, d = "-", "-", "-"
		pcall(function() b = api.util.formatLength(v, 0) end)
		pcall(function() c = api.util.formatLength(v, 2) end)
		pcall(function() d = api.util.formatLength(v, 2, true) end)
		p(string.format("%.3f", v), "| ()", a, "| (0)", b, "| (2)", c, "| (2, true)", d)
	end
	p("distanceSpeedUnit", api.util.getAppConfig().distanceSpeedUnit)
end)

-- 2. Snap targets: does entity_util load here, and what positions does it give?
local entity_util
section("entity_util", function()
	entity_util = ug_require "::/scripts/entity_util.tl"
	p("entity_util loaded:", entity_util ~= nil)
end)

local function firstFew(componentType, label)
	section(label, function()
		local n = 0
		api.engine.forEachEntityWithComponent(function(e)
			n = n + 1
			if n <= 3 then
				local pos = "-"
				pcall(function()
					local v = entity_util.getPosition(e)
					pos = string.format("(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
				end)
				local bbox = "-"
				pcall(function()
					local bv = api.engine.getComponent(e, api.type.ComponentType.BOUNDING_VOLUME)
					bbox = string.format("(%.1f, %.1f)-(%.1f, %.1f)", bv.bbox.min.x, bv.bbox.min.y, bv.bbox.max.x, bv.bbox.max.y)
				end)
				local name = "-"
				pcall(function() name = api.engine.getComponent(e, api.type.ComponentType.NAME).name end)
				p(label, e, name, "pos", pos, "bbox", bbox)
			end
		end, componentType)
		p(label, "count", n)
	end)
end

firstFew(api.type.ComponentType.TOWN, "town")
firstFew(api.type.ComponentType.INDUSTRY, "industry")
firstFew(api.type.ComponentType.STATION_GROUP, "station group")

-- 3. Terrain under the cursor (move the mouse over the map before pressing Enter) and its height.
section("terrain", function()
	if api.gui.mouse.hasTerrainPosition() then
		local t = api.gui.mouse.getTerrainPosition()
		local h = api.engine.terrain.getHeightAt(api.type.Vec2f.new(t.x, t.y))
		p(string.format("cursor (%.3f, %.3f, %.3f), getHeightAt %.3f", t.x, t.y, t.z, h))
	else
		p("no terrain position under the cursor")
	end
end)

-- 4. Shift as "hold to disable snapping".
section("precision", function()
	p("IA_PRECISION_MODE active:", api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE"))
end)

-- 5. The tool stack, as a mod would reach it.
section("tool stack", function()
	local globals = ug_require "::/gui/main/game_react_globals.tl"
	local ts = globals.getDefaultToolStackApi()
	p("tool stack api:", ts ~= nil)
	if ts then
		local tool, key = ts.getActiveTool()
		p("active tool:", tool and tool.name, key)
	end
end)
