--[[
	CutData - serialization of a cut model's source size and visual properties.

	Roblox attributes are strongly typed and cannot hold tables, so a cut
	model's source size and visual properties live in one JSON string attribute.
	Color3/Vector3 have no JSON form, so they are tagged and rebuilt on read;
	numbers, booleans and strings (including a Material enum stored by name)
	serialize as themselves. This module owns both the read/write of that blob
	and rebuilding geometry parts from the stored property snapshot.
]]

local HttpService = game:GetService("HttpService")

local Constants = require(script.Parent.Parent.Constants)

local ATTRS = Constants.Attributes

local CutData = {}

export type Data = { size: Vector3, props: { [string]: any } }

local COPY_PROPERTIES = {
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

local DATA_VERSION = 1

local function encodeValue(value: any): any
	local t = typeof(value)
	if t == "Color3" then
		return { __t = "Color3", r = value.R, g = value.G, b = value.B }
	elseif t == "Vector3" then
		return { __t = "Vector3", x = value.X, y = value.Y, z = value.Z }
	end
	return value
end

local function decodeValue(encoded: any): any
	if type(encoded) == "table" then
		if encoded.__t == "Color3" then
			return Color3.new(encoded.r, encoded.g, encoded.b)
		elseif encoded.__t == "Vector3" then
			return Vector3.new(encoded.x, encoded.y, encoded.z)
		end
		return nil
	end
	return encoded
end

-- Snapshot the source part's visual properties (EnumItems by name) so geometry
-- can be rebuilt even after a cut temporarily removes every solid part.
function CutData.collectProperties(source: BasePart): { [string]: any }
	local props = {}
	for _, prop in COPY_PROPERTIES do
		local value = (source :: any)[prop]
		if typeof(value) == "EnumItem" then
			value = value.Name
		end
		props[prop] = value
	end
	return props
end

function CutData.write(model: Model, size: Vector3, props: { [string]: any })
	local encodedProps = {}
	for name, value in props do
		encodedProps[name] = encodeValue(value)
	end
	model:SetAttribute(
		ATTRS.Data,
		HttpService:JSONEncode({
			version = DATA_VERSION,
			size = encodeValue(size),
			props = encodedProps,
		})
	)
end

-- Reads the cut model's data blob. Returns nil if the model carries no
-- recoverable data (missing or malformed attribute).
function CutData.read(model: Model): Data?
	local raw = model:GetAttribute(ATTRS.Data)
	if type(raw) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local size = decodeValue(decoded.size)
	if typeof(size) ~= "Vector3" then
		return nil
	end
	local props = {}
	if type(decoded.props) == "table" then
		for name, encoded in decoded.props do
			props[name] = decodeValue(encoded)
		end
	end
	return { size = size, props = props }
end

function CutData.newPartFromProps(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for _, prop in COPY_PROPERTIES do
		local value = props[prop]
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

return CutData
