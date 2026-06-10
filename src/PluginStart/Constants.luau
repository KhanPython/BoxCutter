return {
	Version = "0.1.0",
	PluginAssetId = 0,

	-- Smallest dimension a generated solid part may have on any axis
	MinPartSize = 0.05,

	-- New cutters spawn at this fraction of the source part's size
	DefaultCutterScale = 0.5,
	MinCutterSize = 0.2,

	CutterColor = Color3.fromRGB(255, 80, 80),
	CutterTransparency = 0.55,

	Attributes = {
		SourceSize = "BoxCutterSourceSize",
		Cutter = "BoxCutterCutter",
		PropertyPrefix = "BoxCutterProp_",
	},

	GeometryFolderName = "Geometry",
	CutterName = "Cutter",
}
