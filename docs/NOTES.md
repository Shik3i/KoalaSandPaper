# KoalaSandPaper — engineering notes

Overwritten as decisions change; not a log. Read this first on resume.

## Versions
- Godot 4.7.1.stable (a13da4feb), Metal 4.0, Forward+, Apple M4 (Apple9). ffmpeg: /opt/homebrew/bin/ffmpeg.

## Layout / how to run
- `godot/` project. `tools/run.sh <scene> k=v ...` refreshes the class cache (headless import) then runs the scene windowed (compute is unavailable headless). Scenes print one JSON line and quit.
- Bench: `tools/run.sh res://tools/bench.tscn n=50000 sub=6 cols=1280 frames=300 warm=60 [probe=1] [shot=/abs/x.png shot_at=45]`.

## Solver (sim/)
- Kernels per substep: `integrate` (gravity, predict, clamp 0.5r, grid insert) → `contacts` ×iters (Jacobi, ping-pong pa/pb) → `finalize` (v=(p−x)/h, guards, clears own grid cell, writes render texel on the last substep).
- Neighbour grid: fixed-capacity bins (cell 2r, CELL_CAP=8, atomic insert, overflow counted). Chosen over counting sort: no prefix scan, clear is per-particle. Revisit if contacts stay memory-bound (see perf).
- Stats buffer (uint): clamp, overflow, nan, oob, max_pen/r (float bits), max_speed. Read only by tests/bench.
- Render: RGBA32F texture 1024×⌈N/1024⌉ (x, y, rgb24-as-float, kind) wrapped as `Texture2DRD`; `ParticleView` = MultiMeshInstance2D, canvas shader reads it by INSTANCE_ID (skip_vertex_transform). No CPU readback.
- GPU timestamps return 0 on Metal → time via frame deltas.

## Scale decision (provisional, M1 finalises)
- r = 5 mm (grain Ø 1 cm), SI, y up. Brief's 1–2 mm is infeasible with the hard 0.5r/substep rule: v_max = 0.5r·60·N_sub (r=1 mm, N_sub=6 → 0.18 m/s). Penetration in a resting pile grows ~ g·h²·depth/r, so substeps matter quadratically.
- At r=5 mm: N_sub=6 collapses piles (pen ≫ 0.25r); N_sub=48–60 holds them (pen 0.08r @ 20 rows). M1 must pick N_sub/stack bias by tests.

## M0 gate (2026-10-08) — PASS, GPU path kept
1920×1080 window, vsync off, block of N grains falling into a 1280×720-Ø box. fps / frame p50 / p95 (ms):

| N | sub=6 | sub=24 | sub=48 |
|---|---|---|---|
| 20k | 414 / 2.2 / 3.8 | 427 / 2.2 / 3.2 | 264 / 3.6 / 6.0 |
| 50k | 383 / 2.5 / 3.7 | 187 / 5.4 / 6.3 | 96 / 10.4 / 13.2 |
| 100k | 207 / 4.7 / 7.0 | 82 / 12.2 / 13.9 | 42 / 24.5 / 30.5 |

- Gate (≥60 fps @ ≥40k, N_sub=6): 383 fps @ 50k. Fallback (GDExtension CPU) not needed.
- Marginal cost ≈ 0.21 ms/substep @50k, 0.51 ms @100k (≈5 ns/particle/substep): memory-bound neighbour gathers. Optimisation candidates: CELL_CAP 4, store (p, Δx) in bins, periodic spatial reorder of particle storage.
- Known issue → M1: settled piles flatten over ~5 s (static friction diluted by Jacobi averaging / residual compression).

## Open questions (defaults assumed)
- Look: side-on 2D, shaded spheres, sorbet. Want 3 reference screenshots at M5.
- Wallpaper: macOS looped video + fullscreen window. Output: 3840×2160@60, 30–60 s loops. Grain target 40–100k.
