local Plugin = script:FindFirstAncestorWhichIsA("Plugin")
local Fusion = require(Plugin:FindFirstChild("Fusion", true))

local PluginComponents = script.Parent
local StudioComponents = PluginComponents.Parent:FindFirstChild("StudioComponents")
local StudioComponentsUtil = StudioComponents:FindFirstChild("Util")

local unwrap = require(StudioComponentsUtil.unwrap)
local types = require(StudioComponentsUtil.types)

local Observer = Fusion.Observer
local Hydrate = Fusion.Hydrate

local COMPONENT_ONLY_PROPERTIES = {
	"ToolTip",
	"Name",
	"Image",
	"Toolbar",
	"Active",
}

type ToolbarProperties = {
	Active: types.CanBeState<boolean>?,
	Toolbar: PluginToolbar,
	ToolTip: string,
	Image: string,
	Name: string,
	[any]: any,
}

return function(props: ToolbarProperties)
	local toolbarButton = props.Toolbar:CreateButton(props.Name, props.ToolTip, props.Image)

	if props.Active ~= nil then
		local initialActive = unwrap(props.Active)
		toolbarButton:SetActive(initialActive)
		-- A state object unwraps to something other than itself; follow it
		if initialActive ~= props.Active then
			Plugin.Unloading:Connect(Observer(props.Active):onChange(function()
				toolbarButton:SetActive(unwrap(props.Active, false))
			end))
		end
	end

	local hydrateProps = table.clone(props)
	for _, propertyName in COMPONENT_ONLY_PROPERTIES do
		hydrateProps[propertyName] = nil
	end

	return Hydrate(toolbarButton)(hydrateProps)
end
