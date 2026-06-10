--[[
	BoxCutterOperations - Non-destructive box subtraction using primitives.

	A "cut model" replaces the source part and contains:
	- A "Geometry" folder holding the solid result parts
	- One or more "Cutter" parts (translucent red boxes) the user can move,
	  rotate, and resize with the standard Studio tools

	The source box dimensions are stored as the BoxCutterSourceSize attribute
	and the source visual properties are stored as BoxCutterProp_* attributes,
	so the cut can be regenerated at any time without losing the original part.
	The model pivot always matches the source part's CFrame.

	regenerate() subtracts the AABB of every cutter (in source-local space)
	from the source box, decomposing the remainder into up to 6 slabs per cut:
	2 along X, then 2 along Z, then 2 along Y within the core.
]]

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
	local sourceCF = model:GetPivot()
	local folder = getGeometryFolder(model)

	local boxes: { Box } = { { min = -sourceSize / 2, max = sourceSize / 2 } }
	for _, cutter in BoxCutterOperations.getCutters(model) do
		local cmin, cmax = cutterLocalAABB(sourceCF, cutter)
		boxes = subtractFromAll(boxes, cmin, cmax)
	end

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
		if not existing[index] then
			part.Parent = folder
		end
	end
	for index = #finalBoxes + 1, #existing do
		existing[index]:Destroy()
	end

	updatePivot(model, sourceCF)
end

-- Converts a plain part into a cut model with one initial cutter.
-- Returns the model and the new cutter.
function BoxCutterOperations.setup(part: BasePart): (Model, BasePart)
	local sourceCF = part.CFrame

	local model = Instance.new("Model")
	model.Name = part.Name .. "_Cut"
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

	local cutter = BoxCutterOperations.addCutter(model)
	BoxCutterOperations.regenerate(model)

	return model, cutter
end

-- Adds a new cutter box centered on the model pivot.
function BoxCutterOperations.addCutter(model: Model): BasePart
	local sourceSize = model:GetAttribute(ATTRS.SourceSize)
	if typeof(sourceSize) ~= "Vector3" then
		sourceSize = Vector3.one
	end
	local scaled = sourceSize * Constants.DefaultCutterScale

	local cutter = Instance.new("Part")
	cutter.Name = Constants.CutterName
	cutter:SetAttribute(ATTRS.Cutter, true)
	cutter.Size = Vector3.new(
		math.max(scaled.X, Constants.MinCutterSize),
		math.max(scaled.Y, Constants.MinCutterSize),
		math.max(scaled.Z, Constants.MinCutterSize)
	)
	cutter.CFrame = model:GetPivot()
	cutter.Color = Constants.CutterColor
	cutter.Transparency = Constants.CutterTransparency
	cutter.Material = Enum.Material.SmoothPlastic
	cutter.TopSurface = Enum.SurfaceType.Smooth
	cutter.BottomSurface = Enum.SurfaceType.Smooth
	cutter.Anchored = true
	cutter.CanCollide = false
	cutter.CanTouch = false
	cutter.CastShadow = false
	cutter.Parent = model

	return cutter
end

-- Removes cutters and all plugin attributes, leaving plain geometry.
-- Returns the resulting instance (part, union, or model).
function BoxCutterOperations.bake(model: Model, shouldUnion: boolean): Instance
	for _, cutter in BoxCutterOperations.getCutters(model) do
		cutter:Destroy()
	end
	for name in model:GetAttributes() do
		if name:sub(1, 9) == "BoxCutter" then
			model:SetAttribute(name, nil)
		end
	end

	local parts = getGeometryParts(model)
	for _, part in parts do
		part.PivotOffset = CFrame.identity
		part.Parent = model
	end
	getGeometryFolder(model):Destroy()

	if shouldUnion and #parts >= 2 then
		local primary = table.remove(parts, 1) :: BasePart
		local ok, unionPart = pcall(function()
			return primary:UnionAsync(parts)
		end)
		if ok and unionPart then
			unionPart.Name = model.Name
			unionPart.Parent = model.Parent
			model:Destroy()
			return unionPart
		end
		warn("BoxCutter: UnionAsync failed for " .. model.Name)
		table.insert(parts, 1, primary)
	end

	if #parts == 1 then
		local single = parts[1]
		single.Name = model.Name
		single.Parent = model.Parent
		model:Destroy()
		return single
	end

	model.PrimaryPart = parts[1]
	return model
end

return BoxCutterOperations
