class_name SimConst
## Single source of physics constants. SI units; y up.

const G := 9.81
const GRAVITY := Vector2(0.0, -G)

## Grain radius (m). Scale decision: see docs/NOTES.md.
const R := 0.005
## Radius spread (uniform ±POLY·R) against hex crystallisation.
const POLY := 0.1
const R_MAX := R * (1.0 + POLY)

const DT := 1.0 / 60.0
## DEM steps per frame and contact duration in steps: t_c = 7 / 2880 s ≈ 2.4 ms
## gives k/m ≈ 0.8e6 s^-2, i.e. ≈ 0.12 R overlap at the bottom of a 0.5 m heap.
## (64 or 96 steps give the same test results, see docs/NOTES.md.)
const SUBSTEPS := 48
const TC_STEPS := 7.0
## Air drag rate (1/s); factor per step = exp(-DAMPING * dt).
const DAMPING := 0.0
## A rigid piece breaks when it is squeezed (sum |F_i| - |sum F_i| over its
## contact forces) by more than this many grain weights for CRUSH_STEPS
## (dem_rigid.glsl). A piece has ~700 grains; resting or landing gives ~0.
const CRUSH_G := 300.0
## Contact damping of rigid grains uses this multiple of the grain mass (a piece
## lands on ~16 grains: without it, pieces would bounce).
const RIGID_DAMP_MASS := 16.0

const SAND_DENSITY := 1600.0
## Grain friction 0.35 (non-rotating discs) is calibrated against two dry-sand
## references: angle of repose ≈ 32° (T2) and quasi-2D column collapse runout
## (L∞ - L0)/L0 ≈ 1.2 a (Lube et al. 2005) (tests/q_sand.gd).
const REPOSE_DEG := 32.0

## Material table. id = index. Colors live per particle, not per material.
const MATERIALS := [
	{"name": "sand", "mu_s": 0.35, "mu_k": 0.35, "restitution": 0.1, "density": SAND_DENSITY},
	{"name": "piece", "mu_s": 0.6249, "mu_k": 0.6249, "restitution": 0.03, "density": SAND_DENSITY,
		"break_strain": 0.04},
]


static func mass(density: float, r: float = R) -> float:
	return density * 4.0 / 3.0 * PI * r * r * r
