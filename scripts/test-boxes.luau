--[[
	Standalone regression test for the AABB subtraction + merge algorithm in
	BoxCutterOperations. Run with: lune run scripts/test-boxes

	The algorithm functions are copied here with a stub vector type because
	the plugin module requires Roblox `script` globals. Keep them in sync
	with src/PluginStart/BoxCutterOperations.luau when the math changes.
]]

-- Stub Vector3: only what the algorithm uses (.X/.Y/.Z, Min, Max)
local Vec = {}
Vec.__index = Vec

local function vec(x: number, y: number, z: number)
	return setmetatable({ X = x, Y = y, Z = z }, Vec)
end

function Vec.Min(self, o)
	return vec(math.min(self.X, o.X), math.min(self.Y, o.Y), math.min(self.Z, o.Z))
end

function Vec.Max(self, o)
	return vec(math.max(self.X, o.X), math.max(self.Y, o.Y), math.max(self.Z, o.Z))
end

type Box = { min: any, max: any }

--- Algorithm under test (mirror of BoxCutterOperations) ---

local function subtractBox(box: Box, cmin, cmax): { Box }
	local imin = box.min:Max(cmin)
	local imax = box.max:Min(cmax)
	if imin.X >= imax.X or imin.Y >= imax.Y or imin.Z >= imax.Z then
		return { box }
	end

	local result = {}
	if box.min.X < imin.X then
		table.insert(result, { min = box.min, max = vec(imin.X, box.max.Y, box.max.Z) })
	end
	if imax.X < box.max.X then
		table.insert(result, { min = vec(imax.X, box.min.Y, box.min.Z), max = box.max })
	end
	if box.min.Z < imin.Z then
		table.insert(result, { min = vec(imin.X, box.min.Y, box.min.Z), max = vec(imax.X, box.max.Y, imin.Z) })
	end
	if imax.Z < box.max.Z then
		table.insert(result, { min = vec(imin.X, box.min.Y, imax.Z), max = vec(imax.X, box.max.Y, box.max.Z) })
	end
	if box.min.Y < imin.Y then
		table.insert(result, { min = vec(imin.X, box.min.Y, imin.Z), max = vec(imax.X, imin.Y, imax.Z) })
	end
	if imax.Y < box.max.Y then
		table.insert(result, { min = vec(imin.X, imax.Y, imin.Z), max = vec(imax.X, box.max.Y, imax.Z) })
	end
	return result
end

local function subtractFromAll(boxes: { Box }, cmin, cmax): { Box }
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

local function tryMerge(a: Box, b: Box): Box?
	for _, axis in MERGE_AXES do
		if extentsEqualExcept(a, b, axis) and touchesAlong(a, b, axis) then
			return { min = a.min:Min(b.min), max = a.max:Max(b.max) }
		end
	end
	return nil
end

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

--- Test helpers ---

local failures = 0

local function check(condition: boolean, message: string)
	if not condition then
		failures += 1
		print("FAIL: " .. message)
	end
end

local function pointInAABB(p, bmin, bmax): boolean
	return p.X > bmin.X and p.X < bmax.X and p.Y > bmin.Y and p.Y < bmax.Y and p.Z > bmin.Z and p.Z < bmax.Z
end

local function boxesOverlap(a: Box, b: Box): boolean
	return a.min.X < b.max.X - MERGE_EPS
		and b.min.X < a.max.X - MERGE_EPS
		and a.min.Y < b.max.Y - MERGE_EPS
		and b.min.Y < a.max.Y - MERGE_EPS
		and a.min.Z < b.max.Z - MERGE_EPS
		and b.min.Z < a.max.Z - MERGE_EPS
end

-- Monte Carlo: every sampled point must be inside the result iff it is
-- inside the source and outside every cutter. Also: no result overlap.
local function verify(label: string, source: Box, cutters: { { any } })
	local boxes: { Box } = { source }
	for _, cutter in cutters do
		boxes = subtractFromAll(boxes, cutter[1], cutter[2])
	end
	local beforeMerge = #boxes
	boxes = mergeBoxes(boxes)
	print(`{label}: {beforeMerge} boxes before merge, {#boxes} after`)
	check(#boxes <= beforeMerge, label .. ": merge must not increase box count")

	for i = 1, #boxes do
		for j = i + 1, #boxes do
			check(not boxesOverlap(boxes[i], boxes[j]), label .. ": result boxes " .. i .. "," .. j .. " overlap")
		end
	end

	local rng = math.random
	math.randomseed(42)
	for _ = 1, 20000 do
		local p = vec(
			source.min.X + rng() * (source.max.X - source.min.X),
			source.min.Y + rng() * (source.max.Y - source.min.Y),
			source.min.Z + rng() * (source.max.Z - source.min.Z)
		)
		local inCutter = false
		for _, cutter in cutters do
			if pointInAABB(p, cutter[1], cutter[2]) then
				inCutter = true
				break
			end
		end
		local inResult = false
		for _, box in boxes do
			if pointInAABB(p, box.min, box.max) then
				inResult = true
				break
			end
		end
		if inCutter then
			check(not inResult, label .. ": point inside a cutter is still solid")
		else
			-- Points on internal box faces report false; skip near-boundary noise
			local nearBoundary = false
			for _, box in boxes do
				for _, axis in MERGE_AXES do
					local minv = (box.min :: any)[axis]
					local maxv = (box.max :: any)[axis]
					local pv = (p :: any)[axis]
					if math.abs(pv - minv) < 1e-3 or math.abs(pv - maxv) < 1e-3 then
						nearBoundary = true
					end
				end
			end
			if not nearBoundary then
				check(inResult, label .. ": point outside cutters lost from solid")
			end
		end
		if failures > 5 then
			break
		end
	end
end

--- Cases ---

local source: Box = { min = vec(-2, -2, -2), max = vec(2, 2, 2) }

verify("single centered cutter", source, {
	{ vec(-1, -1, -1), vec(1, 1, 1) },
})

verify("cutter through full box", source, {
	{ vec(-1, -3, -1), vec(1, 3, 1) },
})

verify("two overlapping cutters", source, {
	{ vec(-1, -1, -1), vec(1, 1, 1) },
	{ vec(0, -1, -1), vec(3, 1, 1) },
})

verify("identical stacked cutters", source, {
	{ vec(-1, -1, -1), vec(1, 1, 1) },
	{ vec(-1, -1, -1), vec(1, 1, 1) },
})

verify("cutter swallows everything", source, {
	{ vec(-3, -3, -3), vec(3, 3, 3) },
})

verify("non-overlapping cutters", source, {
	{ vec(-1.5, -3, -1.5), vec(-0.5, 3, -0.5) },
	{ vec(0.5, -3, 0.5), vec(1.5, 3, 1.5) },
})

verify("three overlapping cutters", source, {
	{ vec(-1, -1, -1), vec(1, 1, 1) },
	{ vec(0, 0, 0), vec(1.5, 1.5, 1.5) },
	{ vec(-1.5, -0.5, -0.5), vec(0.5, 0.5, 0.5) },
})

if failures == 0 then
	print("All box math tests passed")
else
	print(failures .. " failure(s)")
	error("test failures", 0)
end
