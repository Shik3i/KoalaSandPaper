# KoalaSandPaper — engineering notes

Overwritten as decisions change; not a log. Read this first on resume.

## Versions / environment
- Godot 4.7.1.stable (a13da4feb), Metal 4.0, Forward+, Apple M4. ffmpeg (Homebrew) for encoding.
- GPU work needs a window *and an unlocked desktop*: macOS throttles hidden/locked Metal windows to ~1 fps, and no local RenderingDevice exists with `--headless`. Batch windows run always-on-top.
- The display caps the window at its refresh rate even with vsync off → timings use `spf=N` (N sim frames per display frame); `ms_per_frame` in traces is per sim frame.
- zsh does not word-split `$var`: loop over argument strings with `eval`.
- Godot re-imports a `.glsl` only when its own checksum changes, never for its `#include` files: an edit to `common.glsli` silently ran stale kernels. `tools/run.sh` and `tools/lint.sh` delete `.godot/imported/*.glsl-*` whenever an include is newer than `.godot/.glsli_stamp` — always go through them.

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
- Breakage (brittle, local): a grain carrying > 300 grain weights for 2 steps chips off as sand (teeth, edges, corners). A body breaks when squeezed two-sided beyond 300·max(1, 0.22√n) grain weights (strength ∝ √size, like stress × contact width) or by a point load: only around the most loaded grain — crushed core (1.6 R) to dust, a shear crack (20–35° off the load) breaks one or two wedges off within ~1.1 × radius of gyration, the rest stays whole; fragments cannot break again for 0.2 s. Bodies below 3×12 grains crumble.
- Press = hydraulic with pressure relief, modelled on the GPU: force sensor on its plate (FLAG_SENSE), the plate holds its position during any step after one above the limit (yield offset, body_pose), and the CPU stroke returns once the frame-averaged load passes 70 % of it — a stamp blow. A kinematic press pulverised everything within one frame.
- Rigid pieces: multi-sphere bodies integrated inline in `dem_step` (every grain recomputes its body state identically; the leader grain stores it), forces summed per SIMD group then float `atomicAdd` into triple-buffered accumulators. Squeeze = force pushing from both sides (max over 4 directions of min(Σ+, Σ−)); breakage rules above; crush counter 4 steps. Fast trigger matters: every step of delay is overlap released explosively. Body spin capped at 20 rad/s (nip torques otherwise spin chunks up and their crumbs fly off). Tried and rejected: stiffer rigid contacts (sand under a stiffly supported piece got crushed and shot out); a force cap on machine contacts (heads plough into heaps).
- Pieces may occupy any free slots (per-piece slot lists + `dem_spawn` scatter): contiguous allocation fragmented as sand burns and grew the slot range without bound.
- Colliders: SDF prims with analytic gradients; per-prim world AABB culling; coarse CPU grid 0.2 m (static part cached).

## Calibration (sand μ = 0.35, e = 0.1, R = 5 mm ±10 %, 48 steps)
- Repose (T2) 31–34° (dry sand 32°). Column collapse a = 2: (L∞−L0)/L0 = 2.4 (Lube 2005: 1.2 a). Rest jitter 0.0 R/s.
- Silo (T4): Beverloo fit within 1 %, k ≈ 2.5; orifices ≥ 8 d (6 d arches and jams, as in 2D experiments).
- Pieces/steel μ = 0.625 (single coefficient; per-contact μs/μk hysteresis made rigid blocks fail progressively below atan μs).
- 64 or 96 steps change no test result; 48 is the cheapest that keeps them.

## Factory (godot/machine/factory.gd), one loop
Enclosed inclined bucket elevator (33 small buckets 16×11 cm every 40 cm: a steady stream; casing walls continue the pit arc; spill stays inside) → head chute → belt A (pieces every 3 s while < 15 000 grains in the line) → press → two-stage shredder → mixer (map factory) or Galton board + bins + slide gate (map galton) → ram feeder (piston head 32×34 cm on a 6-stage telescopic cylinder from the furnace wall, phase-modulated so it is left of the outlet half the time: 50/50) → left: pit, right: furnace. Design rules learnt: no rounded edges sliding on floors (wedge-ejects grains); no overlapping colliders under sand (two springs flick grains up) — the ram's stages are drawn only and one rod collider spans head to barrel, length updated per frame (Factory.update), flush with the barrel; wiper seals (sole/gate 1 mm into the plate) instead of gaps. Galton map: full-width staggered peg field under a 6 cm throat (a triangle with side walls fed the outer bins).

## Readability (wallpaper)
Station badges (number, name, one line on what happens), faint drifting chevrons along the material path (render/flow.gd, Factory.flow_paths), sand drawn 15 % fuller than its contact radius, contact-count shading on heaps.

## Performance (M4, factory ~15 k grains)
- ~8–9 ms per sim frame incl. render share; real time is display-capped at 60 fps. Was ~30 ms at the start of the DEM work.
- Steps: 96 → 48; fused kernel; machine drawing cached per moving part (was ~9 ms/frame of GDScript); visible instances = used slots; static collider grid cached.
- Remaining cost: ~10 ns per grain-step in dense heaps (contact model ~½). No memory growth over 2 min (objects, RAM, VRAM constant); GPU memory ~580 MB (grid bins 135 MB).

## Test status (48 steps)
- PASS: T1 free fall (0.01 %), T2 repose 32–35°, T3 tilting plane (30° holds, 34° accelerates at exactly g(sinθ−μcosθ)), T4 Beverloo (2.4 %), T5 mixer (p99 1.8 m/s), T6 shredding (all to sand, none inside rollers), T7 conveyor, pusher (no grain past the sole), column collapse 2.36 (Lube: 2.4), clearance + no-touch audits.
- T8 120 s: balance 0, nan 0, oob 0, grid overflow 0, 740 speed clamps (was > 2 million before the jam fixes), max overlap 0.97 r.
- Diagnostics kept in the trace (`trace=1 trace_every=N`): clamp/oob positions and the prim touched; how every launch source above was found.

## Known issues / next
- Sand riding on the ram rod is pushed over the flush barrel into the furnace (burns there).
- Wallpaper: macOS has no video wallpaper; use the rendered loop with a third-party app or `wallpaper=1`.

## Owner preferences (from feedback)
One readable loop, mechanisms visible (no hidden fields), pistons never pause and are thick (engine-piston look, driven from the furnace side), rollers feed the nip, no laser, minimal splash, real-time speeds, no parts touching, pieces must not break on landing, performance matters; maps: more variants, e.g. Galton board.
