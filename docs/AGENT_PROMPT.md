# KoalaSandPaper — Agent Brief (Godot rebuild)

You are the lead engineer for **KoalaSandPaper**. Read this file once, then execute. Work autonomously; ask the owner only the questions in §9 and only if a default is wrong for them.

## 1. Goal (one paragraph)

Build a **physically driven granular-matter machine** that produces (a) a live wallpaper and (b) offline-rendered, loopable 4K videos in the style of the "Shredding Tetris / Tetris Shredding Machine" series (see §2): a conveyor delivers colored Tetris pieces, a laser can cut them, interlocking counter-rotating rollers **tear them into grains**, the grains **pour, pile, and are physically mixed by a rotating 3-blade mixer**, then drain/collect. Everything visible must be the *result of simulation*, never of scripted animation or teleporting.

**Engine: Godot 4.7.1** (installed: `/Applications/Godot.app/Contents/MacOS/Godot`, Apple M4 / Metal). Language: GDScript for orchestration/tools, GLSL compute for the solver. The existing JS/Electron prototype is **legacy** (§3).

## 2. Reference material (what is verified, what is not)

- Videos (owner's targets): `https://youtu.be/Os6T_SBR7uU` ("Shredding Tetris, Tetris Shredding Machine 4 4K") and `https://youtu.be/ZoePRZHFCuM` ("… Machine 14 4K LASER"), channel *Lafikobra 3D*. Per its description the latter was **made in Blender with the "Hurricane" add-on** (BeFX Studios; per press coverage a CPU multi-material solver using XPBD for sand/grains/fluids/cloth/soft bodies, all materials interacting in one solver).
- Verified from the first frame only: grey machine, red block on a conveyor, a large 3-blade rotor, a laser emitter, gears, side-on near-orthographic view, colored pieces on dark monochrome machinery. You **cannot** watch the videos. Do not invent further details; if the look matters, ask the owner for 3 screenshots (§9).
- Owner's brief (authoritative): sand/grains are physically mixed and shredded; output = wallpapers and mesmerizing videos. Current prototype "falls through the mixer, has no physical properties, shredding is bad".

## 3. Starting point (do not re-audit)

Read `docs/AUDIT.md` (≈45 lines) and nothing else from the legacy code unless a task needs it. Summary: the JS prototype is a falling-sand cellular automaton with scripted props; grains have no mass/velocity/friction; mixer stalls at ~tick 1200 and nothing is ever collected; "shredder" is static disks with decorative gears; tetromino forms are pixel lists that convert to grains at once; belt teleports grains. **Replace the core; do not patch it.**

First `git mv` `src/ scripts/ desktop/ tests/ index.html public/ package.json package-lock.json vendor/` into `legacy/web/` (do not extend them; delete at M4). Layout to create:

```
godot/            Godot project (project.godot at this level)
  sim/            compute shaders (.glsl) + solver wrapper (GDScript)
  machine/        machine definition (data) + kinematic colliders
  render/         particle renderer, post, camera
  tools/          benchmark, capture, test runner (headless-safe parts)
  tests/          physical acceptance tests (§7)
docs/             AUDIT.md, AGENT_PROMPT.md, NOTES.md (you maintain, ≤150 lines)
legacy/web/       the old JS prototype
```

Do **not** read `../KoalaSand` (92 markdown docs, grid-CA design, token sink). `vendor/koalasand/` is a historical snapshot; ignore it. Keep `docs/` and the public-repo licence note in `README.md` accurate.

## 4. Architecture (decided; deviate only via the M0 gate)

**One unified particle solver, all matter = particles.** (This is the Hurricane/XPBD idea, scoped down.)

- **Space:** 2D simulation in the XY plane (side view like the references). Particles are discs of radius `r`; render as shaded spheres (fake 3D) first. A 3D-extruded render is optional polish (M6), never a precondition.
- **Solver:** XPBD/position-based on the GPU (Godot `RenderingDevice` compute; **Forward+** or **Mobile** renderer only — compute does not exist in Compatibility or `--headless`).
  - Fixed timestep `dt = 1/60`, `N_sub` substeps (start 6), 1–2 contact iterations per substep, Jacobi with averaged corrections (GPU-safe).
  - Neighbour search: uniform grid, cell size `2r`, counting sort per substep (histogram → prefix sum → scatter). Max particles per cell bounded and asserted.
  - Contacts: non-penetration + **Coulomb friction** (`mu_static`, `mu_kinetic`, defaults from `tan(32°)` for sand; per-material table), restitution ≈ 0.1–0.2, mild velocity damping. Velocity from position delta; no free-floating velocity state that can explode.
  - **Anti-tunnelling rule (hard):** per substep no particle may move more than `0.5·r`; clamp and count violations (expose counter).
- **Matter kinds** (a `kind` + `material_id` per particle; per-material `mass`, `mu`, `restitution`, color palette):
  1. **Free grain** — no bonds.
  2. **Bonded solid** — tetromino piece = hex-packed cluster of particles with **distance bonds** (XPBD compliance, per-bond rest length). A bond **breaks** when strain > `break_strain` (tunable); fragments are then ordinary grains/clumps. Shredding emerges from roller teeth straining bonds — no scripted conversion.
  3. **Kinematic machine colliders** — analytic **SDF primitives** (circle, capsule, box, convex polygon) uploaded each frame with pose + linear/angular velocity. Contact uses **relative surface velocity**, so a moving surface drags grains through friction (this is how belt, rollers and mixer blades transport/mix). They are driven by motors (target angular/linear velocity); optional torque limit → physical jam/stall detection.
- **Conveyor:** a kinematic collider with tangential surface speed. Never move particles directly.
- **Laser:** each substep, a moving segment cuts every bond it intersects (state change = bond break) and emits emissive spark particles (cosmetic, excluded from conservation). No heat model required.
- **Source/Sink:** the only places where particle count may change; both counted. Preferred loop: sink at the drain → source re-spawns new Tetris pieces at the belt start, so the scene runs endlessly.
- **Rendering:** no CPU readback. Particle positions/colors live in an RD storage buffer/texture; a `MultiMeshInstance2D` (or one instanced quad mesh) reads them in the vertex shader (`Texture2DRD` pattern). Machine drawn from the *same* machine definition used for collision (single source of truth) — no overlay hacks.
- **Determinism:** GPU atomics are not bit-deterministic. Acceptable for video. Provide a fixed seed for spawn/material jitter and a **CPU reference solver** (`sim/ref_cpu.gd`, small N≈300–1500, same constants) for parity/regression tests.
- **Fallback (only if M0 fails):** GDExtension (C++/godot-cpp or Rust/gdext) multithreaded 2D XPBD with spatial hash, same data model, 30–80k particles. Decide at the M0 gate with numbers, record in `docs/NOTES.md`.
- **Do not use:** grid cellular automata, Godot `RigidBody2D` per grain, `GPUParticles2D` collision as physics, MPM/FLIP (out of scope; revisit only after M5).

## 5. Milestones (vertical slices; each ends with tests green + commit)

- **M0 — Spike & gate (small).** Godot project opens; RD compute works on this Mac; 50k discs free-fall onto a floor from a texture-fed renderer; measure ms/step and FPS at 20k/50k/100k. **Gate:** ≥ 60 FPS sim+render at ≥ 40k particles with `N_sub=6`, else take the fallback. Write numbers to `docs/NOTES.md`.
- **M1 — Granular core.** Gravity, walls, neighbour grid, contacts, friction, restitution, anti-tunnelling counters, material table. Tests T1–T4, T8.
- **M2 — Machine colliders + mixer.** SDF kinematic bodies, motors, surface-velocity friction, open-top bowl with a real outlet, 3-blade rotor. Tests T5, T7.
- **M3 — Bonded solids, rollers, laser.** Tetromino generator, bond graph, break strain, two interlocking counter-rotating toothed rollers, laser bond-cutter. Test T6.
- **M4 — Full line.** Belt → laser → rollers → mixer → drain → source loop, endless for ≥ 10 sim-minutes with zero leaks and stable count. Delete `legacy/web/`.
- **M5 — Look.** Palettes (6 base colors each; vary lightness ±10% per grain): `sorbet` #f6b17a #ed7e9a #bea5ee #8dccbc #f0d487 #8cbbe2 · `aurora` #7ae4c4 #62b7cd #8997ee #ba8ae0 #ee91bf #a9deb0 · `ember` #ef8468 #f4ad69 #e6cd88 #d78297 #ae96c5 #c5b397; machine greys ≈ #55676d/#718781 on background #111e28. Soft shadow/AO fake, rim light, depth tint, bloom, laser glow, camera (static + slow drift). German UI labels: stations `01 / FORMEN`, `02 / SCHNITT`, `03 / MAHLWERK`, `04 / MISCHEN`, `05 / SAMMELN`, title `KOALASANDPAPER / KINETIC STUDY 001`. Particle size 2–4 px at 4K.
- **M6 — Outputs.** (a) **Movie Maker** offline capture (`--write-movie out.png --fixed-fps 60` = PNG sequence + wav, decoupled from real time; 4K; optional seamless-loop mode by cycling the source schedule), then ffmpeg to H.265/ProRes. (b) Wallpaper mode: borderless fullscreen window, FPS cap, low-power profile, pause on battery/occlusion; macOS = looped video wallpaper (and/or fullscreen window), Windows = Lively/Wallpaper-Engine-compatible window or video. (c) Optional 3D-extruded render.

## 6. Physics constants (starting values; put in one `constants.gd`/resource)

`g = 9.81 m/s²` mapped at a documented px/m scale (e.g. 1 grain Ø = 2 mm ⇒ choose scale once; keep SI units in code). `r = 1.0–2.0 mm` equivalent, `mu_kinetic = tan 28°`, `mu_static = tan 32°`, restitution 0.15, sand density ≈ 1600 kg/m³. Tetromino cell = 8×8 grains per block (tunable). Roller gap ≈ 0.5–0.8 × piece thickness so pieces are gripped, not bypassed.

## 7. Physical acceptance tests (must exist, automated, print one JSON line each)

- **T1 Free fall:** grain from rest, `y(t)=½gt²` within 1% over 1 s (drag off).
- **T2 Angle of repose:** pour a column onto a plane; fitted pile slope within ±3° of the material's configured repose; reproducible over 3 seeds.
- **T3 Incline:** bonded block on a slope slides iff `tanθ > mu_static` (test θ = φ±2°).
- **T4 Silo/hourglass:** 2D Beverloo scaling `flow ∝ (D − k·d)^1.5` within 15% for 3 orifice widths.
- **T5 Mixing:** two color halves in the bowl; mixing index (nearest-neighbour color-entropy or Lacey) rises from < 0.2 to > 0.8 within ≤ 6 rotor revolutions; **0 grains leave the bowl except through the outlet** over 60 sim-s.
- **T6 Shredding:** a piece with thickness < roller gap is pulled in and torn into ≥ N fragments; thicker piece stalls under the torque limit (jam flag), no tunnelling through teeth.
- **T7 Conveyor transport:** grain on belt reaches belt speed within the friction-limited time; belt never moves a particle by direct assignment (assert in code review/grep).
- **T8 Conservation & stability:** `count(free)+count(bonded)+sinks−sources` constant; tunnelling violations = 0; max penetration < 0.25 r; no particle outside world bounds; no NaN.
- **T9 Performance:** frame-time p95 and particles/s on this Mac, logged to `docs/NOTES.md`.

GPU tests need a window (compute is unavailable with `--headless`): run Godot with a small/hidden window, `--quit-after`, and a test scene; the CPU reference covers purely logical checks headlessly. A milestone is **done only when tests are green and a 10 s clip (or 2–3 screenshots at ≤ 960 px) is committed under `docs/media/`**.

## 8. Working rules — token & quality discipline

- **One read of this file.** Persist decisions in `docs/NOTES.md` (≤150 lines, overwrite, no logs). On resume read `NOTES.md`, not the whole repo.
- Plan **once** per milestone (≤10 lines), then implement. No restating of requirements, no option surveys; if choosing, state the pick + one-line reason.
- Smallest viable slice per commit; commit message = what + test evidence. Branch `main`, PR not needed.
- Read with `rg`/line ranges; never `cat` large files or print shader/compute dumps, long logs, or full JSON. Pipe tool output through `head`/`tail`/`jq`. Tests print **one JSON line**.
- Compute shaders: small, single-purpose kernels (`clear`, `hash`, `scan`, `scatter`, `integrate`, `contacts`, `bonds`, `finalize`). Put shared structs in one include. Keep each file < 300 lines.
- Verify visually rarely and cheaply: ≤ 960 px screenshots, only at milestone ends or when a test fails for a visual reason. Prefer numeric asserts.
- No new dependencies unless needed; prefer Godot built-ins. Do not install Godot plugins that bring large docs. Pin versions in `NOTES.md`.
- Never claim a feature works without the test number or a measured value. Report failures plainly.
- Don't touch `legacy/web/` except to move it; don't reintroduce grid CA, teleporting, or overlay drawing.
- Safe by default: no network access in the app, no telemetry, no secrets in repo. Commit only source, docs, small media (< 5 MB each); large renders go to a git-ignored `renders/`.
- Keep the German UI strings; code, comments and docs in English.

## 9. Open questions (assume defaults, ask once if wrong)

1. **Look/scale:** default = side-on 2D sim, shaded-sphere grains, dark monochrome machine, colored pieces (palette `sorbet`). Ask the owner for 3 screenshots of the reference videos to lock the look at M5.
2. **Platform for wallpaper:** default macOS (owner's machine) = looped video + fullscreen window; Windows via Lively/Wallpaper Engine is secondary.
3. **Resolution/length:** default 3840×2160 @ 60 fps, 30–60 s seamless loops.
4. **Grain count target:** default 40–100k visible grains (decided by M0 numbers).

## 10. Definition of done

M0–M6 complete; T1–T9 green; endless run ≥ 10 sim-minutes without leaks or jams outside intentional ones; 4K 60 fps Movie Maker clip rendered; `legacy/web/` removed; README updated (how to run, capture, and wallpaper-install); everything committed and pushed to `origin/main`.

Start now: M0.
