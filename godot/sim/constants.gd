class_name SimConst
## Single source of physics constants. SI units; y up.

const G := 9.81
const GRAVITY := Vector2(0.0, -G)

## Grain radius (m). Scale decision: see docs/NOTES.md.
const R := 0.005

const DT := 1.0 / 60.0
const SUBSTEPS := 6
const ITERATIONS := 1
const OMEGA := 1.0
## Velocity damping rate (1/s); factor per substep = exp(-DAMPING * h).
const DAMPING := 0.0
## Shock-propagation strength for stacking (0 = off).
const STACK_K := 0.0

const SAND_DENSITY := 1600.0

## Material table. id = index. Colors live per particle, not per material.
const MATERIALS := [
	{"name": "sand", "mu_s": 0.6249, "mu_k": 0.5317, "restitution": 0.15, "density": SAND_DENSITY},
]


static func mass(density: float, r: float = R) -> float:
	return density * 4.0 / 3.0 * PI * r * r * r
