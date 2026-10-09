# KoalaSandPaper

A physically driven granular-matter machine for live wallpapers and rendered 4K loops: Tetris pieces ride a conveyor, get crushed by a press, torn by toothed rollers, mixed by a rotor, and a never-stopping pusher sends half the sand back up a bucket elevator and half into a furnace. Everything you see is the result of simulation, not animation.

Built with Godot 4.7 (Forward+, Metal) and a GPU XPBD particle solver in GLSL compute shaders. The engineering notes are in [docs/NOTES.md](docs/NOTES.md); the original audit and brief are in [docs/AUDIT.md](docs/AUDIT.md) and [docs/AGENT_PROMPT.md](docs/AGENT_PROMPT.md).

## Requirements

- Godot 4.7.1 (`/Applications/Godot.app` on macOS; set `GODOT=/path/to/godot` otherwise).
- A GPU with Vulkan or Metal. Compute shaders do not run with `--headless` or the Compatibility renderer.
- ffmpeg for video encoding.
- On macOS, keep the desktop unlocked while simulating: hidden or locked-screen windows are throttled to about 1 fps.

## Run

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path godot
```

The factory scene runs in real time at 60 fps. Press `Esc` to quit.

## Tests

```sh
godot/tools/lint.sh
godot/tests/run_all.sh
```

`lint.sh` parse-checks every script and compiles every compute shader. `run_all.sh` runs the machine clearance audit (headless) and the physical acceptance tests T1–T9 plus a pusher test, each printing one JSON line, then a pass/fail summary.

## Capture a 4K video

```sh
godot/tools/run.sh res://render/main.tscn frames=5400 save_state=../renders/state.bin
godot/tools/capture.sh 30 renders/state.bin
```

The first command runs the machine in for 90 s and saves the full simulation state. The second renders 30 s with Godot's Movie Maker at 3840×2160 and a fixed 60 fps, decoupled from real time, and encodes `renders/kinetic_study_001_4k.mp4` (H.265, 10-bit). Renders are git-ignored.

## Wallpaper

- **Fullscreen window:** `Godot --path godot -- wallpaper=1 fps=30` (add `load_state=/abs/path/state.bin` to start with a running machine).
- **macOS:** set the rendered loop as a video wallpaper with a third-party wallpaper app. macOS has no built-in video wallpaper.
- **Windows:** use the rendered video with Lively Wallpaper or Wallpaper Engine.

## Licence

This repository is public at the copyright holder's request (Shik3i). No licence is granted to third parties to copy, modify or redistribute it.
