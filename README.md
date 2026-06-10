<h1 align="center">BoxCutter</h1>

<p align="center">
  A Roblox Studio plugin that cuts box-shaped holes into Parts non-destructively, with live preview while you move the cutter.
</p>

---

## Features

- **Non-destructive cutting** — select a block Part and click **Add Cut Box** to turn it into a cut model with a translucent red cutter box inside.
- **Live editing** — move, rotate, or resize cutter boxes with the standard Studio tools; the cut geometry regenerates in real time while the widget is open.
- **Multiple cutters** — add as many cut boxes to a model as you want; delete a cutter part to remove its cut.
- **Attribute-driven** — the source part's size and visual properties are stored as attributes (`BoxCutterSourceSize`, `BoxCutterProp_*`), so cut models survive saves and can be re-edited any time.
- **Bake** — strips cutters and plugin attributes, leaving plain geometry; optionally unions the result into a single UnionOperation.
- **Undo support** — all operations are recorded with `ChangeHistoryService`; live drag updates append to the existing waypoint so undo history isn't flooded.
- **Native Studio look** — the widget UI is built with Fusion and themed Studio components.

## Installation

1. Build the plugin with [Rojo](https://rojo.space):
   ```
   rojo build build.project.json -o BoxCutter.rbxm
   ```
2. Place the output file in your Roblox Studio **Plugins** folder.

## Usage

1. Open the **Box Cutter** widget from the toolbar.
2. Select a block Part in the viewport.
3. Click **Add Cut Box** — the part becomes a cut model and the new cutter box is selected.
4. Move/rotate/resize the red cutter with the standard Studio tools; the hole follows live.
5. Select the model and click **Add Cut Box** again for additional holes.
6. When you're happy, click **Bake Selection** to strip the plugin data (optionally unioning the result).

## Development

Tooling is managed with [Rokit](https://github.com/rojo-rbx/rokit):

```
rokit install
cd src && wally install && cd ..
rojo sourcemap build.project.json -o sourcemap.json
wally-package-types --sourcemap sourcemap.json src/Packages
```

`watch-build.ps1` rebuilds the plugin into your local Studio plugins folder whenever a source file changes.

## Tech Stack

- [Fusion 0.2](https://elttob.uk/Fusion/) - reactive UI framework
- [Promise](https://eryn.io/roblox-lua-promise/) - async utilities
- [Janitor](https://github.com/howmanysmall/Janitor) - cleanup management

## License

This project is licensed under the [MIT License](LICENSE).
