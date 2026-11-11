-- Ruler: drawing the measurements, in the tool and outside it.
--
-- The lines (an EdgeRenderable) and the segment labels (a full-screen FloatingLayout placed by
-- world2Screen every step) are built here for both. In the tool, its own action carries them
-- (ruler_tool.lua). Outside it, the measurements are kept (core.stop() leaves them) and shown
-- in whatever action is active, unless hidden with the eye button (ruler_button.script.lua):
-- ruler_replace.script.lua puts lines() into every ActionDescriptor (merged into an
-- EdgeRenderable the action already has) and a FullScreenComponent with Labels into every
-- descriptor that has none (an action takes only one; vanilla, only the town window's layer
-- legend has one). A 3D renderable only draws inside the active action's descriptor
-- (network-wireframe, Parallelism, path-visualizer), and a mod entry plugin can't draw at all
-- (Parallelism, 2026-10-09). subscribe() runs in the action's recipe and redraws the action
-- when what's shown changes: the measurements, the zoom (line width), the eye.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local core = ug_require "imsvale_ruler::/gui/ruler/ruler_core.lua"

local S = core.S
local overlay = {}

local COLOR_LINE = { 1.0, 0.82, 0.2, 1.0 }
local COLOR_LIVE = { 1.0, 0.9, 0.5, 0.85 }
local COLOR_CIRCLE = { 0.35, 0.8, 1.0, 1.0 }
local COLOR_CIRCLE_LIVE = { 0.6, 0.9, 1.0, 0.85 }
local COLOR_MARKER = { 1.0, 1.0, 1.0, 1.0 }
local COLOR_SNAP = { 0.35, 0.95, 0.45, 1.0 }

--------------------------------------------------------------------------------
-- the camera

function overlay.cameraDistance()
	local d = 500
	pcall(function()
		local e, c = api.gui.camera.getEye(), api.gui.camera.getCenter()
		d = math.sqrt((e.x - c.x) ^ 2 + (e.y - c.y) ^ 2 + (e.z - c.z) ^ 2)
	end)
	return d
end

-- lines are drawn wider zoomed out: a new step when the zoom has changed by a quarter
function overlay.zoomStep()
	return math.floor(math.log(math.max(overlay.cameraDistance(), 1)) / math.log(1.25))
end

-- line half width for the current zoom (an edge comes out about twice its width)
local function lineWidth()
	return math.max(0.1, math.min(40, overlay.cameraDistance() * 0.0012))
end

--------------------------------------------------------------------------------
-- lines

local function vec4(c)
	return api.type.Vec4f.new(c[1], c[2], c[3], c[4])
end

-- a straight piece from a to b (heights linear between them)
local function straightEdge(a, b, color, width)
	local len = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
	if len < 0.01 then
		return nil
	end
	local st = api.type.EdgeGeometry.Straight.new()
	st.pos = { api.type.Vec2f.new(a.x, a.y), api.type.Vec2f.new(b.x, b.y) }
	local geom = api.type.EdgeGeometry.new()
	geom.type = api.type.EdgeGeometry.Type.STRAIGHT
	geom.straight = st
	geom.height = api.type.Vec2f.new(a.z, b.z)
	geom.tangent = api.type.Vec2f.new(b.z - a.z, b.z - a.z)
	geom.length = len
	geom.width = width
	local edge = builtin.type.EdgeRenderable.Edge.new(geom)
	edge.colors = { vec4(color) }
	edge.width = width
	edge.offsetZ = 0
	edge.stepSize = math.max(len, 0.1)
	return edge
end

-- a filled square of half size h at p (one straight piece as wide as half its length)
local function marker(p, h, color)
	return straightEdge({ x = p.x - h, y = p.y, z = p.z }, { x = p.x + h, y = p.y, z = p.z }, color, h)
end

-- a level circle around o
local function circleEdge(o, r, color, width)
	if r < 0.05 then
		return nil
	end
	local angle = 2 * math.pi + 0.05
	local arc = api.type.EdgeGeometry.Arc.new()
	arc.center = api.type.Vec2f.new(o.x, o.y)
	arc.radius = r
	arc.startAngle = 0
	arc.angle = angle
	local geom = api.type.EdgeGeometry.new()
	geom.type = api.type.EdgeGeometry.Type.ARC
	geom.arc = arc
	geom.height = api.type.Vec2f.new(o.z, o.z)
	geom.tangent = api.type.Vec2f.new(0, 0)
	geom.length = r * angle
	geom.width = width
	local edge = builtin.type.EdgeRenderable.Edge.new(geom)
	edge.colors = { vec4(color) }
	edge.width = width
	edge.offsetZ = 0
	edge.stepSize = math.max(0.5, 2 * math.pi * r / 128)
	return edge
end

function overlay.buildEdges(view)
	local edges = {}
	local function add(e)
		if e then
			edges[#edges + 1] = e
		end
	end
	local w = lineWidth()
	for _, path in ipairs(view.paths) do
		local color
		if path.circle then
			color = path.live and COLOR_CIRCLE_LIVE or COLOR_CIRCLE
		else
			color = path.live and COLOR_LIVE or COLOR_LINE
		end
		for i = 2, #path.pts do
			add(straightEdge(path.pts[i - 1], path.pts[i], color, w))
		end
	end
	for _, c in ipairs(view.circles) do
		add(circleEdge(c.o, c.r, c.live and COLOR_CIRCLE_LIVE or COLOR_CIRCLE, w))
	end
	for _, p in ipairs(view.markers) do
		add(marker(p, w * 3, COLOR_MARKER))
	end
	if view.snap then
		add(circleEdge(view.snap, w * 8, COLOR_SNAP, w))
	end
	return edges
end

--------------------------------------------------------------------------------
-- labels

function overlay.screenLabels(view)
	if not view or #view.labels == 0 then
		return {}
	end
	-- a FloatingLayoutChild's h / v are fractions of the layout (0..1), world2Screen gives pixels
	local out = {}
	pcall(function()
		local size = api.gui.camera.getSize()
		local w, h = math.max(size.x, 1), math.max(size.y, 1)
		local eye, center = api.gui.camera.getEye(), api.gui.camera.getCenter()
		local dx, dy, dz = center.x - eye.x, center.y - eye.y, center.z - eye.z
		for _, l in ipairs(view.labels) do
			-- in front of the camera only
			if (l.p.x - eye.x) * dx + (l.p.y - eye.y) * dy + (l.p.z - eye.z) * dz > 0 then
				local s = api.gui.camera.world2Screen(api.type.Vec3f.new(l.p.x, l.p.y, l.p.z))
				local fx, fy = s.x / w, s.y / h
				if fx >= 0 and fx <= 1 and fy >= 0 and fy <= 1 then
					out[#out + 1] = { x = fx, y = fy, text = l.text }
				end
			end
		end
	end)
	return out
end

function overlay.labelsKey(labels)
	local parts = {}
	for _, l in ipairs(labels) do
		parts[#parts + 1] = string.format("%.4f,%.4f,%s", l.x, l.y, l.text)
	end
	return table.concat(parts, ";")
end

function overlay.labelsLayout(list)
	local children = {}
	for i, l in ipairs(list) do
		children[#children + 1] = builtin.FloatingLayoutChild{
			h = l.x,
			v = l.y,
			localKey = "label" .. i,
			item = builtin.TextView{
				meta = { class = "imsvale-ruler-label", mouseTransparent = true },
				text = l.text,
			},
		}
	end
	return builtin.FloatingLayout{
		meta = { class = "imsvale-ruler-labels", mouseTransparent = true },
		children = children,
	}
end

--------------------------------------------------------------------------------
-- outside the tool

-- kept measurements shown in other actions: not while the tool is in use (it draws its own)
function overlay.shown()
	return not S.active and S.show and core.hasMeasurements()
end

local zoom = { step = nil }

local function currentKey()
	local shown = overlay.shown()
	if shown then
		zoom.step = overlay.zoomStep()
	end
	return shown and (S.version .. ":" .. tostring(zoom.step)) or "off"
end

-- In an action's recipe (ruler_replace.script.lua's ActionDescriptor wrapper): redraws it when
-- what's shown changes. Hooks are called unconditionally so the calling recipe's hook order
-- stays the same.
function overlay.subscribe()
	local seen = react.useState(currentKey())
	react.onStep(function()
		local ok, key = pcall(currentKey)
		if ok and seen:old() ~= key then
			seen:set(key)
		end
	end)
end

local cache = { key = nil, edges = nil }

-- the edges to add to the active action, or nil
function overlay.lines()
	if not overlay.shown() or not S.view then
		return nil
	end
	local key = currentKey()
	if cache.key ~= key then
		local ok, edges = pcall(overlay.buildEdges, S.view)
		cache.key, cache.edges = key, (ok and #edges > 0) and edges or nil
		if not ok then
			core.log("drawing: %s", tostring(edges))
		end
	end
	return cache.edges
end

-- the labels, mounted in other actions (a FullScreenComponent's recipe): passive, no focus and
-- no mouse
overlay.Labels = react.RegisterRecipe("ImsvaleRulerLabels", function()
	react.setMouseTransparent(true)
	react.setDisableFocusable(true)
	local labels = react.useState({ key = "", list = {} })
	react.onStep(function()
		pcall(function()
			local list = overlay.shown() and overlay.screenLabels(S.view) or {}
			local key = overlay.labelsKey(list)
			if key ~= labels:old().key then
				labels:set({ key = key, list = list })
			end
		end)
	end)
	return overlay.labelsLayout(labels:old().list)
end)

return overlay
