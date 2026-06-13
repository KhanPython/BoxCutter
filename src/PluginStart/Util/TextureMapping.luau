--[[
	TextureMapping - keeps surface Textures aligned across the cut.

	When the source box is decomposed into fragments, each fragment's Textures
	must shift so the pattern lines up exactly as it did on the uncut source.
	This module reads the original per-texture anchor (recorded once) and the
	face UV convention, then computes the offset for a given fragment.
]]

local Constants = require(script.Parent.Parent.Constants)

local ATTRS = Constants.Attributes

local TextureMapping = {}

-- Fragments are min/max AABBs in source-local space (see BoxMath.Box).
type Box = { min: Vector3, max: Vector3 }

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

-- Reads the texture's (U, V) offset on the uncut source, recording it on first
-- sight so later regenerations re-derive from the original anchor instead of
-- stacking adjustments on top of adjusted values. One Vector2 attribute rather
-- than two numbers - same data, half the Properties clutter.
local function getBaseOffset(texture: Texture): Vector2
	local base = texture:GetAttribute(ATTRS.TextureBaseOffset)
	if typeof(base) ~= "Vector2" then
		base = Vector2.new(texture.OffsetStudsU, texture.OffsetStudsV)
		texture:SetAttribute(ATTRS.TextureBaseOffset, base)
	end
	return base :: Vector2
end

-- Shifts every Texture on a fragment so the pattern lines up exactly as it
-- did on the uncut source box. `box` is the fragment in source-local space.
function TextureMapping.apply(part: BasePart, box: Box, half: Vector3)
	for _, texture in part:GetChildren() do
		if not texture:IsA("Texture") then
			continue
		end
		local map = FACE_UV[texture.Face]
		if not map then
			continue
		end
		local base = getBaseOffset(texture)
		texture.OffsetStudsU = wrapOffset(base.X + originDelta(map.U, map.UFromMax, box, half), texture.StudsPerTileU)
		texture.OffsetStudsV = wrapOffset(base.Y + originDelta(map.V, map.VFromMax, box, half), texture.StudsPerTileV)
	end
end

return TextureMapping
