# KoalaSandPaper — engineering notes

Overwritten as decisions change; not a log. Read this first on resume.

## Versions / environment
- Godot 4.7.1.stable (a13da4feb), Metal 4.0, Forward+, Apple M4. ffmpeg (Homebrew) for encoding.
- GPU work needs a window *and an unlocked desktop*: macOS throttles hidden/locked Metal windows to ~1 fps, and no local RenderingDevice exists with `--headless`. Batch windows run always-on-top.
- The display caps the window at its refresh rate even with vsync off → timings use `spf=N` (N sim frames per display frame); `ms_per_frame` in traces is per sim frame.
- zsh does not word-split `$var`: loop over argument strings with `eval`.

## How to run
- Lint (GDScript + shader compile): `godot/tools/lint.sh`
- Machine audit (headless): `godot --headless --path godot --script res://tools/clearance.gd -- map=factory|galton`
- Factory: `godot/tools/run.sh res://render/main.tscn` (`map=galton`, `frames=N`, `trace=1`, `spf=N`, `shots=a,b shot=/abs.png full=1`, `t8=1`, `save_state=`/`load_state=`, `skip=kernel+kernel`, `hide=layer+layer`, `wallpaper=1 fps=30`, `max_active=N`).
- Tests: `godot/tests/run_all.sh`; sand quality: `tools/run.sh res://tests/runner.tscn t=q_sand case=collapse|impact|push`.

## Solver (godot/sim) — DEM on the main RenderingDevice
Why DEM: the earlier XPBD/Jacobi solver had friction capacity independent of depth (per-substep corrections, not load), so bulk sand flowed like a light fluid around blades, crept (0.3 R/s at rest) and turned overlap into velocity. DEM (Cundall & Strack 1979; Luding 2008) gives load-dependent friction, real inertia, no creep.
- Contact: linear spring-dashpot normal (k from contact time t_c = 7 steps, no tension), tangential spring with memory, Coulomb on the elastic shear with static/kinetic hysteresis; dashpots implicit in the grain's own velocity (explicit ones went unstable with many stiff contacts: bonded lattices burst). Non-rotating discs.
- Per frame: `dem_order` ×4 (count/scan/scatter grains into 9 cm blocks → spatial visit order; carry contact histories to the new visit slots), then 48 × `dem_step` (fused: forces, integration, zones, grid insert, render), `dem_rigid` every 4 steps.
- Grid: bins of packed grain data (pos, half-float vel, id|radius|kind|material), two halves stamped by step (count word = stamp<<8 | n; stale = empty; no clear pass).
- Contact history (keys + float32 springs) lives in visit-slot order (coalesced); float32 because per-step increments (~1e-7 R) vanish in half floats.
- Rigid pieces: multi-sphere bodies integrated inline in `dem_step` (every grain recomputes its body state identically; the leader grain stores it), forces summed per SIMD group then float `atomicAdd` into triple-buffered accumulators. Crush = force pushing from both sides (max over 4 directions of min(Σ+, Σ−)) > max(300 grain weights, 3 body weights) for 4 steps → piece breaks into ≤5 rigid chunks, chunk crumbles to sand. Fast trigger matters: every step of delay is overlap released explosively.
- Pieces may occupy any free slots (per-piece slot lists + `dem_spawn` scatter): contiguous allocation fragmented as sand burns and grew the slot range without bound.
- Colliders: SDF prims with analytic gradients; per-prim world AABB culling; coarse CPU grid 0.2 m (static part cached).

## Calibration (sand μ = 0.35, e = 0.1, R = 5 mm ±10 %, 48 steps)
- Repose (T2) 31–34° (dry sand 32°). Column collapse a = 2: (L∞−L0)/L0 = 2.4 (Lube 2005: 1.2 a). Rest jitter 0.0 R/s.
- Silo (T4): Beverloo fit within 1 %, k ≈ 2.5; orifices ≥ 8 d (6 d arches and jams, as in 2D experiments).
- Pieces/steel μ = 0.625 (single coefficient; per-contact μs/μk hysteresis made rigid blocks fail progressively below atan μs).
- 64 or 96 steps change no test result; 48 is the cheapest that keeps them.

## Factory (godot/machine/factory.gd), one loop
Enclosed inclined bucket elevator (casing walls continue the pit arc; spill stays inside) → head chute → belt A (pieces every 3 s while < 15 000 grains in the line) → press → two-stage shredder → mixer (map factory) or Galton board + bins + slide gate (map galton) → ram feeder (piston head 32×34 cm on a 6-stage telescopic cylinder from the furnace wall, phase-modulated so it is left of the outlet half the time: 50/50) → left: pit, right: furnace. Design rules learnt: no rounded edges sliding on floors (wedge-ejects grains), telescopic shoulders < grain radius, wiper seals (sole/gate 1 mm into the plate) instead of gaps.

## Performance (M4, factory ~15 k grains)
- ~8–9 ms per sim frame incl. render share; real time is display-capped at 60 fps. Was ~30 ms at the start of the DEM work.
- Steps: 96 → 48; fused kernel; machine drawing cached per moving part (was ~9 ms/frame of GDScript); visible instances = used slots; static collider grid cached.
- Remaining cost: ~10 ns per grain-step in dense heaps (contact model ~½). No memory growth over 2 min (objects, RAM, VRAM constant); GPU memory ~580 MB (grid bins 135 MB).

## Test status (last run, 48 steps)
- PASS: T1 free fall (0.01 %), T2 repose 32–35°, T3 tilting plane (30° holds, 34° accelerates at exactly g(sinθ−μcosθ)), T4 Beverloo (2.4 %), T5 mixer (p99 1.8 m/s), T6 shredding (all to sand, none inside rollers), T7 conveyor, pusher (no grain past the sole), column collapse 2.36 (Lube: 2.4), factory clearance + no-touch audit.
- Pending (screen locked during the last run): T8 120 s conservation (previous run: balance 0, nan 0, oob 0 after the crush fix), T9 benchmark, Galton map audit.
- Visuals added last, not yet looked at on screen: contact-count ambient occlusion in particles.gdshader.

## Known issues / next
- Sand riding on the ram rod collects at the barrel mouth inside the furnace (burns there).
- Wallpaper: macOS has no video wallpaper; use the rendered loop with a third-party app or `wallpaper=1`.

## Owner preferences (from feedback)
One readable loop, mechanisms visible (no hidden fields), pistons never pause and are thick (engine-piston look, driven from the furnace side), rollers feed the nip, no laser, minimal splash, real-time speeds, no parts touching, pieces must not break on landing, performance matters; maps: more variants, e.g. Galton board.
