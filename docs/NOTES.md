# KoalaSandPaper — engineering notes

Overwritten as decisions change; not a log. Read this first on resume.

## Versions / environment
- Godot 4.7.1.stable (a13da4feb), Metal 4.0, Forward+, Apple M4. ffmpeg (Homebrew) for encoding.
- GPU work needs a window *and an unlocked desktop*: macOS throttles hidden/locked Metal windows to ~1 fps, and no local RenderingDevice exists with `--headless`. Batch windows run always-on-top.
- The display caps windows at 120 Hz even with vsync off → benchmarks use `spf=N` (N sim frames per display frame).

## How to run
- Lint (GDScript + shader compile): `godot/tools/lint.sh`
- Machine clearance audit (headless): `godot --headless --path godot --script res://tools/clearance.gd`
- One scene: `godot/tools/run.sh <scene> k=v ...` (prints JSON lines). Factory: `res://render/main.tscn` (`frames=N`, `shot=/abs.png shots=a,b`, `full=1`, `trace=1`, `t8=1`, `save_state=`, `load_state=`, `wallpaper=1 fps=30`).
- All tests: `godot/tests/run_all.sh` (summary table; results in /tmp/koalasandpaper_tests.jsonl).
- 4K capture: `godot/tools/capture.sh 30 renders/state.bin` → `renders/kinetic_study_001_4k.mp4`.

## Solver (godot/sim) — XPBD on the main RenderingDevice
Per substep (48 per 1/60 s frame): `rigid_predict` → `integrate` → `contacts` → `rigid_solve` → `finalize` → `velocity`.
- State: X (positions), D (substep displacement, kept separate so v = D/h keeps float32 precision), V; packed XD/XV for neighbour reads; INFO = material | kind | radius code (8 bit) | heat (8 bit).
- Grid: cell 2·r_max, fixed bins (CELL_CAP 4, overflow counted), double-buffered by substep parity so clearing never races with reads.
- `integrate`: applies the pre-stabilisation shift (position only), predicts (gravity / rigid pose), clamps to 0.5 r (counted), bins.
- `contacts` (Jacobi, constraint groups in order, Macklin 2014 §4.3): particle contacts with Coulomb friction (eq. 24) and shock-propagation mass bias exp(k·Δy/R), k = 0.13; bonds (XPBD distance, break on strain 0.12, on lost partner/fragment change). Averaging: N_eff = Σ|c|/max|c| (zero-proposing constraints don't dilute friction). Then machine surfaces + walls projected sequentially (Gauss-Seidel) on the result.
- `rigid_solve` (one 64-thread workgroup per piece): intact pieces are rigid bodies; grain corrections → impulse response for point contacts blended with the least-squares rigid motion for extended contacts; Coulomb friction decided per piece (mean slip vs mean cone); a body pinched beyond 0.3 R for 4 substeps shatters into its bond net; laser (removed from the factory) splits bodies.
- `finalize`: X += D (or rigid pose), velocity → XV, sinks, heat zones (glow +1/8 substeps, burn at 250, cool −1/24).
- `velocity` (Müller 2020 §3.6): closed contacts get relative normal velocity −e·v_pre (e = 0.03, 0 below 2gh) → no popping/compression waves; same loop computes the next pre-stabilisation shift (Macklin 2014 §4.4).
- Machine colliders: SDF prims (circle, capsule, box, arc; polar repeat; belt surface speed on the top face only), poses from analytic motion profiles with finite-difference velocities; coarse CPU-built prim grid (0.4 m cells).

## Scale
- R = 5 mm (±10 % radius spread), SI, y up. The brief's 1–2 mm is infeasible with the hard 0.5 r/substep rule (max speed = 0.5 r·60·N_sub; 48 substeps → 4.8 m/s at R = 5 mm). World 12.288 × 6.912 m ≈ 1229 × 691 grain diameters ≈ 3 px per grain at 4K.

## Factory (godot/machine/factory.gd), one loop
Inclined bucket elevator (left, 24° lean so the empty return strand clears the head; buckets fixed to the chain, mouth in travel direction, gravity discharge, 0.5 m/s) → 37° head chute → belt A (cleated, 0.45 m/s; tetromino pieces spawn every 3 s) → press (17 cm above belt: tall pieces shatter) → shredder (2 roller pairs, tops running into the nip, 5 cm gaps) → mixer (3-blade rotor, bottom outlet ±12°) → floor with one heavy pusher on a continuous phase-modulated stroke (right of the outlet exactly half the time → 50/50) → left: elevator pit / right: furnace (heat zone). Floor drain recycles spill. `tools/clearance.gd` keeps every moving part ≥ 3 cm from static geometry (gaps < 8 mm are seals).

## Test status (last full run before the screen locked; see run_all.sh)
- T1 free fall: PASS (rel err 0.023 % at 80 substeps).
- T2 repose: PASS (30.3/31.4/31.9° and 33.1/29.9/31.3° vs 32°).
- T3 incline (rigid 8×10 block): PASS (30° static 0.0 m; 34° slides 0.5838 m vs 0.5808 m analytic).
- T4 silo, T5 mixer (new geometry), T6 shredding, T7 conveyor, T8 conservation, pusher: written, not yet run (screen locked).
- Clearance audit: PASS (min open gap 3.95 cm).
- T9 perf (48 substeps): 16k grains 5.2 ms/sim frame, 64k 32.3 ms. Factory (~20k grains + render) ≈ 50–60 fps uncapped.

## Known issues / next
- Free-fall spill from the elevator head and long drops exceed 4.8 m/s → speed clamps counted (no tunnelling observed).
- Perf at 64k is memory-bound (neighbour gathers): next step is periodic spatial reordering of free grains.
- Jam/torque limits not modelled (motors are ideal kinematic drives).
- macOS wallpaper = looped video via a third-party wallpaper app or `wallpaper=1` fullscreen window.

## Owner preferences (from feedback)
One readable loop, no hidden "fields": mechanisms must be visible (pistons, cleats, buckets). Pistons never pause. Rollers feed the nip. No laser. Minimal splash. Real-time speeds.
