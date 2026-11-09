-- Ruler: the measurements and everything derived from them, without any UI.
--
-- Lines and polylines (points placed in Line or Poly mode: a line has two points, a further click
-- starts a new one in its place; a polyline ends where it joins a placed point, kept, and the next
-- click starts another) and any number of circles (Radius mode: an origin, then a point fixing the
-- radius). Every placement is pushed on an undo stack (ops), so undo takes back the last one
-- whatever the mode. What's shown (lines, labels, the totals) is derived
-- in core.changed() into S.view, with the current way of measuring (2D, 3D, along the terrain),
-- so switching it re-measures everything placed.

local core = {}

local function log(fmt, ...)
	local args = { ... }
	pcall(function() print("[ruler] " .. string.format(fmt, (table.unpack or unpack)(args))) end)
end
core.log = log

-- true logs what snapping finds: each industry's candidate positions when the tool opens, and
-- every change of snap target
local DEBUG_SNAP = true

local function fmtP(p)
	return p and string.format("(%.1f, %.1f, %.1f)", p.x, p.y, p.z or 0) or "-"
end

core.MODE_LINE, core.MODE_POLY, core.MODE_RADIUS = 1, 2, 3
core.METRIC_2D, core.METRIC_3D, core.METRIC_TERRAIN = 1, 2, 3

-- Snapping: a station or industry snaps while the cursor is within its bounding box (plus a
-- margin), the smallest box winning; one without a box within SNAP_RADIUS of its position. A
-- town snaps within TOWN_RADIUS of its position, and only if nothing else does.
local SNAP_MARGIN = 15
local SNAP_RADIUS = 60
local TOWN_RADIUS = 150
-- placed points snap within this share of the camera distance (at least POINT_SNAP_MIN metres),
-- before anything else
local POINT_SNAP_SHARE = 0.015
local POINT_SNAP_MIN = 1

-- Along the terrain: a height sample about every metre, at most this many per segment (the
-- segment following the cursor is measured again on every move, so it gets fewer).
local MAX_SAMPLES = 4000
local MAX_SAMPLES_LIVE = 1000
-- points kept for drawing a segment along the terrain
local DRAW_POINTS = 200

local S = {
	active = false,
	mode = core.MODE_LINE,
	metric = core.METRIC_2D,
	snap = true,
	noSnapKey = false, -- C held (constructNoSnap)
	points = {}, -- the line or polyline being placed
	lines = {}, -- polylines ended by joining a placed point: { points }
	circles = {}, -- { o = origin, p = point on the circle }
	origin = nil, -- a circle's origin waiting for its radius
	ops = {}, -- undo stack: { kind = "point" | "origin" | "radius", replaced = points a new line replaced }
	cursor = nil, -- the point the next click places (snapped or not), nil off the map
	snapped = nil, -- the target the cursor snapped to
	targets = nil,
	version = 0,
	view = nil,
}
core.S = S

--------------------------------------------------------------------------------
-- small helpers

local function copy(p)
	return p and { x = p.x, y = p.y, z = p.z } or nil
end

local function dist2(a, b)
	return math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
end

local function dist3(a, b)
	return math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
end

local function samePoint(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z) < 0.005
end

function core.groundZ(x, y)
	local z
	pcall(function() z = api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end)
	return z
end

function core.now()
	local t = 0
	pcall(function() t = api.util.getApplicationTime() end)
	return t
end

--------------------------------------------------------------------------------
-- formatting

local function isImperial()
	local imperial = false
	pcall(function()
		imperial = api.util.getAppConfig().distanceSpeedUnit == api.type["enum"].DistanceSpeedUnit.Imperial
	end)
	return imperial
end

-- 1234567 -> "1 234 567"
local function grouped(n)
	local s = tostring(n)
	local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return (out:gsub("^ ", ""))
end

-- one decimal, digits grouped: "1 234.5 m"; imperial: feet, or miles from a mile up
function core.format(metres)
	if metres == nil then
		return ""
	end
	local value, unit = metres, "m"
	if isImperial() then
		value, unit = metres / 0.3048, "ft"
		if value >= 5280 then
			return string.format("%.3f mi", value / 5280)
		end
	end
	local tenths = math.floor(value * 10 + 0.5)
	return string.format("%s.%d %s", grouped(math.floor(tenths / 10)), tenths % 10, unit)
end

--------------------------------------------------------------------------------
-- snap targets

local entity_util = nil

local function positionOf(e)
	local p = nil
	pcall(function()
		entity_util = entity_util or ug_require "::/scripts/entity_util.tl"
		local v = entity_util.getPosition(e)
		if v then
			p = { x = v.x, y = v.y, z = v.z }
		end
	end)
	return p
end

local function bboxOf(e)
	local b = nil
	pcall(function()
		local bv = api.engine.getComponent(e, api.type.ComponentType.BOUNDING_VOLUME)
		if bv and bv.bbox then
			local mn, mx = bv.bbox.min, bv.bbox.max
			if mx.x > mn.x and mx.y > mn.y then
				b = { x0 = mn.x, y0 = mn.y, x1 = mx.x, y1 = mx.y }
			end
		end
	end)
	return b
end

local function nameOf(e)
	local name = nil
	pcall(function() name = api.engine.getComponent(e, api.type.ComponentType.NAME).name end)
	return name
end

-- An industry's possible "one location", for finding the one the game uses (DEBUG_SNAP): the
-- INDUSTRY entity's own position and box, and its construction's (Industry.construction)
-- transform, which the game's celebrations script takes as the industry's position.
local function logIndustry(e)
	local parts = { string.format("industry %d %q", e, tostring(nameOf(e))) }
	local function add(fmt, ...)
		parts[#parts + 1] = string.format(fmt, ...)
	end
	add("entity_util %s", fmtP(positionOf(e)))
	local b = bboxOf(e)
	add("box %s", b and string.format("x %.1f..%.1f y %.1f..%.1f (centre %.1f, %.1f)", b.x0, b.x1, b.y0, b.y1,
		(b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2) or "-")
	local ok, err = pcall(function()
		local ind = api.engine.getComponent(e, api.type.ComponentType.INDUSTRY)
		add("stockList %s", tostring(ind.stockList))
		local c = ind.construction
		add("construction %s", tostring(c))
		local viaSub = api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction(e)
		add("forSubconstruction %s", tostring(viaSub))
		local con = api.engine.getComponent(c, api.type.ComponentType.CONSTRUCTION)
		if con then
			local t = con.transf:getTransl()
			add("construction transl %s", fmtP(t))
			add("file %s", tostring(con.fileName))
			add("%d industries, %d subconstructions, %d stations", #con.industries, #con.subconstructions, #con.stations)
			local cb = bboxOf(c)
			add("construction box %s", cb and string.format("centre %.1f, %.1f, size %.0f x %.0f", (cb.x0 + cb.x1) / 2,
				(cb.y0 + cb.y1) / 2, cb.x1 - cb.x0, cb.y1 - cb.y0) or "-")
		end
	end)
	if not ok then
		add("error %s", tostring(err))
	end
	log("snap: %s", table.concat(parts, "; "))
end

function core.loadTargets()
	local list, counts = {}, {}
	local kinds = {
		{ "town", api.type.ComponentType.TOWN },
		{ "industry", api.type.ComponentType.INDUSTRY },
		{ "station", api.type.ComponentType.STATION_GROUP },
	}
	for _, k in ipairs(kinds) do
		local entities = {}
		local ok, err = pcall(function()
			api.engine.forEachEntityWithComponent(function(e)
				entities[#entities + 1] = e
			end, k[2])
		end)
		if not ok then
			log("targets: %s failed: %s", k[1], tostring(err))
		end
		local n, withBox = 0, 0
		for _, e in ipairs(entities) do
			local b = bboxOf(e)
			local p = positionOf(e)
			if not p and b then
				p = { x = (b.x0 + b.x1) / 2, y = (b.y0 + b.y1) / 2, z = 0 }
			end
			if p then
				list[#list + 1] = { entity = e, kind = k[1], pos = p, bbox = b, name = nameOf(e) }
				if DEBUG_SNAP and k[1] == "industry" then
					logIndustry(e)
				end
				n = n + 1
				if b then
					withBox = withBox + 1
				end
			end
		end
		counts[#counts + 1] = string.format("%s %d/%d (%d with a box)", k[1], n, #entities, withBox)
	end
	S.targets = list
	log("snap targets: %s", table.concat(counts, ", "))
end

local function cameraDistance()
	local d = 500
	pcall(function()
		local e, c = api.gui.camera.getEye(), api.gui.camera.getCenter()
		d = math.sqrt((e.x - c.x) ^ 2 + (e.y - c.y) ^ 2 + (e.z - c.z) ^ 2)
	end)
	return d
end

-- the nearest placed point within reach
local function findPointSnap(x, y)
	local reach = math.max(POINT_SNAP_MIN, cameraDistance() * POINT_SNAP_SHARE)
	local best, bestD = nil, reach
	local function try(p)
		local d = math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2)
		if d <= bestD then
			best, bestD = p, d
		end
	end
	for i, p in ipairs(S.points) do
		if i < #S.points then -- not the last: that would be a zero-length segment
			try(p)
		end
	end
	for _, line in ipairs(S.lines) do
		for _, p in ipairs(line) do
			try(p)
		end
	end
	for _, c in ipairs(S.circles) do
		try(c.o)
		try(c.p)
	end
	if S.origin then
		try(S.origin)
	end
	return best and { kind = "point", pos = best } or nil
end

local function findSnap(x, y)
	local point = findPointSnap(x, y)
	if point then
		return point
	end
	local best, bestScore = nil, nil
	for _, t in ipairs(S.targets or {}) do
		local score = nil
		if t.kind == "town" then
			local d = math.sqrt((x - t.pos.x) ^ 2 + (y - t.pos.y) ^ 2)
			if d <= TOWN_RADIUS then
				score = 1e12 + d
			end
		elseif t.bbox then
			local b = t.bbox
			if x >= b.x0 - SNAP_MARGIN and x <= b.x1 + SNAP_MARGIN and y >= b.y0 - SNAP_MARGIN and y <= b.y1 + SNAP_MARGIN then
				score = (b.x1 - b.x0 + 2 * SNAP_MARGIN) * (b.y1 - b.y0 + 2 * SNAP_MARGIN)
			end
		else
			local d = math.sqrt((x - t.pos.x) ^ 2 + (y - t.pos.y) ^ 2)
			if d <= SNAP_RADIUS then
				score = d * d
			end
		end
		if score and (bestScore == nil or score < bestScore) then
			best, bestScore = t, score
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- measuring

local terrainCache = {}

-- Along the ground from a to b: the length, and points for drawing it.
local function terrainPath(a, b, live)
	local key = not live and string.format("%.3f,%.3f,%.3f,%.3f,%.3f,%.3f", a.x, a.y, a.z, b.x, b.y, b.z) or nil
	if key and terrainCache[key] then
		return terrainCache[key]
	end
	local flat = dist2(a, b)
	local n = math.max(1, math.min(live and MAX_SAMPLES_LIVE or MAX_SAMPLES, math.ceil(flat)))
	local every = math.max(1, math.floor(n / DRAW_POINTS))
	local length, prev = 0, copy(a)
	local pts = { prev }
	for i = 1, n do
		local t = i / n
		local p
		if i == n then
			p = copy(b)
		else
			local x, y = a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
			p = { x = x, y = y, z = core.groundZ(x, y) or (a.z + (b.z - a.z) * t) }
		end
		length = length + dist3(prev, p)
		prev = p
		if i % every == 0 or i == n then
			pts[#pts + 1] = p
		end
	end
	local result = { length = length, pts = pts }
	if key then
		terrainCache[key] = result
	end
	return result
end

-- the length from a to b the current way, and the points to draw it through
local function measure(a, b, live)
	if S.metric == core.METRIC_TERRAIN then
		local r = terrainPath(a, b, live)
		return r.length, r.pts
	elseif S.metric == core.METRIC_3D then
		return dist3(a, b), { a, b }
	end
	return dist2(a, b), { a, b }
end

-- the middle of a drawn path, for its label
local function middle(pts)
	if #pts == 2 then
		local a, b = pts[1], pts[2]
		return { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 }
	end
	return pts[math.floor(#pts / 2) + 1]
end

--------------------------------------------------------------------------------
-- the view: what the UI draws and shows

local function buildView()
	local v = {
		paths = {}, -- { pts = {...}, live = bool, circle = bool }
		circles = {}, -- { o = point, r = horizontal radius, live = bool }
		markers = {}, -- points
		labels = {}, -- { p = point, text = string }
		snap = S.snapped and S.cursor and copy(S.cursor) or nil,
		snapName = S.snapped and S.snapped.name or nil,
		total = nil, -- the polyline's length, with the segment to the cursor
		radius = nil, -- the radius being set, or the last one fixed
	}

	-- the polylines ended earlier
	local lastTotal = nil
	for _, line in ipairs(S.lines) do
		local sum = 0
		for i, p in ipairs(line) do
			v.markers[#v.markers + 1] = p
			if i > 1 then
				local len, pts = measure(line[i - 1], p, false)
				sum = sum + len
				v.paths[#v.paths + 1] = { pts = pts }
				v.labels[#v.labels + 1] = { p = middle(pts), text = core.format(len) }
			end
		end
		lastTotal = sum
	end

	-- the line or polyline being placed
	local total = 0
	for i, p in ipairs(S.points) do
		v.markers[#v.markers + 1] = p
		if i > 1 then
			local len, pts = measure(S.points[i - 1], p, false)
			total = total + len
			v.paths[#v.paths + 1] = { pts = pts }
			v.labels[#v.labels + 1] = { p = middle(pts), text = core.format(len) }
		end
	end
	if #S.points > 0 then
		v.total = total
	else
		v.total = lastTotal
	end
	local drawing = (S.mode == core.MODE_POLY and #S.points > 0) or (S.mode == core.MODE_LINE and #S.points == 1)
	if drawing and S.cursor then
		local len, pts = measure(S.points[#S.points], S.cursor, true)
		v.total = total + len
		v.paths[#v.paths + 1] = { pts = pts, live = true }
		v.labels[#v.labels + 1] = { p = middle(pts), text = core.format(len) }
	end

	-- the circles
	local function addCircle(o, p, live)
		local len, pts = measure(o, p, live)
		v.circles[#v.circles + 1] = { o = o, r = dist2(o, p), live = live }
		v.paths[#v.paths + 1] = { pts = pts, live = live, circle = true }
		v.markers[#v.markers + 1] = o
		v.labels[#v.labels + 1] = { p = middle(pts), text = "r " .. core.format(len) }
		v.radius = len
	end
	for _, c in ipairs(S.circles) do
		addCircle(c.o, c.p, false)
	end
	if S.origin then
		if S.mode == core.MODE_RADIUS and S.cursor then
			addCircle(S.origin, S.cursor, true)
		else
			v.markers[#v.markers + 1] = S.origin
		end
	end

	-- the cursor tooltip
	local value = nil
	if (S.mode == core.MODE_LINE or S.mode == core.MODE_POLY) and #S.points > 0 then
		value = v.total and core.format(v.total)
	elseif S.mode == core.MODE_RADIUS and S.origin then
		value = v.radius and ("r " .. core.format(v.radius))
	end
	if value and v.snapName then
		v.tooltip = value .. "  ·  " .. v.snapName
	else
		v.tooltip = value or v.snapName
	end
	return v
end

function core.changed()
	S.version = S.version + 1
	local ok, view = pcall(buildView)
	if ok then
		S.view = view
	else
		log("view: %s", tostring(view))
	end
end

--------------------------------------------------------------------------------
-- input

local function shiftHeld()
	local held = false
	pcall(function() held = api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE") end)
	return held
end

local lastSnapKey = nil -- DEBUG_SNAP: what was logged last

-- The cursor's point, snapped unless snapping is off or Shift / C is held. Called every frame.
function core.updateCursor()
	local raw = nil
	pcall(function()
		if api.gui.mouse.hasTerrainPosition() then
			local t = api.gui.mouse.getTerrainPosition()
			raw = { x = t.x, y = t.y, z = t.z }
		end
	end)
	local target = nil
	if raw and S.snap and not S.noSnapKey and not shiftHeld() then
		target = findSnap(raw.x, raw.y)
	end
	local p = raw
	if target then
		if target.kind == "point" then
			p = copy(target.pos)
		else
			p = { x = target.pos.x, y = target.pos.y, z = core.groundZ(target.pos.x, target.pos.y) or target.pos.z }
		end
	end
	-- (a placed point's target is a new table every frame: compare by what it is)
	local key = target and (target.kind .. ":" .. tostring(target.entity or fmtP(target.pos))) or (raw and "none" or "off")
	if DEBUG_SNAP and key ~= lastSnapKey then
		lastSnapKey = key
		if target then
			local b = target.bbox
			log("snap: to %s %s %q at %s%s", target.kind, tostring(target.entity), tostring(target.name),
				fmtP(p), b and string.format(", box %.0f x %.0f", b.x1 - b.x0, b.y1 - b.y0) or "")
		elseif raw then
			log("snap: none at %s", fmtP(raw))
		end
	end
	if not samePoint(p, S.cursor) or target ~= S.snapped then
		S.cursor, S.snapped = p, target
		core.changed()
	end
end

function core.place()
	local p = copy(S.cursor)
	if not p then
		return
	end
	if S.mode == core.MODE_LINE and #S.points >= 2 then
		-- a finished line: this click starts a new one (undo brings the old one back)
		S.ops[#S.ops + 1] = { kind = "point", replaced = S.points }
		S.points = { p }
	elseif S.mode == core.MODE_LINE or S.mode == core.MODE_POLY then
		S.points[#S.points + 1] = p
		local op = { kind = "point" }
		-- a polyline joining a placed point ends there
		if S.mode == core.MODE_POLY and #S.points > 1 and S.snapped and S.snapped.kind == "point" then
			S.lines[#S.lines + 1] = S.points
			S.points = {}
			op.ended = true
		end
		S.ops[#S.ops + 1] = op
	elseif S.origin then
		S.circles[#S.circles + 1] = { o = S.origin, p = p }
		S.origin = nil
		S.ops[#S.ops + 1] = { kind = "radius" }
	else
		S.origin = p
		S.ops[#S.ops + 1] = { kind = "origin" }
	end
	core.changed()
end

-- takes back the last placement; false if there was none
function core.undo()
	local op = table.remove(S.ops)
	if not op then
		return false
	end
	if op.kind == "point" then
		if op.ended then
			S.points = table.remove(S.lines) or {}
		end
		table.remove(S.points)
		if op.replaced then
			S.points = op.replaced
		end
	elseif op.kind == "origin" then
		S.origin = nil
	elseif op.kind == "radius" then
		local c = table.remove(S.circles)
		S.origin = c and c.o or nil
	end
	core.changed()
	return true
end

function core.clear()
	S.points, S.lines, S.circles, S.origin, S.ops = {}, {}, {}, nil, {}
	core.changed()
end

function core.setMode(mode)
	S.mode = mode
	core.changed()
end

function core.setMetric(metric)
	S.metric = metric
	core.changed()
end

function core.setSnap(on)
	S.snap = on
	core.changed()
end

-- the tool opened / closed: measurements last only while it's open
function core.start()
	S.active = true
	S.points, S.lines, S.circles, S.origin, S.ops = {}, {}, {}, nil, {}
	S.cursor, S.snapped, S.noSnapKey = nil, nil, false
	terrainCache = {}
	core.loadTargets()
	core.changed()
end

function core.stop()
	S.active = false
	S.points, S.lines, S.circles, S.origin, S.ops = {}, {}, {}, nil, {}
	S.cursor, S.snapped, S.targets = nil, nil, nil
	terrainCache = {}
	core.changed()
end

return core
