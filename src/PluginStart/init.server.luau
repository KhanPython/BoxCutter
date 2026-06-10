local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local Components = script.Parent.Components
local Packages = script.Parent.Packages

local PluginComponents = Components:FindFirstChild("PluginComponents")
local Widget = require(PluginComponents.Widget)
local Toolbar = require(PluginComponents.Toolbar)
local ToolbarButton = require(PluginComponents.ToolbarButton)

local StudioComponents = Components:FindFirstChild("StudioComponents")
local ScrollFrame = require(StudioComponents.ScrollFrame)
local MainButton = require(StudioComponents.MainButton)
local Button = require(StudioComponents.Button)
local Checkbox = require(StudioComponents.Checkbox)
local Label = require(StudioComponents.Label)
local Title = require(StudioComponents.Title)

local Fusion = require(Packages.Fusion)
local Janitor = require(Packages.Janitor)

local Constants = require(script.Constants)
local Operations = require(script.BoxCutterOperations)

local New = Fusion.New
local Value = Fusion.Value
local Children = Fusion.Children
local OnChange = Fusion.OnChange
local OnEvent = Fusion.OnEvent
local Observer = Fusion.Observer
local Computed = Fusion.Computed

local widgetsEnabled = Value(false)
local unionOnBake = Value(false)
local selectedParts = Value({}) -- plain block Parts that can become cut models
local selectedModels = Value({}) -- existing cut models (or their geometry/cutters)
local pluginJanitor = Janitor.new()

-- Live tracking: cut models being watched for cutter movement.
-- model -> { cutterCount: number, [BasePart]: { cf: CFrame, size: Vector3 } }
local watched: { [Model]: { [any]: any } } = {}

local function snapshotModel(model: Model): { [any]: any }
	local cutters = Operations.getCutters(model)
	local state: { [any]: any } = { cutterCount = #cutters }
	for _, cutter in cutters do
		state[cutter] = { cf = cutter.CFrame, size = cutter.Size }
	end
	return state
end

local function isModelDirty(model: Model, state: { [any]: any }): boolean
	local cutters = Operations.getCutters(model)
	if #cutters ~= state.cutterCount then
		return true
	end
	for _, cutter in cutters do
		local cached = state[cutter]
		if not cached or cached.cf ~= cutter.CFrame or cached.size ~= cutter.Size then
			return true
		end
	end
	return false
end

local function updateSelection()
	local newSelection = Selection:Get()
	local parts, models = {}, {}
	local seenModels = {}

	local function addModel(model: Model)
		if not seenModels[model] then
			seenModels[model] = true
			table.insert(models, model)
		end
	end

	for _, item in ipairs(newSelection) do
		if Operations.isCutModel(item) then
			addModel(item)
		elseif Operations.isCutter(item) then
			addModel(item.Parent :: Model)
		elseif Operations.isGeometryPart(item) then
			addModel(item.Parent.Parent :: Model)
		elseif item:IsA("Part") and item.Shape == Enum.PartType.Block then
			table.insert(parts, item)
		end
	end

	selectedParts:set(parts)
	selectedModels:set(models)

	-- Watch selected models for live cutter movement
	local newWatched = {}
	for _, model in models do
		newWatched[model] = watched[model] or snapshotModel(model)
	end
	watched = newWatched
end

local function onHeartbeat()
	for model, state in watched do
		if not model.Parent then
			watched[model] = nil
			continue
		end
		if isModelDirty(model, state) then
			-- Append to the dragger's waypoint so live updates don't flood undo
			local recording = ChangeHistoryService:TryBeginRecording("BoxCutterLive", "Box Cutter Live Update")
			Operations.regenerate(model)
			if recording then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.AppendToLast)
			end
			watched[model] = snapshotModel(model)
		end
	end
end

local function doAddCutBox()
	local parts = selectedParts:get()
	local models = selectedModels:get()
	if #parts == 0 and #models == 0 then
		return
	end

	local recording = ChangeHistoryService:TryBeginRecording("BoxCutterAdd", "Add Cut Box")
	if not recording then
		warn("BoxCutter: Could not begin ChangeHistory recording")
		return
	end

	local newCutters = {}

	for _, part in ipairs(parts) do
		local _, cutter = Operations.setup(part)
		table.insert(newCutters, cutter)
	end

	for _, model in ipairs(models) do
		local cutter = Operations.addCutter(model)
		Operations.regenerate(model)
		table.insert(newCutters, cutter)
	end

	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)

	if #newCutters > 0 then
		Selection:Set(newCutters)
	end
end

local function doBake()
	local models = selectedModels:get()
	if #models == 0 then
		return
	end

	local shouldUnion = unionOnBake:get()

	local recording = ChangeHistoryService:TryBeginRecording("BoxCutterBake", "Bake Cut Models")
	if not recording then
		warn("BoxCutter: Could not begin ChangeHistory recording")
		return
	end

	local results = {}
	for _, model in ipairs(models) do
		watched[model] = nil
		table.insert(results, Operations.bake(model, shouldUnion))
	end

	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)

	if #results > 0 then
		Selection:Set(results)
	end

	updateSelection()
end

local hasSelection = Computed(function()
	return #selectedParts:get() > 0 or #selectedModels:get() > 0
end)

local statusText = Computed(function()
	local partCount = #selectedParts:get()
	local modelCount = #selectedModels:get()
	if partCount == 0 and modelCount == 0 then
		return "No parts selected"
	end
	local segments = {}
	if partCount > 0 then
		table.insert(segments, partCount .. (partCount == 1 and " part" or " parts"))
	end
	if modelCount > 0 then
		table.insert(segments, modelCount .. (modelCount == 1 and " cut model" or " cut models"))
	end
	return table.concat(segments, ", ") .. " selected"
end)

do
	local pluginToolbar = Toolbar({
		Name = "Box Cutter",
	})

	ToolbarButton({
		Toolbar = pluginToolbar,
		ClickableWhenViewportHidden = true,
		Name = "Box Cutter",
		ToolTip = "Open Box Cutter widget",
		Image = "",

		[OnEvent("Click")] = function()
			widgetsEnabled:set(not widgetsEnabled:get())
		end,
	})

	Widget({
		Id = "BoxCutterWidget",
		Name = "Box Cutter v" .. Constants.Version,

		InitialDockTo = Enum.InitialDockState.Right,
		InitialEnabled = false,
		ForceInitialEnabled = false,
		FloatingSize = Vector2.new(250, 300),
		MinimumSize = Vector2.new(250, 250),

		Enabled = widgetsEnabled,
		[OnChange("Enabled")] = function(isEnabled)
			widgetsEnabled:set(isEnabled)
		end,

		[Children] = ScrollFrame({
			Size = UDim2.fromScale(1, 1),

			CanvasScaleConstraint = Enum.ScrollingDirection.X,

			UILayout = New("UIListLayout")({
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 7),
			}),

			UIPadding = New("UIPadding")({
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 10),
				PaddingTop = UDim.new(0, 10),
			}),

			[Children] = {
				Title({
					Text = "Cutting",
					LayoutOrder = 1,
				}),

				Label({
					Text = statusText,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 2,
				}),

				MainButton({
					Text = "Add Cut Box",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 3,
					Enabled = hasSelection,
					Activated = doAddCutBox,
				}),

				Label({
					Text = "Move, rotate, or resize the red cutter boxes with the standard Studio tools. The cut updates live while this widget is open. Delete a cutter to remove its cut.",
					Size = UDim2.new(1, 0, 0, 60),
					TextSize = 15,
					TextWrapped = true,
					TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
					LayoutOrder = 4,
				}),

				Title({
					Text = "Baking",
					LayoutOrder = 5,
				}),

				Checkbox({
					Text = "Union result",
					Value = unionOnBake,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 6,
				}),

				Button({
					Text = "Bake Selection",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 7,
					Enabled = Computed(function()
						return #selectedModels:get() > 0
					end),
					Activated = doBake,
				}),

				Label({
					Text = "Bake removes cutter boxes and attributes placed by the plugin.",
					Size = UDim2.new(1, 0, 0, 30),
					TextSize = 15,
					TextWrapped = true,
					TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
					LayoutOrder = 8,
				}),
			},
		}),
	})

	plugin.Unloading:Connect(Observer(widgetsEnabled):onChange(function()
		if widgetsEnabled:get() then
			task.spawn(updateSelection)
			pluginJanitor:Add(Selection.SelectionChanged:Connect(updateSelection))
			pluginJanitor:Add(RunService.Heartbeat:Connect(onHeartbeat))
		else
			pluginJanitor:Cleanup()
			table.clear(watched)
		end
	end))

	plugin.Unloading:Connect(function()
		pluginJanitor:Cleanup()
	end)
end
