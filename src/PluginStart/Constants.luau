return {
	Version = "0.3.0",
	PluginAssetId = 0,

	-- Smallest dimension a generated solid part may have on any axis
	MinPartSize = 0.05,

	-- Seconds of cutter inactivity before a live-edit recording is committed
	LiveCommitDelay = 0.3,

	-- Cutters are invisible; this colors their SelectionBox outline
	CutterColor = Color3.fromRGB(255, 80, 80),

	Attributes = {
		SourceSize = "BoxCutterSourceSize",
		Cutter = "BoxCutterCutter",
		PropertyPrefix = "BoxCutterProp_",
	},

	GeometryFolderName = "Geometry",
	CutterName = "Cutter",
}
