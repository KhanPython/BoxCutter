--[[
	BoxMath - pure axis-aligned box geometry for the cut decomposition.

	A Box is a min/max AABB expressed in the source part's local space. These
	helpers compute a cutter's local AABB, subtract holes from a set of boxes
	(decomposing each cut into up to 6 slabs), and greedily merge the aligned
	fragments back into elongated boxes. Everything here is pure: no Roblox
	instances are mutated and no module state is kept.
]]

local BoxMath = {}

export type Box = {
	min: Vector3,
	max: Vector3,
}

-- AABB of `cutter` expressed in `sourceCF` local space
function BoxMath.cutterLocalAABB(sourceCF: CFrame, cutter: BasePart): (Vector3, Vector3)
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

function BoxMath.subtractFromAll(boxes: { Box }, cmin: Vector3, cmax: Vector3): { Box }
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
function BoxMath.mergeBoxes(boxes: { Box }): { Box }
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

return BoxMath
