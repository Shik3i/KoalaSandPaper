# KoalaSandPaper — Audit (2026-10-08)

Scope: the JavaScript/Electron prototype in this repo (`src/`, 590 LOC). Verified by reading all source and running a diagnostic (`factory.step()` × 3600 ticks, seed 2718).

## Verdict

The prototype is a **falling-sand cellular automaton plus choreographed props**, not a physical simulation. Grains have no mass, size, velocity, friction or density. The "machine" (mixer, shredder, conveyor, laser) is mostly scripted or decorative. It cannot be tuned into the target look; the simulation core has to be replaced.

## Measured behaviour (seed 2718)

| tick | grains | in mixer bowl | collected | rotor angle (rad) |
|---|---|---|---|---|
| 600 | 1845 | 677 | 0 | 5.39 |
| 1200 | 2923 | 1680 | 0 | 5.50 |
| 2400 | 5157 | 3907 | 0 | 5.50 |
| 3600 | 5733 | 4911 | **0** | **5.50 (frozen)** |

- The rotor stops advancing after ~1200 ticks (jam: `updateRotor` returns `false` when a blade cell cannot evacuate its grain) and never recovers. The bowl overfills and nothing is ever collected.
- `npm test` fails 1 of 8 tests for this reason: `s.collected>0` in `tests/physics.test.mjs` ("factory conserves every grain…").

## Root causes (by file/function)

1. **No dynamics in the core** — `src/physics.js` `gravity()`: one cell, one move (down, then down-diagonal at random) per tick. Max speed 1 cell/tick, no velocity, no momentum, no friction, no restitution, no pressure. Pile slope is a lattice artefact (diagonal moves ⇒ ~45° by construction), not a material property. All grains behave identically; "color" is identity only.
2. **Mixer cannot mix** — `src/factory.js` `updateRotor/pushFromBlade`: blades are a *static solid mask* re-rasterised every second tick; grains are shoved one cell sideways if a neighbour is free, otherwise the rotor stalls. A blade cannot drag grains by friction because there is no friction, and a grain with no horizontal momentum falls straight back down. Bowl wall + gap (`x<489 && y 310..335`) is a hand-cut hole, not an outlet that flow can find.
3. **Shredder is not physical** — `SHREDDER_TEETH` are 10 *stationary* disks (`disk(...)`); the rotating gears are drawn by `src/render.js` `gear()` on top with no coupling to collision. Forms are *not* torn: `transport()` converts the whole bound shape into free grains in one tick once it reaches x=537 (`w.add(...)` for every pixel).
4. **Forms are not in the simulation** — tetromino "bodies" are pixel lists moved with `body.x++` every other tick. They are not rigid bodies, have no collision with grains, and are painted over the grid in `frame()`.
5. **Laser cut is a rule, not an interaction** — grains at `x===362 && p[1]%13===6` are released; no kerf, no heat, no deformation.
6. **Belt teleports** — `transport()` moves free grains with `w.move(x,107,x+1,107)` for the whole row every 2nd tick; no surface-friction transport.
7. **Rendering hides the gaps** — `render.js` redraws collision walls and gears over the grain layer ("exact collision overlay"). The picture is composed, not simulated.
8. **Resolution/perf ceiling** — 768×432 cells, 1 px grains, single JS worker, ≤8 steps per frame; a 4K wallpaper/video would be pixelated upscaling.

## What is worth keeping

- `tests/physics.test.mjs` idea of **mass-conservation + determinism** assertions (port the concept, not the code).
- Factory layout (belt → laser → shredder throat → mixer bowl → collection tray) and the visual language: 3-blade rotor, counter-rotating rollers, laser gantry, palettes `sorbet / aurora / ember`, German UI strings, Lively wallpaper packaging idea.
- `vendor/koalasand/*` is a reference snapshot of KoalaSand's Phase-1 GDScript CA (provenance in `provenance.json`). It is a grid CA like the prototype; it does not provide the physics needed here.

## Repo / dependency hygiene

- No secrets found (grep for token/secret/password/api key).
- `npm audit`: 8 moderate findings, all transitive via `electron-builder` (build tooling, not shipped). Fix is a semver-major `electron-builder` change; skip if the Electron path is retired (see AGENT_PROMPT.md).
- `electron` 44.4.3 → 44.7.0 available (patch/minor).
- `package-lock.json` was refreshed by `npm audit fix` during the workspace audit (before git existed); `dist/` is regenerated build output (git-ignored). `release/` (288 MB) is git-ignored.
- License: `package.json` says `UNLICENSED`; `vendor/koalasand/LICENSE` is all-rights-reserved. Repo is public at the owner's request; no licence is granted to third parties.
