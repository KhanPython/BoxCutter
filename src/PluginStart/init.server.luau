local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
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
local groupOnBake = Value(true) -- wrap a multi-part bake in a Model; off leaves loose parts
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

-- History model: only USER state lives in the undo history - cutters, the
-- model and its attributes - captured by Studio's own gestures (move, scale,
-- delete) or by our explicit recordings (Add Cutters, Bake). The generated
-- geometry is DERIVED state: a pure function of the cutters, deliberately
-- kept OUT of the history. regenerateQuietly never opens a recording, so
-- rebuilding the cut never creates a waypoint and never clears the redo
-- stack. Undo and redo therefore move only the user state, and
-- onHistoryChanged re-derives every cut model from whatever state history
-- just restored - geometry can never get out of step with its cutters, no
-- matter how the timeline is walked, and every user action stays exactly
-- one waypoint.
--
-- When a Studio gesture happens to hold its recording open while we rebuild
-- (dragging a cutter), the engine captures the rebuild into that waypoint.
-- That is harmless: those geometry deltas travel together with their cutter
-- deltas, and the post-undo re-derivation is idempotent.
local function regenerateQuietly(model: Model): boolean
	local ok, err = pcall(Operations.regenerate, model)
	if not ok then
		warn("BoxCutter: failed to update cut for " .. model:GetFullName() .. " - " .. tostring(err))
	end
	return ok
end

-- Runs `callback` inside a ChangeHistory recording - used only for real user
-- operations (Add Cutters, Bake) that must form a waypoint of their own. The
-- recording is always finished (Commit on success, Cancel on error) so a
-- thrown error can never leave a recording open and block every future one.
-- If a recording cannot begin because a foreign one is open (a Studio
-- gesture or another plugin), the operation is REFUSED: edits made then
-- would fold into that recording instead of forming their own waypoint.
-- Refusing is safe - every caller is a user action that can simply be
-- retried. Never yields.
local function withRecording(name: string, displayName: string, callback: () -> ())
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

-- Hot path: runs every Heartbeat for each watched model, so it scans the
-- children in one pass instead of building a cutter list first.
local function isModelDirty(model: Model, state: { [any]: any }): boolean
	local cutterCount = 0
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child:HasTag(Constants.CutterTag) then
			cutterCount += 1
			local cached = state[child]
			if not cached or cached.cf ~= child.CFrame or cached.size ~= child.Size then
				return true
			end
		end
	end
	return cutterCount ~= state.cutterCount
end

-- After any undo or redo the cutters are authoritative: re-derive every cut
-- model in the place from them, unrecorded (see the history model above).
-- This is what makes a single undo of "delete cutter" bring the hole back:
-- the waypoint only restores the cutter, and the cut is recomputed here.
-- Deferred so the rebuild observes the world AFTER the history deltas have
-- been applied; the deferred thread still resumes before the next Heartbeat
-- sweep, so the watched snapshots are also refreshed in time to not be
-- mistaken for new user edits.
local function onHistoryChanged()
	task.defer(function()
		for _, model in CollectionService:GetTagged(Constants.CutModelTag) do
			if Operations.isCutModel(model) then
				regenerateQuietly(model)
			end
		end
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
	for _, item in newSelection do
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
			-- Models from saves made before the tag existed get tagged on
			-- first contact, so onHistoryChanged can always find them
			model:AddTag(Constants.CutModelTag)
			table.insert(models, model)
		end
	end

	for _, item in resolvedSelection do
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

	-- A model leaving the watch set may still owe a re-derivation: deleting a
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
		regenerateQuietly(model)
	end
end

local function onHeartbeat()
	for model, state in watched do
		if not model.Parent then
			watched[model] = nil
			continue
		end
		if isModelDirty(model, state) then
			if regenerateQuietly(model) then
				watched[model] = snapshotModel(model)
			else
				-- Stop watching so one bad model can't spam errors every frame
				watched[model] = nil
			end
		end
	end
end

local function doToggleTarget()
	-- One button, two jobs. Selecting a different valid part always wins, so
	-- you can retarget in one click without removing first; only when there is
	-- nothing new to target does the button clear the current one.
	local candidate = targetCandidate:get()
	local current = activeTarget:get()
	if candidate and candidate ~= current then
		setTarget(candidate)
	elseif current ~= nil and not current:IsA("Model") then
		-- Only a plain-part target is removable; a cut-model target is cleared
		-- by deselecting it, never by this button (see canRemoveTarget).
		setTarget(nil)
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
		for _, part in pending do
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
	local shouldGroup = groupOnBake:get()

	local results = {}
	withRecording("BoxCutterBake", "Bake Cut Models", function()
		for _, model in models do
			watched[model] = nil
			for _, result in Operations.bake(model, shouldUnion, shouldGroup) do
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

-- A cut-model target is never explicitly removable. Selecting a cut model
-- auto-targets it (see updateSelection), so offering "Remove Target" would be a
-- confusing no-op - the model stays cut and re-selecting it brings the target
-- straight back. Only an explicitly Set plain-part target can be removed.
local canRemoveTarget = Computed(function()
	local current = activeTarget:get()
	return current ~= nil and not current:IsA("Model")
end)

-- The Set/Remove Target button has two modes. When a new valid part is
-- selected it offers "Set Target" (retargeting included); with no new
-- candidate but a removable plain-part target it offers "Remove Target". Color
-- reinforces the mode: blue accent to set, red text to remove.
local targetButtonText = Computed(function()
	if not canSetTarget:get() and canRemoveTarget:get() then
		return "Remove Target"
	end
	return "Set Target"
end)

local canToggleTarget = Computed(function()
	return canSetTarget:get() or canRemoveTarget:get()
end)

local targetButtonBackground = Computed(function()
	return if canSetTarget:get() then Enum.StudioStyleGuideColor.DialogMainButton else Enum.StudioStyleGuideColor.Button
end)

local targetButtonTextColor = Computed(function()
	if canSetTarget:get() then
		return Enum.StudioStyleGuideColor.DialogMainButtonText
	elseif canRemoveTarget:get() then
		return Enum.StudioStyleGuideColor.ErrorText
	end
	return Enum.StudioStyleGuideColor.ButtonText
end)

local canAddCutters = Computed(function()
	return activeTarget:get() ~= nil and #pendingCutters:get() > 0
end)

local addCuttersText = Computed(function()
	return if #pendingCutters:get() > 1 then "Set Cutters" else "Set Cutter"
end)

-- Mirror the Set Target / Bake accent: the blue main-button styling only when
-- cutters can actually be added. Otherwise it stays neutral, so setting a
-- target (which leaves only the target selected) no longer leaves Set Cutters
-- looking like the primary action when there is nothing to add.
local addCuttersBackground = Computed(function()
	return if canAddCutters:get()
		then Enum.StudioStyleGuideColor.DialogMainButton
		else Enum.StudioStyleGuideColor.Button
end)

local addCuttersTextColor = Computed(function()
	return if canAddCutters:get()
		then Enum.StudioStyleGuideColor.DialogMainButtonText
		else Enum.StudioStyleGuideColor.ButtonText
end)

local canBake = Computed(function()
	return #selectedModels:get() > 0
end)

-- Mirror the Set Target accent: the blue main-button background only when the
-- action is actually available, so an enabled Bake reads as the primary thing
-- to do, and a disabled one stays neutral.
local bakeButtonBackground = Computed(function()
	return if canBake:get() then Enum.StudioStyleGuideColor.DialogMainButton else Enum.StudioStyleGuideColor.Button
end)

local bakeButtonTextColor = Computed(function()
	return if canBake:get()
		then Enum.StudioStyleGuideColor.DialogMainButtonText
		else Enum.StudioStyleGuideColor.ButtonText
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
		Image = Constants.PluginImage,

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
				Label({
					Text = statusText,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 2,
				}),

				Button({
					Text = targetButtonText,
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 3,
					Enabled = canToggleTarget,
					Activated = doToggleTarget,
					BackgroundColorStyle = targetButtonBackground,
					TextColorStyle = targetButtonTextColor,
				}),

				Button({
					Text = addCuttersText,
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 4,
					Enabled = canAddCutters,
					Activated = doAddCutters,
					BackgroundColorStyle = addCuttersBackground,
					TextColorStyle = addCuttersTextColor,
				}),

				Checkbox({
					Text = "Show cutter outlines",
					Value = showCutterOutlines,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 5,
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

				Checkbox({
					Text = "Group result into a Model",
					Value = groupOnBake,
					Size = UDim2.new(1, 0, 0, 20),
					LayoutOrder = 9,
				}),

				Button({
					Text = "Bake Selection",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 10,
					Enabled = canBake,
					Activated = doBake,
					BackgroundColorStyle = bakeButtonBackground,
					TextColorStyle = bakeButtonTextColor,
				}),

				Label({
					Text = "Bake removes cutter boxes and attributes placed by the plugin.",
					Size = UDim2.new(1, 0, 0, 30),
					TextSize = 15,
					TextWrapped = true,
					TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
					LayoutOrder = 11,
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
			pluginJanitor:Add(RunService.Heartbeat:Connect(onHeartbeat))
		else
			pluginJanitor:Cleanup()
			table.clear(watched)
		end
	end))

	-- History can be walked at any time, widget open or not, so the re-derive
	-- hooks outlive the widget gate and last for the plugin's whole life.
	local undoConnection = ChangeHistoryService.OnUndo:Connect(onHistoryChanged)
	local redoConnection = ChangeHistoryService.OnRedo:Connect(onHistoryChanged)

	plugin.Unloading:Connect(function()
		pluginJanitor:Cleanup()
		undoConnection:Disconnect()
		redoConnection:Disconnect()
		-- Lives in CoreGui, so nothing else cleans it up on unload
		targetBox:Destroy()
		if targetConnection then
			targetConnection:Disconnect()
			targetConnection = nil
		end
	end)
end
