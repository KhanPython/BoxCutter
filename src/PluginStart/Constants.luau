return {
	Version = "0.4.1",
	PluginAssetId = 73159461276495,
	PluginImage = "rbxassetid://121545053856429",

	-- Smallest dimension a generated solid part may have on any axis
	MinPartSize = 0.05,

	-- Cutters are invisible; this colors their SelectionBox outline
	CutterColor = Color3.fromRGB(255, 80, 80),

	-- Color of the SelectionBox outline marking the current target
	TargetColor = Color3.fromRGB(255, 170, 40),

	Attributes = {
		-- A single JSON string holding the source part's size and visual
		-- properties ({ version, size, props }), so a cut model can be rebuilt
		-- without a wall of per-property attributes cluttering the Properties
		-- widget. See BoxCutterOperations for the encode/decode format.
		Data = "BoxCutterData",
		-- Stored on Texture instances as a Vector2 (U, V): the OffsetStudsU/V
		-- the texture had on the uncut source part, so fragment offsets are
		-- always computed from the original anchor instead of compounding
		-- regeneration after regeneration
		TextureBaseOffset = "BoxCutterBaseOffset",
	},

	GeometryFolderName = "Geometry",
	CutterName = "Cutter",
	CutterBoxName = "CutterBox",

	-- Suffix appended to a part's name when it becomes a cut model; stripped
	-- back off on bake so the resulting geometry keeps the original name
	CutModelSuffix = "_Cut",

	CutterTag = "BoxCutterCutter",

	-- CollectionService tag identifying the outline SelectionBoxes the plugin
	-- places on cutters; survives renames and avoids workspace-wide scans
	CutterBoxTag = "BoxCutterOutline",

	-- CollectionService tag on every cut model, so all of them can be found
	-- after an undo/redo without scanning the whole place
	CutModelTag = "BoxCutterModel",
}
