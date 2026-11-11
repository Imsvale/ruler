-- Puts the kept measurements (ruler_overlay.lua) into every ActionDescriptor, so they show
-- whatever tool is active, and with none. Runs through the react-replacement-config
-- (ruler_replace.res.lua), before any recipe; recipes can't be replaced afterwards. Modelled on
-- path-visualizer's path_visualizer_replace.script.lua.
--
-- An ActionDescriptor takes at most one EdgeRenderable and one FullScreenComponent (a second
-- of either is fatal). So both are wrapped as well:
-- * An EdgeRenderable built for a descriptor gets our lines added to its edges, and the
--   descriptor then gets no second one.
-- * A FullScreenComponent can't be merged (it mounts one recipe). Where an action has one, it
--   gets no labels from us (vanilla: only the town window's layer legend; the Ruler's own tool).
-- Children are built before their descriptor, so flags set by these wrappers tell the next
-- descriptor.
--
-- Chained, not replacing: each wrapper calls what was in the recipe's replacement slot when it
-- was installed (_react.recipeReplace[id], another mod's wrapper), and only where that's empty
-- the game's original (_react.originalRecipeFn[id]). See the mods folder's
-- docs/COMPATIBILITY.md. Installed early (order -1000), so ours is an inner wrapper: what outer
-- wrappers build passes through ours before our descriptor wrapper decides.
--
-- The overlay module is looked up on every call, not once here: a UI reload loads the modules
-- afresh, and these wrappers (installed once, at startup) would otherwise keep the old ones.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"

local OVERLAY = "imsvale_ruler::/gui/ruler/ruler_overlay.lua"

local function log(msg)
	print("[ruler] " .. msg)
end

local function overlay()
	local ok, m = pcall(ug_require, OVERLAY)
	if ok and type(m) == "table" then
		return m
	end
	return nil
end

local function isParams(arg)
	return type(arg) == "table" and not arg.is_react_ref_info and not arg.is_react_style_info
end

local function copyOf(t)
	local copy = {}
	for k, v in pairs(t) do copy[k] = v end
	return copy
end

-- Vanilla children lists can have nil holes (`cond and node or nil`): compacted. Named entries
-- are kept as they are (the line window's action has `lineViewer = lineViewer`).
local function compact(list)
	local out, maxIndex = {}, 0
	for k, v in pairs(list or {}) do
		if type(k) == "number" then
			if k > maxIndex then maxIndex = k end
		else
			out[k] = v
		end
	end
	for i = 1, maxIndex do
		if list[i] ~= nil then out[#out + 1] = list[i] end
	end
	return out
end

-- Recipes are called as Recipe(params) or Recipe(ref, params): wraps fn(params) around the
-- original. Explicit arities: the script sandbox lacks parts of the base library.
local function wrapParams(original, fn)
	return function(a, b, c)
		if c ~= nil then
			return original(a, b, fn(c))
		elseif b ~= nil then
			return original(a, fn(b))
		end
		return original(fn(a))
	end
end

local loggedError = false
local function logOnce(what, err)
	if not loggedError then
		loggedError = true
		log(what .. ": " .. tostring(err))
	end
end

local function doReplace(replacementApi)
	local ok, internal = pcall(function() return _react end)
	if not ok or type(internal) ~= "table" then internal = {} end
	-- what each recipe calls through to: the wrapper already installed, else the original
	local function previous(recipe)
		local id = react.GetRecipeId(recipe)
		if not id then return nil end
		return (internal.recipeReplace and internal.recipeReplace[id])
			or (internal.originalRecipeFn and internal.originalRecipeFn[id])
	end
	local previousAD = previous(builtin.ActionDescriptor)
	local previousER = previous(builtin.EdgeRenderable)
	local previousFSC = previous(builtin.FullScreenComponent)
	if not previousAD or not previousER or not previousFSC then
		log("ActionDescriptor, EdgeRenderable or FullScreenComponent not reachable: no measurements outside the tool")
		return
	end

	local erBuilt, fscBuilt = false, false -- built since the last descriptor
	local own = false -- building our own: leave it alone

	replacementApi.ReplaceRecipe(builtin.EdgeRenderable, wrapParams(previousER, function(params)
		if own or not isParams(params) then return params end
		erBuilt = true
		local o = overlay()
		local okLines, lines = pcall(function() return o and o.lines() end)
		if not okLines or not lines then return params end
		local okMerge, merged = pcall(function()
			local copy = copyOf(params)
			local edges = compact(params.edges)
			for _, e in ipairs(lines) do edges[#edges + 1] = e end
			copy.edges = edges
			return copy
		end)
		return okMerge and merged or params
	end))

	replacementApi.ReplaceRecipe(builtin.FullScreenComponent, wrapParams(previousFSC, function(params)
		if not own and isParams(params) then
			fscBuilt = true
		end
		return params
	end))

	replacementApi.ReplaceRecipe(builtin.ActionDescriptor, wrapParams(previousAD, function(params)
		if not isParams(params) then return params end
		local hadER, hadFSC = erBuilt, fscBuilt
		erBuilt, fscBuilt = false, false
		local o = overlay()
		if not o then return params end
		local okSub, err = pcall(o.subscribe)
		if not okSub then logOnce("subscribe", err) end
		local okShown, shown = pcall(o.shown)
		if not okShown or not shown then return params end
		local lines = nil
		if not hadER then
			local okLines, l = pcall(o.lines)
			lines = okLines and l or nil
		end
		if not lines and hadFSC then return params end
		local okInject, injected = pcall(function()
			local copy = copyOf(params)
			local children = compact(params.children)
			own = true
			if lines then
				children[#children + 1] = builtin.EdgeRenderable{ edges = lines, ignoreDepth = true }
			end
			if not hadFSC then
				children[#children + 1] = builtin.FullScreenComponent{ recipe = o.Labels, param = {} }
			end
			own = false
			copy.children = children
			return copy
		end)
		own = false
		if not okInject then
			logOnce("inject", injected)
			return params
		end
		return injected
	end))
end

function data()
	return { doReplace = doReplace }
end
