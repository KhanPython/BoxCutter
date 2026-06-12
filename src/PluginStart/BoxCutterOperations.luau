--[[
	BoxCutterOperations - Non-destructive box subtraction using primitives.

	A "cut model" replaces the source part and contains:
	- A "Geometry" folder holding the solid result parts
	- One or more "Cutter" parts: user-placed boxes adopted by the plugin
	  (made invisible and non-physical, outlined with a SelectionBox) that
	  can be moved, rotated, and resized with the standard Studio tools

	The source box dimensions are stored as the BoxCutterSourceSize attribute
	and the source visual properties are stored as BoxCutterProp_* attributes,
	so the cut can be regenerated at any time without losing the original part.
	The model pivot always matches the source part's CFrame.

	regenerate() subtracts the AABB of every cutter (in source-local space)
	from the source box, decomposing the remainder into up to 6 slabs per cut:
	2 along X, then 2 along Z, then 2 along Y within the core.
]]

local CollectionService = game:GetService("CollectionService")

local Constants = require(script.Parent.Constants)

local ATTRS = Constants.Attributes
local MIN_PART_SIZE = Constants.MinPartSize

export type Box = {
	min: Vector3,
	max: Vector3,
}

local BoxCutterOperations = {}

BoxCutterOperations.COPY_PROPERTIES = {
	"Color",
	"Material",
	"MaterialVariant",
	"Transparency",
	"Reflectance",
	"Anchored",
	"CanCollide",
	"CanQuery",
	"CanTouch",
	"CastShadow",
	"CollisionGroup",
}

function BoxCutterOperations.isCutModel(item: Instance): boolean
	return item:IsA("Model") and item:GetAttribute(ATTRS.SourceSize) ~= nil
end

function BoxCutterOperations.isCutter(item: Instance): boolean
	return item:IsA("BasePart")
		and item:GetAttribute(ATTRS.Cutter) == true
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
		if child:IsA("BasePart") and child:GetAttribute(ATTRS.Cutter) == true then
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

-- Persist the source part's visual properties so geometry can be rebuilt
-- even after a cut temporarily removes every solid part.
local function storeProperties(model: Model, source: BasePart)
	for _, prop in BoxCutterOperations.COPY_PROPERTIES do
		local value = (source :: any)[prop]
		if typeof(value) == "EnumItem" then
			value = value.Name
		end
		model:SetAttribute(ATTRS.PropertyPrefix .. prop, value)
	end
end

local function newPartFromStoredProperties(model: Model): Part
	local part = Instance.new("Part")
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for _, prop in BoxCutterOperations.COPY_PROPERTIES do
		local value = model:GetAttribute(ATTRS.PropertyPrefix .. prop)
		if value ~= nil then
			if prop == "Material" then
				local ok, material = pcall(function()
					return (Enum.Material :: any)[value]
				end)
				if ok then
					part.Material = material
				end
			else
				(part :: any)[prop] = value
			end
		end
	end
	return part
end

-- AABB of `cutter` expressed in `sourceCF` local space
local function cutterLocalAABB(sourceCF: CFrame, cutter: BasePart): (Vector3, Vector3)
	local rel = sourceCF:ToObjectSpace(cutter.CFrame)
	local half = cutter.Size / 2
	local x, y, z = rel.XVector, rel.YVector, rel.ZVector
	local extents = Vector3.new(
		math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
		math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
		math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
	)
	return rel.Position - extents, rel.Position + extents
end

-- Subtracts the [cmin, cmax] AABB from `box`, returning the remainder as
-- up to 6 boxes: X slabs span the full box, Z slabs span the clamped X range,
-- Y slabs cover what remains above/below the hole.
local function subtractBox(box: Box, cmin: Vector3, cmax: Vector3): { Box }
	local imin = box.min:Max(cmin)
	local imax = box.max:Min(cmax)
	if imin.X >= imax.X or imin.Y >= imax.Y or imin.Z >= imax.Z then
		return { box }
	end

	local result = {}
	if box.min.X < imin.X then
		table.insert(result, {
			min = box.min,
			max = Vector3.new(imin.X, box.max.Y, box.max.Z),
		})
	end
	if imax.X < box.max.X then
		table.insert(result, {
			min = Vector3.new(imax.X, box.min.Y, box.min.Z),
			max = box.max,
		})
	end
	if box.min.Z < imin.Z then
		table.insert(result, {
			min = Vector3.new(imin.X, box.min.Y, box.min.Z),
			max = Vector3.new(imax.X, box.max.Y, imin.Z),
		})
	end
	if imax.Z < box.max.Z then
		table.insert(result, {
			min = Vector3.new(imin.X, box.min.Y, imax.Z),
			max = Vector3.new(imax.X, box.max.Y, box.max.Z),
		})
	end
	if box.min.Y < imin.Y then
		table.insert(result, {
			min = Vector3.new(imin.X, box.min.Y, imin.Z),
			max = Vector3.new(imax.X, imin.Y, imax.Z),
		})
	end
	if imax.Y < box.max.Y then
		table.insert(result, {
			min = Vector3.new(imin.X, imax.Y, imin.Z),
			max = Vector3.new(imax.X, box.max.Y, imax.Z),
		})
	end
	return result
end

local function subtractFromAll(boxes: { Box }, cmin: Vector3, cmax: Vector3): { Box }
	local result = {}
	for _, box in boxes do
		for _, piece in subtractBox(box, cmin, cmax) do
			table.insert(result, piece)
		end
	end
	return result
end

local MERGE_EPS = 1e-4

local function approxEq(x: number, y: number): boolean
	return math.abs(x - y) <= MERGE_EPS
end

-- Identical extents on two axes (the one named by `skip` is ignored)
local function extentsEqualExcept(a: Box, b: Box, skip: string): boolean
	if skip ~= "X" and not (approxEq(a.min.X, b.min.X) and approxEq(a.max.X, b.max.X)) then
		return false
	end
	if skip ~= "Y" and not (approxEq(a.min.Y, b.min.Y) and approxEq(a.max.Y, b.max.Y)) then
		return false
	end
	if skip ~= "Z" and not (approxEq(a.min.Z, b.min.Z) and approxEq(a.max.Z, b.max.Z)) then
		return false
	end
	return true
end

local function touchesAlong(a: Box, b: Box, axis: string): boolean
	local amin, amax, bmin, bmax
	if axis == "X" then
		amin, amax, bmin, bmax = a.min.X, a.max.X, b.min.X, b.max.X
	elseif axis == "Y" then
		amin, amax, bmin, bmax = a.min.Y, a.max.Y, b.min.Y, b.max.Y
	else
		amin, amax, bmin, bmax = a.min.Z, a.max.Z, b.min.Z, b.max.Z
	end
	return amax + MERGE_EPS >= bmin and bmax + MERGE_EPS >= amin
end

local MERGE_AXES = { "X", "Y", "Z" }

-- Returns the union of `a` and `b` if it is itself a box: identical extents
-- on two axes and contiguous (or overlapping) on the third.
local function tryMerge(a: Box, b: Box): Box?
	for _, axis in MERGE_AXES do
		if extentsEqualExcept(a, b, axis) and touchesAlong(a, b, axis) then
			return { min = a.min:Min(b.min), max = a.max:Max(b.max) }
		end
	end
	return nil
end

-- Greedily coalesces aligned fragments (produced by overlapping cutters)
-- into elongated boxes so fewer parts are generated.
local function mergeBoxes(boxes: { Box }): { Box }
	local changed = true
	while changed do
		changed = false
		local i = 1
		while i <= #boxes do
			local j = i + 1
			while j <= #boxes do
				local merged = tryMerge(boxes[i], boxes[j])
				if merged then
					boxes[i] = merged
					table.remove(boxes, j)
					changed = true
				else
					j += 1
				end
			end
			i += 1
		end
	end
	return boxes
end

-- How a Texture's UV space maps onto each face in part-local coordinates:
-- which axis carries U and V, and whether the texture's origin corner sits
-- on the positive (max) or negative (min) side of that axis. Derived from
-- the viewed-from-outside surface convention (U right, V down); if a face
-- ever tiles misaligned in practice, flipping its FromMax flag is the fix.
local FACE_UV: { [Enum.NormalId]: { U: string, UFromMax: boolean, V: string, VFromMax: boolean } } = {
	[Enum.NormalId.Front] = { U = "X", UFromMax = true, V = "Y", VFromMax = true },
	[Enum.NormalId.Back] = { U = "X", UFromMax = false, V = "Y", VFromMax = true },
	[Enum.NormalId.Right] = { U = "Z", UFromMax = true, V = "Y", VFromMax = true },
	[Enum.NormalId.Left] = { U = "Z", UFromMax = false, V = "Y", VFromMax = true },
	[Enum.NormalId.Top] = { U = "X", UFromMax = false, V = "Z", VFromMax = false },
	[Enum.NormalId.Bottom] = { U = "X", UFromMax = true, V = "Z", VFromMax = false },
}

-- Studs from the source face's texture origin to the fragment face's texture
-- origin along one axis. The source box is centered on the origin, so its
-- min corner is -half and its max corner is +half.
local function originDelta(axis: string, fromMax: boolean, box: Box, half: Vector3): number
	if fromMax then
		return (half :: any)[axis] - (box.max :: any)[axis]
	end
	return (box.min :: any)[axis] + (half :: any)[axis]
end

local function wrapOffset(offset: number, tile: number): number
	return if tile > 0 then offset % tile else offset
end

-- Reads the texture's offset on the uncut source, recording it on first
-- sight so later regenerations re-derive from the original anchor instead
-- of stacking adjustments on top of adjusted values.
local function getBaseOffset(texture: Texture, attr: string, current: number): number
	local base = texture:GetAttribute(attr)
	if typeof(base) ~= "number" then
		base = current
		texture:SetAttribute(attr, base)
	end
	return base :: number
end

-- Shifts every Texture on a fragment so the pattern lines up exactly as it
-- did on the uncut source box. `box` is the fragment in source-local space.
local function applyTextureOffsets(part: BasePart, box: Box, half: Vector3)
	for _, texture in part:GetChildren() do
		if not texture:IsA("Texture") then
			continue
		end
		local map = FACE_UV[texture.Face]
		if not map then
			continue
		end
		local baseU = getBaseOffset(texture, ATTRS.TextureBaseOffsetU, texture.OffsetStudsU)
		local baseV = getBaseOffset(texture, ATTRS.TextureBaseOffsetV, texture.OffsetStudsV)
		texture.OffsetStudsU = wrapOffset(baseU + originDelta(map.U, map.UFromMax, box, half), texture.StudsPerTileU)
		texture.OffsetStudsV = wrapOffset(baseV + originDelta(map.V, map.VFromMax, box, half), texture.StudsPerTileV)
	end
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
	local sourceSize = model:GetAttribute(ATTRS.SourceSize) :: Vector3?
	if typeof(sourceSize) ~= "Vector3" then
		return
	end
	-- Studio's scale tool scales every descendant part but cannot scale an
	-- attribute; GetScale() carries the applied factor, keeping the stored
	-- value a clean "size at scale 1" record while the rebuilt body matches
	-- the scaled cutters.
	sourceSize *= model:GetScale()
	local half = sourceSize / 2
	local sourceCF = model:GetPivot()
	local folder = getGeometryFolder(model)

	local boxes: { Box } = { { min = -half, max = half } }
	for _, cutter in BoxCutterOperations.getCutters(model) do
		local cmin, cmax = cutterLocalAABB(sourceCF, cutter)
		boxes = subtractFromAll(boxes, cmin, cmax)
	end
	boxes = mergeBoxes(boxes)

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
			part = if sample then sample:Clone() else newPartFromStoredProperties(model)
		end
		part.PivotOffset = CFrame.identity
		part.Size = box.max - box.min
		part.CFrame = sourceCF * CFrame.new((box.min + box.max) / 2)
		applyTextureOffsets(part, box, half)
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
	model.Name = part.Name .. "_Cut"
	model:AddTag(Constants.CutModelTag)
	model:SetAttribute(ATTRS.SourceSize, part.Size)
	storeProperties(model, part)

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
	part:SetAttribute(ATTRS.Cutter, true)
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
function BoxCutterOperations.bake(model: Model, shouldUnion: boolean, groupResult: boolean): { Instance }
	local parts = {}
	for _, part in getGeometryParts(model) do
		local clone = part:Clone()
		clone.PivotOffset = CFrame.identity
		for _, texture in clone:GetChildren() do
			if texture:IsA("Texture") then
				texture:SetAttribute(ATTRS.TextureBaseOffsetU, nil)
				texture:SetAttribute(ATTRS.TextureBaseOffsetV, nil)
			end
		end
		table.insert(parts, clone)
	end

	if #parts == 0 then
		model.Parent = nil
		return {}
	end

	local parent = model.Parent
	local results: { Instance }

	if #parts == 1 then
		local single = parts[1]
		single.Name = model.Name
		single.Parent = parent
		results = { single }
	elseif groupResult then
		local container = Instance.new("Model")
		container.Name = model.Name
		for _, part in parts do
			part.Parent = container
		end
		container.Parent = parent
		results = { container }
	else
		results = {}
		for _, part in parts do
			part.Name = model.Name
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
			unionOrErr.Name = model.Name
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
