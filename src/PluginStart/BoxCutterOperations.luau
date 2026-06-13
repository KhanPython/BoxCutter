--[[
	BoxCutterOperations - Non-destructive box subtraction using primitives.

	A "cut model" replaces the source part and contains:
	- A "Geometry" folder holding the solid result parts
	- One or more "Cutter" parts: user-placed boxes adopted by the plugin
	  (made invisible and non-physical, outlined with a SelectionBox) that
	  can be moved, rotated, and resized with the standard Studio tools

	The source box dimensions and visual properties are serialized into a
	single BoxCutterData string attribute (see Util/CutData), so the cut can be
	regenerated at any time without losing the original part. The model pivot
	always matches the source part's CFrame.

	regenerate() subtracts the AABB of every cutter (in source-local space)
	from the source box, decomposing the remainder into up to 6 slabs per cut;
	the box geometry itself lives in Util/BoxMath and texture realignment in
	Util/TextureMapping.
]]

local CollectionService = game:GetService("CollectionService")

local Constants = require(script.Parent.Constants)
local Util = script.Parent.Util
local BoxMath = require(Util.BoxMath)
local CutData = require(Util.CutData)
local TextureMapping = require(Util.TextureMapping)

local MIN_PART_SIZE = Constants.MinPartSize

export type Box = BoxMath.Box

local BoxCutterOperations = {}

function BoxCutterOperations.isCutModel(item: Instance): boolean
	return item:IsA("Model") and item:GetAttribute(Constants.Attributes.Data) ~= nil
end

function BoxCutterOperations.isCutter(item: Instance): boolean
	return item:IsA("BasePart")
		and item:HasTag(Constants.CutterTag)
		and item.Parent ~= nil
		and BoxCutterOperations.isCutModel(item.Parent)
end

function BoxCutterOperations.isGeometryPart(item: Instance): boolean
	local folder = item.Parent
	if not (item:IsA("BasePart") and folder and folder.Name == Constants.GeometryFolderName) then
		return false
	end
	local model = folder.Parent
	return model ~= nil and BoxCutterOperations.isCutModel(model)
end

function BoxCutterOperations.getCutters(model: Model): { BasePart }
	local cutters = {}
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child:HasTag(Constants.CutterTag) then
			table.insert(cutters, child)
		end
	end
	return cutters
end

local function getGeometryFolder(model: Model): Folder
	local folder = model:FindFirstChild(Constants.GeometryFolderName)
	if not folder or not folder:IsA("Folder") then
		folder = Instance.new("Folder")
		folder.Name = Constants.GeometryFolderName
		folder.Parent = model
	end
	return folder :: Folder
end

local function getGeometryParts(model: Model): { BasePart }
	local parts = {}
	for _, child in getGeometryFolder(model):GetChildren() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end
	return parts
end

local function updatePivot(model: Model, sourceCF: CFrame)
	local primary = getGeometryFolder(model):FindFirstChildWhichIsA("BasePart")
	if primary then
		primary.PivotOffset = primary.CFrame:ToObjectSpace(sourceCF)
		model.PrimaryPart = primary
	else
		model.PrimaryPart = nil
		model.WorldPivot = sourceCF
	end
end

-- Recomputes the solid geometry from the current cutters. Reuses existing
-- geometry parts where possible so user re-styling (color, material) sticks.
function BoxCutterOperations.regenerate(model: Model)
	local data = CutData.read(model)
	if not data then
		return
	end
	-- Studio's scale tool scales every descendant part but cannot scale an
	-- attribute; GetScale() carries the applied factor, keeping the stored
	-- value a clean "size at scale 1" record while the rebuilt body matches
	-- the scaled cutters.
	local sourceSize = data.size * model:GetScale()
	local half = sourceSize / 2
	local sourceCF = model:GetPivot()
	local folder = getGeometryFolder(model)

	local boxes: { Box } = { { min = -half, max = half } }
	for _, cutter in BoxCutterOperations.getCutters(model) do
		local cmin, cmax = BoxMath.cutterLocalAABB(sourceCF, cutter)
		boxes = BoxMath.subtractFromAll(boxes, cmin, cmax)
	end
	boxes = BoxMath.mergeBoxes(boxes)

	local finalBoxes = {}
	for _, box in boxes do
		local size = box.max - box.min
		if size.X >= MIN_PART_SIZE and size.Y >= MIN_PART_SIZE and size.Z >= MIN_PART_SIZE then
			table.insert(finalBoxes, box)
		end
	end

	local existing = getGeometryParts(model)
	local sample = existing[1]

	for index, box in finalBoxes do
		local part = existing[index]
		if not part then
			part = if sample then sample:Clone() else CutData.newPartFromProps(data.props)
		end
		part.PivotOffset = CFrame.identity
		part.Size = box.max - box.min
		part.CFrame = sourceCF * CFrame.new((box.min + box.max) / 2)
		TextureMapping.apply(part, box, half)
		if not existing[index] then
			part.Parent = folder
		end
	end
	-- Parent to nil instead of destroying so undo can restore these parts
	for index = #finalBoxes + 1, #existing do
		existing[index].Parent = nil
	end

	updatePivot(model, sourceCF)
end

-- Converts a plain part into a cut model with no cutters yet.
function BoxCutterOperations.setup(part: BasePart): Model
	local sourceCF = part.CFrame

	local model = Instance.new("Model")
	model.Name = part.Name .. Constants.CutModelSuffix
	model:AddTag(Constants.CutModelTag)
	CutData.write(model, part.Size, CutData.collectProperties(part))

	local folder = Instance.new("Folder")
	folder.Name = Constants.GeometryFolderName
	folder.Parent = model

	local solid = part:Clone()
	solid.Name = "Solid"
	solid.PivotOffset = CFrame.identity
	solid.Parent = folder

	model.Parent = part.Parent
	part.Parent = nil

	updatePivot(model, sourceCF)

	return model
end

-- Adopts a user-placed part as a cutter: invisible, non-physical, and
-- outlined with a SelectionBox so the cut region stays visible. Anything the
-- part carried (Textures, Decals, welds, scripts, ...) is removed - a cutter
-- is pure geometry and stray children would linger invisibly inside the cut
-- model. Removal is parent-to-nil so undo can restore them.
function BoxCutterOperations.adoptCutter(model: Model, part: BasePart, outlineVisible: boolean?): BasePart
	part.Name = Constants.CutterName
	part:AddTag(Constants.CutterTag)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = model

	local hasOutline = false
	for _, child in part:GetChildren() do
		if child:HasTag(Constants.CutterBoxTag) then
			hasOutline = true
		else
			child.Parent = nil
		end
	end

	if not hasOutline then
		local box = Instance.new("SelectionBox")
		box.Name = Constants.CutterBoxName
		box:AddTag(Constants.CutterBoxTag)
		box.Color3 = Constants.CutterColor
		box.SurfaceColor3 = Constants.CutterColor
		box.SurfaceTransparency = 0.92
		box.LineThickness = 0.02
		box.Visible = outlineVisible ~= false
		box.Adornee = part
		box.Parent = part
	end

	return part
end

-- Shows or hides the outline adorn on every cutter in the place. A view
-- preference, so callers should not wrap it in a ChangeHistory recording.
function BoxCutterOperations.setOutlinesVisible(visible: boolean)
	for _, box in CollectionService:GetTagged(Constants.CutterBoxTag) do
		local parent = box.Parent
		if box:IsA("SelectionBox") and parent and BoxCutterOperations.isCutter(parent) then
			box.Visible = visible
		end
	end
end

-- Bakes the cut into plain geometry and returns the resulting instances:
-- a single part, a union, a model of parts, or - with `groupResult` off -
-- the loose parts themselves. Empty if the model had no geometry.
--
-- The result is built from CLONES and the cut model is then parented to nil
-- in one step, cutters and all. Undo therefore only has to reverse a single
-- parent change (plus delete the clones) to bring the model back exactly as
-- it was - reparenting cutters and geometry piecemeal proved unreliable:
-- Studio restored only part of the structure on undo. The model is never
-- destroyed, so undo can always resurrect it.
-- The baked name is the model's name with the "_Cut" suffix stripped, so the
-- result inherits the source part's original name. Respects renames: whatever
-- the model is called in the explorer (minus the suffix) is what bakes out.
local function bakedName(model: Model): string
	local suffix = Constants.CutModelSuffix
	local name = model.Name
	if #suffix > 0 and name:sub(-#suffix) == suffix then
		return name:sub(1, #name - #suffix)
	end
	return name
end

function BoxCutterOperations.bake(model: Model, shouldUnion: boolean, groupResult: boolean): { Instance }
	local parts = {}
	for _, part in getGeometryParts(model) do
		local clone = part:Clone()
		clone.PivotOffset = CFrame.identity
		for _, texture in clone:GetChildren() do
			if texture:IsA("Texture") then
				texture:SetAttribute(Constants.Attributes.TextureBaseOffset, nil)
			end
		end
		table.insert(parts, clone)
	end

	if #parts == 0 then
		model.Parent = nil
		return {}
	end

	local parent = model.Parent
	local name = bakedName(model)
	local results: { Instance }

	if #parts == 1 then
		local single = parts[1]
		single.Name = name
		single.Parent = parent
		results = { single }
	elseif groupResult then
		local container = Instance.new("Model")
		container.Name = name
		for _, part in parts do
			part.Name = name
			part.Parent = container
		end
		container.Parent = parent
		results = { container }
	else
		results = {}
		for _, part in parts do
			part.Name = name
			part.Parent = parent
			table.insert(results, part)
		end
	end

	if shouldUnion and #parts >= 2 then
		local primary = table.remove(parts, 1) :: BasePart
		local ok, unionOrErr = pcall(function()
			return primary:UnionAsync(parts)
		end)
		if ok and unionOrErr then
			unionOrErr.Name = name
			unionOrErr.Parent = parent
			for _, result in results do
				result.Parent = nil
			end
			results = { unionOrErr }
		else
			-- The un-unioned parts are already parented, so the bake still
			-- succeeds; the user just gets separate parts instead of one union.
			warn(
				"BoxCutter: UnionAsync failed for " .. model.Name .. (if ok then "" else " - " .. tostring(unionOrErr))
			)
		end
	end

	model.Parent = nil
	return results
end

return BoxCutterOperations
