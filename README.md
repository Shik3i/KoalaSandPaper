# KoalaSandPaper

An endless, local kinetic-sand studio for browser, desktop and Windows live-wallpaper use.

## What runs today

- `src/physics.js`: deterministic falling-sand kernel. Global bottom-to-top traversal, alternating horizontal order, one move per tick, active 32×32 chunks and sleep/wake handling.
- `src/factory.js`: conveyor, bound tetromino forms, laser kerf, interlocking shredder teeth, open mixer bowl, circulation field and drain. The material balance is exact: a grain is bound to a form, in the simulated world, or counted at the outlet.
- `src/worker.js`: up to eight fixed 60 Hz steps per animation hand-off. Rendering and the studio UI remain on the main thread.
- Browser studio: presets, tempo, palette, machine toggles, deterministic seed, zen mode and 30-second canvas recording.
- Electron desktop shell: macOS and Windows targets are defined; renderer access to Node is disabled, context isolation and sandboxing are enabled, and external navigation is blocked.
- Lively package: a self-contained HTML wallpaper with persistent tempo, palette and pause controls.

## Origin and scope

`vendor/koalasand/` contains unmodified copies of the KoalaSand Phase-1 GDScript granular reference and its deterministic hash, plus the original license and a SHA-256 provenance manifest. The copied upstream snapshot is `99cedca40f487af84d8bfd0d950af3918535259e` from `https://github.com/Shik3i/KoalaSand`.

KoalaSandPaper ports those rules to JavaScript. It does **not** copy the original Godot game, native `NativeSandWorld`, assets, world generation, material data, factory systems, or GDExtension. The conveyor, cutting, shredding and mixer are new Paper-specific presentation and simulation systems.

KoalaSand is all-rights-reserved. Its license and source provenance remain included. Do not publish this derivative or its copied source without the copyright holder's written permission.

## Run

```sh
npm install
npm run dev
```

Open `http://127.0.0.1:4173`.

```sh
npm test
npm run benchmark
npm run package:wallpaper
npm run package:desktop
```

`package:wallpaper` creates `release/KoalaSandPaper-Lively.zip`. In Lively Wallpaper, import the ZIP and use **Customise** to set tempo, palette and pause. `package:desktop` creates an unpacked platform application in `release/`; a signed distribution needs the platform signing credentials and release configuration.

## Platforms

| Surface | Current result |
| --- | --- |
| Web | Fully runnable from `dist/` or the development server. |
| macOS desktop | Packaged arm64 Electron app tested as an unsigned local build. |
| Windows desktop | Electron builder configuration is present; build it on Windows for a Windows executable. |
| Windows live wallpaper | `KoalaSandPaper-Lively.zip` is ready for Lively's webpage-wallpaper player. |
| macOS live wallpaper | Feasible with a native desktop-level `NSWindow` / `WKWebView` host, but not implemented in this first delivery. |

## Validation

`npm test` has eight tests: upstream hash parity, global traversal against an independent reference, chunk-boundary single-move protection, sleep/wake, input guards, machinery move stamps, 2,400-tick factory flow/mass balance and deterministic replay.

`npm run benchmark` measures the JS kernel only, not browser paint or video encoding. On Apple M4 during this delivery: the factory averaged `0.29 ms/tick`; 91,691 active grains averaged `2.05 ms/tick`; the settled sleeping case averaged `0.025 ms/tick`.
