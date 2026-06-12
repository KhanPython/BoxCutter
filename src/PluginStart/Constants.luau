return {
	Version = "0.4.0",
	PluginAssetId = 0,

	-- Smallest dimension a generated solid part may have on any axis
	MinPartSize = 0.05,

	-- Cutters are invisible; this colors their SelectionBox outline
	CutterColor = Color3.fromRGB(255, 80, 80),

	-- Color of the SelectionBox outline marking the current target
	TargetColor = Color3.fromRGB(255, 170, 40),

	Attributes = {
		SourceSize = "BoxCutterSourceSize",
		Cutter = "BoxCutterCutter",
		PropertyPrefix = "BoxCutterProp_",
		-- Stored on Texture instances: the OffsetStudsU/V the texture had on
		-- the uncut source part, so fragment offsets are always computed from
		-- the original anchor instead of compounding regeneration after
		-- regeneration
		TextureBaseOffsetU = "BoxCutterBaseOffsetU",
		TextureBaseOffsetV = "BoxCutterBaseOffsetV",
	},

	GeometryFolderName = "Geometry",
	CutterName = "Cutter",
	CutterBoxName = "CutterBox",

	-- CollectionService tag identifying the outline SelectionBoxes the plugin
	-- places on cutters; survives renames and avoids workspace-wide scans
	CutterBoxTag = "BoxCutterOutline",

	-- CollectionService tag on every cut model, so all of them can be found
	-- after an undo/redo without scanning the whole place
	CutModelTag = "BoxCutterModel",
}
