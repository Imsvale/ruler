-- Ruler: the button in the HUD's mod button area (top left). Pressing it starts the tool
-- (ruler_tool.lua) with its options window right under the button; pressing it again, or the
-- window's close button, ends it. The button follows the tool, also when something else ends it.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl"
local tool = ug_require "imsvale_ruler::/gui/ruler/ruler_tool.lua"

local BUTTON_ID = "imsvale_ruler.button"

local Button = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "ImsvaleRulerButton", function()
	local on = react.useState(tool.isActive() and 1 or 0)
	local selfRef = react.useSelfRef()

	react.onStep(function()
		local want = tool.isActive() and 1 or 0
		if on:old() ~= want then
			on:set(want)
		end
	end)

	-- The root must be a layout (the button area refuses anything else: "Recipe child must be
	-- a layout"), and a layout takes no margin: the margin is on a Component inside it.
	return builtin.BoxLayout{
		children = {
			builtin.Component{
				meta = { class = "imsvale-ruler-button-area" },
				layout = builtin.BoxLayout{
					children = {
						builtin.ToggleButton{
							meta = {
								id = BUTTON_ID,
								tooltip = _("Ruler"),
							},
							value = on:old(),
							onValueChange = function(value)
								on:set(value)
								if value == 1 then
									-- the window right under the button
									local pos = nil
									pcall(function()
										local p = selfRef:get():getPosition(0.0, 0.0)
										local size = api.gui.byId.getSize(BUTTON_ID)
										pos = { x = p.x, y = p.y + size.y }
									end)
									tool.open(pos)
								else
									tool.close()
								end
							end,
							content = builtin.ImageView{
								path = "imsvale_ruler::/gui/ruler.tga",
								scaling = builtin.type.ImageViewScaling.AutoFit,
							},
						},
					},
				},
			},
		},
	}
end)

function data()
	return { Button = Button }
end
