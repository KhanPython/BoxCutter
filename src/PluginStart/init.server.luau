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
local selectedTarget = Value(nil) -- first selected: plain block Part or cut model
local pendingCutters = Value({}) -- subsequently selected plain block Parts
local selectedModels = Value({}) -- every cut model in the selection
local selectionCount = Value(0) -- raw selection size, for status messages
local pluginJanitor = Janitor.new()

-- Live tracking: cut models being watched for cutter movement.
-- model -> { cutterCount: number, [BasePart]: { cf: CFrame, size: Vector3 } }
local watched: { [Model]: { [any]: any } } = {}

-- One recording spans a whole drag session; committed once cutters go idle
-- so live edits land in a single undo waypoint.
local liveRecording: string? = nil
local lastDirtyClock = 0

local function finishLiveRecording()
	if liveRecording then
		ChangeHistoryService:FinishRecording(liveRecording, Enum.FinishRecordingOperation.Commit)
		liveRecording = nil
	end
end

-- Runs `callback` inside a ChangeHistory recording. The recording is always
-- finished (Commit on success, Cancel on error) so a thrown error can never
-- leave a recording open and block every future one. If a recording can't
-- begin, the operation still runs - undo granularity degrades, the plugin
-- keeps working.
local function withRecording(name: string, displayName: string, callback: () -> ())
	finishLiveRecording()

	local recording = ChangeHistoryService:TryBeginRecording(name, displayName)
	if not recording then
		local blocked = ChangeHistoryService:IsRecordingInProgress()
		warn(
			"BoxCutter: Could not begin ChangeHistory recording"
				.. (blocked and " (another recording is in progress - restart Studio if this persists)" or "")
		)
	end

	local ok, err = pcall(callback)

	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not ok then
		warn("BoxCutter: " .. tostring(err))
	end
end

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
	local plainParts, models = {}, {}
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
		elseif item:IsA("BasePart") then
			table.insert(plainParts, item)
		end
	end

	-- An already-cut model in the selection is always the target, regardless
	-- of selection order; every plain part then becomes a cutter. Otherwise
	-- the first selected block Part is the target and the rest are cutters.
	local target = nil
	local pending = {}
	if #models > 0 then
		target = models[1]
		pending = plainParts
	else
		for _, part in plainParts do
			if target == nil and part:IsA("Part") and part.Shape == Enum.PartType.Block then
				target = part
			else
				table.insert(pending, part)
			end
		end
	end

	selectedTarget:set(target)
	pendingCutters:set(pending)
	selectedModels:set(models)
	selectionCount:set(#newSelection)

	-- Watch selected models for live cutter movement
	local newWatched = {}
	for _, model in models do
		newWatched[model] = watched[model] or snapshotModel(model)
	end
	watched = newWatched
end

local function onHeartbeat()
	local anyDirty = false
	for model, state in watched do
		if not model.Parent then
			watched[model] = nil
			continue
		end
		if isModelDirty(model, state) then
			anyDirty = true
			if not liveRecording then
				liveRecording = ChangeHistoryService:TryBeginRecording("BoxCutterLive", "Move Cut Box")
			end
			local ok, err = pcall(Operations.regenerate, model)
			if not ok then
				-- Stop watching so one bad model can't spam errors every frame
				watched[model] = nil
				warn("BoxCutter: live update failed: " .. tostring(err))
				continue
			end
			watched[model] = snapshotModel(model)
		end
	end

	if anyDirty then
		lastDirtyClock = os.clock()
	elseif liveRecording and os.clock() - lastDirtyClock > Constants.LiveCommitDelay then
		finishLiveRecording()
	end
end

local function doAddCutters()
	local target = selectedTarget:get()
	local pending = pendingCutters:get()
	if not target or #pending == 0 then
		return
	end

	local adopted = {}
	withRecording("BoxCutterAdd", "Add Cutters", function()
		local model = if target:IsA("Model") then target else Operations.setup(target)
		for _, part in ipairs(pending) do
			table.insert(adopted, Operations.adoptCutter(model, part))
		end
		Operations.regenerate(model)
	end)

	-- Keep the new cutters selected so they can be moved right away
	if #adopted > 0 then
		Selection:Set(adopted)
	end
end

local function doBake()
	local models = selectedModels:get()
	if #models == 0 then
		return
	end

	local shouldUnion = unionOnBake:get()

	local results = {}
	withRecording("BoxCutterBake", "Bake Cut Models", function()
		for _, model in ipairs(models) do
			watched[model] = nil
			table.insert(results, Operations.bake(model, shouldUnion))
		end
	end)

	if #results > 0 then
		Selection:Set(results)
	end

	updateSelection()
end

local canAddCutters = Computed(function()
	return selectedTarget:get() ~= nil and #pendingCutters:get() > 0
end)

local statusText = Computed(function()
	local target = selectedTarget:get()
	local pendingCount = #pendingCutters:get()
	local modelCount = #selectedModels:get()

	if target == nil then
		if selectionCount:get() > 0 then
			return "No valid target: the part to cut must be a block Part"
		end
		return "Select the part to cut first"
	end

	local text = "Target: " .. target.Name
	if pendingCount > 0 then
		text ..= ", " .. pendingCount .. (pendingCount == 1 and " cutter to add" or " cutters to add")
	elseif modelCount > 1 then
		text ..= " (+" .. (modelCount - 1) .. " more cut models)"
	end
	return text
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
					Text = "Add Cutters",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 3,
					Enabled = canAddCutters,
					Activated = doAddCutters,
				}),

				Label({
					Text = "Select the part to cut first, then Ctrl+click the parts to cut with and press Add Cutters. Move, rotate, resize, or delete cutters at any time - the cut updates live while this widget is open.",
					Size = UDim2.new(1, 0, 0, 90),
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
			finishLiveRecording()
			pluginJanitor:Cleanup()
			table.clear(watched)
		end
	end))

	plugin.Unloading:Connect(function()
		finishLiveRecording()
		pluginJanitor:Cleanup()
	end)
end
