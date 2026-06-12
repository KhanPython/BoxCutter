local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")

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
local doNothing = Fusion.doNothing

local widgetsEnabled = Value(false)
local unionOnBake = Value(false)
local showCutterOutlines = Value(true)
local target = Value(nil) -- instance chosen via Set Target: block Part or cut model
local targetAncestryClock = Value(0) -- bumped whenever the target's ancestry changes
local selectedPlainParts = Value({}) -- plain BaseParts in the selection
local selectedModels = Value({}) -- every cut model in the selection
local selectionCount = Value(0) -- raw selection size, for status messages
local pluginJanitor = Janitor.new()

-- The first valid target in the selection: an existing cut model wins
-- (selecting a cutter resolves to its model), otherwise the first plain
-- block Part.
local targetCandidate = Computed(function()
	local models = selectedModels:get()
	if #models > 0 then
		return models[1]
	end
	for _, part in selectedPlainParts:get() do
		if part:IsA("Part") and part.Shape == Enum.PartType.Block then
			return part
		end
	end
	return nil
	-- doNothing: these are user-owned workspace instances, never ours to destroy
end, doNothing)

-- The live target: the chosen instance while it is actually in the
-- DataModel. The reference is intentionally kept when the instance leaves -
-- bake, deletion, and undo all reparent to nil rather than destroy - so an
-- undo that resurrects the instance restores the target (and its outline)
-- with no bookkeeping, purely as derived state. Everything downstream gates
-- on this, never on `target` directly, so a dead target can never be
-- operated on.
local activeTarget = Computed(function()
	targetAncestryClock:get() -- re-evaluate whenever the target's ancestry changes
	local instance = target:get()
	return if instance and instance:IsDescendantOf(game) then instance else nil
end, doNothing)

-- Selected plain parts become cutters; the target itself never does.
local pendingCutters = Computed(function()
	local currentTarget = activeTarget:get()
	local pending = {}
	for _, part in selectedPlainParts:get() do
		if part ~= currentTarget then
			table.insert(pending, part)
		end
	end
	return pending
end, doNothing)

local targetConnection: RBXScriptConnection? = nil
local function setTarget(newTarget: Instance?)
	if targetConnection then
		targetConnection:Disconnect()
		targetConnection = nil
	end
	target:set(newTarget)
	if newTarget then
		targetConnection = newTarget.AncestryChanged:Connect(function()
			targetAncestryClock:set(targetAncestryClock:get() + 1)
		end)
	end
end

-- Live tracking: cut models being watched for cutter movement.
-- model -> { cutterCount: number, [BasePart]: { cf: CFrame, size: Vector3 } }
local watched: { [Model]: { [any]: any } } = {}

-- History model: EVERY change is captured in a ChangeHistory recording.
-- Roblox undo is delta-based - each waypoint stores old/new values captured
-- at recording time - so unrecorded edits make later waypoints restore onto
-- state they never observed (that is how cutters went missing after a bake
-- undo). To keep the history clean, a whole drag session coalesces into one
-- recording committed once the cutters go idle; and while Studio's own
-- move/scale gesture holds the single global recording, our regeneration
-- folds into that same waypoint, so undoing the cutter move restores the
-- cut in the same step.
local liveRecording: string? = nil
local lastDirtyClock = 0

local function finishLiveRecording()
	if liveRecording then
		local recording = liveRecording
		liveRecording = nil
		-- pcall: a stale identifier (e.g. after a plugin hot reload) must not
		-- abort the caller, or the next recording could never begin
		local ok = pcall(function()
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end)
		if not ok then
			-- A recording that fails to finish stays open and silently absorbs
			-- every later edit, so no new waypoints form and undo applies stale
			-- deltas onto state they never observed. Unrecoverable from a
			-- plugin; the user must know.
			warn("BoxCutter: failed to commit a live recording - undo may be unreliable until Studio restarts")
		end
	end
end

-- Runs `callback` inside a ChangeHistory recording. The recording is always
-- finished (Commit on success, Cancel on error) so a thrown error can never
-- leave a recording open and block every future one. If a recording cannot
-- begin because a foreign one is open (a Studio gesture, another plugin, or
-- a recording stuck after a failed finish), the operation is REFUSED: edits
-- made then would fold into that recording and never form a waypoint of
-- their own, so a later undo would apply an older waypoint's deltas onto
-- state it never observed (cutters and attributes vanish). Refusing is safe
-- - every caller is a user action that can simply be retried. Never yields.
local function withRecording(name: string, displayName: string, callback: () -> ())
	finishLiveRecording()
	local recording = ChangeHistoryService:TryBeginRecording(name, displayName)

	if not recording and ChangeHistoryService:IsRecordingInProgress() then
		warn(
			'BoxCutter: skipped "'
				.. displayName
				.. '" - another change recording is in progress. Retry; if this persists, restart Studio.'
		)
		return
	end

	local ok, err = pcall(callback)

	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	else
		pcall(function()
			ChangeHistoryService:SetWaypoint("BoxCutter: " .. displayName)
		end)
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

-- Undo/redo restores cutters AND geometry together - they were captured in
-- the same waypoint - so the watched snapshots must be refreshed without
-- regenerating. Treating the restored cutter transforms as a user edit would
-- commit a brand-new waypoint on top of the undone state, and any new
-- waypoint erases the redo stack: undo would work once and redo never would.
-- Deferred because the snapshot must observe the world AFTER the history
-- deltas have been applied, regardless of when the event fires relative to
-- them; the deferred thread still resumes before the next Heartbeat sweep.
local function resyncWatched()
	task.defer(function()
		for model in watched do
			if model.Parent then
				watched[model] = snapshotModel(model)
			else
				watched[model] = nil
			end
		end
	end)
end

local suppressSelectionEvents = false

local function updateSelection()
	if suppressSelectionEvents then
		return
	end
	local newSelection = Selection:Get()

	-- Geometry fragments are ephemeral - the next regeneration destroys and
	-- rebuilds them - so selecting one is a trap: any manual edit silently
	-- evaporates. Redirect fragment selections to their owning cut model,
	-- mirroring Studio's model-selection convention.
	local resolvedSelection, seenResolved = {}, {}
	local needsRedirect = false
	for _, item in ipairs(newSelection) do
		local resolved: Instance = item
		if Operations.isGeometryPart(item) then
			resolved = item.Parent.Parent :: Model
			needsRedirect = true
		end
		if not seenResolved[resolved] then
			seenResolved[resolved] = true
			table.insert(resolvedSelection, resolved)
		end
	end
	if needsRedirect then
		suppressSelectionEvents = true
		Selection:Set(resolvedSelection)
		suppressSelectionEvents = false
	end

	local plainParts, models = {}, {}
	local seenModels = {}

	local function addModel(model: Model)
		if not seenModels[model] then
			seenModels[model] = true
			table.insert(models, model)
		end
	end

	for _, item in ipairs(resolvedSelection) do
		if Operations.isCutModel(item) then
			addModel(item)
		elseif Operations.isCutter(item) then
			addModel(item.Parent :: Model)
		elseif item:IsA("BasePart") and not item:IsA("Terrain") then
			table.insert(plainParts, item)
		end
	end

	selectedPlainParts:set(plainParts)
	selectedModels:set(models)
	selectionCount:set(#resolvedSelection)

	-- Selecting an existing cut model - directly or via one of its cutters -
	-- makes it the target. It is already a cut model, so retargeting is never
	-- destructive, and it keeps the target outline in lockstep with what the
	-- user clicked. Plain parts still require an explicit Set Target, since a
	-- selected part is ambiguous: future target or pending cutter.
	if models[1] and models[1] ~= target:get() then
		setTarget(models[1])
	end

	-- Watch selected models for live cutter movement
	local newWatched = {}
	for _, model in models do
		newWatched[model] = watched[model] or snapshotModel(model)
	end

	-- A model leaving the watch set may still owe a regeneration: deleting a
	-- cutter empties the selection, which lands here before Heartbeat ever
	-- sees the model as dirty - without this catch-up the hole stays cut.
	local dropped = {}
	for model, state in watched do
		if not newWatched[model] and model.Parent and isModelDirty(model, state) then
			table.insert(dropped, model)
		end
	end
	watched = newWatched

	for _, model in dropped do
		withRecording("BoxCutterCatchUp", "Update Cut", function()
			Operations.regenerate(model)
		end)
	end
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
				liveRecording = ChangeHistoryService:TryBeginRecording("BoxCutterLive", "Update Cut")
				if not liveRecording and not ChangeHistoryService:IsRecordingInProgress() then
					-- Nothing would capture the change; mutating now would
					-- desync the history. Retry next frame. (A foreign
					-- recording - usually Studio's own drag gesture - does
					-- capture our changes, folding the cut into the same
					-- undo step as the cutter move.)
					continue
				end
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

local function doSetTarget()
	local candidate = targetCandidate:get()
	if candidate then
		setTarget(candidate)
	end
end

local function doAddCutters()
	local currentTarget = activeTarget:get()
	local pending = pendingCutters:get()
	if not currentTarget or #pending == 0 then
		return
	end

	local adopted = {}
	local model: Model? = nil
	withRecording("BoxCutterAdd", "Add Cutters", function()
		model = if currentTarget:IsA("Model") then currentTarget else Operations.setup(currentTarget)
		for _, part in ipairs(pending) do
			table.insert(adopted, Operations.adoptCutter(model :: Model, part, showCutterOutlines:get()))
		end
		Operations.regenerate(model :: Model)
	end)

	-- setup() replaces a plain-part target with its cut model; keep the
	-- target pointing at the live instance
	if model and model ~= currentTarget and model:IsDescendantOf(game) then
		setTarget(model)
	end

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
			local result = Operations.bake(model, shouldUnion)
			if result then
				table.insert(results, result)
			end
		end
	end)

	if #results > 0 then
		Selection:Set(results)
	end

	updateSelection()
end

local canSetTarget = Computed(function()
	local candidate = targetCandidate:get()
	return candidate ~= nil and candidate ~= activeTarget:get()
end)

local canAddCutters = Computed(function()
	return activeTarget:get() ~= nil and #pendingCutters:get() > 0
end)

local statusText = Computed(function()
	local currentTarget = activeTarget:get()
	local candidate = targetCandidate:get()
	local pendingCount = #pendingCutters:get()

	if currentTarget == nil then
		if candidate then
			return 'Press Set Target to cut "' .. candidate.Name .. '"'
		elseif selectionCount:get() > 0 then
			return "No valid target: select a block Part or cut model"
		end
		return "Select the part to cut, then press Set Target"
	end

	local text = "Target: " .. currentTarget.Name
	if pendingCount > 0 then
		text ..= ", " .. pendingCount .. (pendingCount == 1 and " cutter to add" or " cutters to add")
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

				Button({
					Text = "Set Target",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 3,
					Enabled = canSetTarget,
					Activated = doSetTarget,
				}),

				MainButton({
					Text = "Add Cutters",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 4,
					Enabled = canAddCutters,
					Activated = doAddCutters,
				}),

				Checkbox({
					Text = "Show cutter outlines",
					Value = showCutterOutlines,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 5,
				}),

				Label({
					Text = "Select a block Part or cut model and press Set Target, then select the parts to cut with and press Add Cutters. Move, rotate, resize, or delete cutters at any time - the cut updates live while this widget is open.",
					Size = UDim2.new(1, 0, 0, 90),
					TextSize = 15,
					TextWrapped = true,
					TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
					LayoutOrder = 6,
				}),

				Title({
					Text = "Baking",
					LayoutOrder = 7,
				}),

				Checkbox({
					Text = "Union result",
					Value = unionOnBake,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 8,
				}),

				Button({
					Text = "Bake Selection",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 9,
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
					LayoutOrder = 10,
				}),
			},
		}),
	})

	-- Outline-only SelectionBox marking the current target. Parented to
	-- CoreGui so it never saves into the place, shows in the Explorer, or
	-- touches the undo history. Adorns the live target itself - selecting a
	-- cut model retargets to it (see updateSelection), so the box always
	-- frames the model operations will act on, and undo-resurrection of the
	-- target restores the outline for free.
	local targetBox = New("SelectionBox")({
		Name = "BoxCutterTargetBox",
		Color3 = Constants.TargetColor,
		LineThickness = 0.05,
		Adornee = Computed(function()
			if not widgetsEnabled:get() then
				return nil
			end
			return activeTarget:get()
		end, doNothing),
		Parent = CoreGui,
	})

	-- Outline visibility is a view preference: applied outside any recording
	-- so toggling it never creates an undo waypoint.
	Observer(showCutterOutlines):onChange(function()
		Operations.setOutlinesVisible(showCutterOutlines:get())
	end)

	plugin.Unloading:Connect(Observer(widgetsEnabled):onChange(function()
		if widgetsEnabled:get() then
			task.spawn(updateSelection)
			pluginJanitor:Add(Selection.SelectionChanged:Connect(updateSelection))
			pluginJanitor:Add(ChangeHistoryService.OnUndo:Connect(resyncWatched))
			pluginJanitor:Add(ChangeHistoryService.OnRedo:Connect(resyncWatched))
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
		-- Lives in CoreGui, so nothing else cleans it up on unload
		targetBox:Destroy()
		if targetConnection then
			targetConnection:Disconnect()
			targetConnection = nil
		end
	end)
end
