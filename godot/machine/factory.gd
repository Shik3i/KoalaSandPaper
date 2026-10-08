class_name Factory
extends Machine
## The production line, laid out on the legacy 768×432 plan (1 plan px = S m,
## plan y points down): belt → laser → toothed rollers → hopper → mixer bowl
## with side outlet → chute → tray with piston → drain.

const S := 0.016
const WORLD := Vector2(768 * S, 432 * S)

const BELT_SPEED := 0.45
const ROLLER_OMEGA := 2.0
const ROTOR_OMEGA := -0.6
const OUTLET_A0 := 206.8
const OUTLET_A1 := 220.3
const PISTON_PERIOD := 8.0
const LASER_X := 362 * S
const LASER_PERIOD := 0.5
const LASER_ON := 0.12

var belt_top := 0.0
var belt_x := Vector2.ZERO
var bowl_c := Vector2.ZERO
var bowl_r := 0.0
var rollers: Array[int] = []
var rotor_body := 0
var piston_body := 0
var laser_top := Vector2.ZERO
var spawn_at := Vector2.ZERO
## Station label anchors (world m) for the HUD.
var stations := {}


static func plan(x: float, y: float) -> Vector2:
	return Vector2(x * S, (432.0 - y) * S)


func _init() -> void:
	super()
	_belt()
	_shredder()
	_bowl()
	_tray()
	stations = {"01 / FORMEN": plan(90, 70), "02 / SCHNITT": plan(362, 40), "03 / MAHLWERK": plan(575, 40),
		"04 / MISCHEN": bowl_c + Vector2(-bowl_r - 0.6, bowl_r + 0.1), "05 / SAMMELN": plan(150, 395)}
	update(0.0)


func _belt() -> void:
	var a := plan(48, 108)
	var b := plan(537, 108)
	belt_top = a.y
	belt_x = Vector2(a.x, b.x)
	var t := 0.04
	add_prim(0, BOX, [(b.x - a.x) * 0.5, t, t], Vector2((a.x + b.x) * 0.5, a.y - t), 0.0, 1, 0, BELT_SPEED, "belt")
	spawn_at = Vector2(a.x + 0.25, a.y + 0.004)
	laser_top = Vector2(LASER_X, a.y + 0.55)


func _shredder() -> void:
	var nip := Vector2(belt_x.y + 0.55, belt_top - 0.65)
	var core := 0.22
	var tip := 0.30
	var half := 0.285
	for k in 2:
		var side := -1.0 if k == 0 else 1.0
		var body := add_body(nip + Vector2(side * half, 0.0), 0.0 if k == 0 else PI / 10.0, "roller")
		# Left turns clockwise, right counter-clockwise: both feed the nip from above.
		rotor(body, -ROLLER_OMEGA * side)
		add_prim(body, CIRCLE, [core], Vector2.ZERO, 0.0, 1, 0, 0.0, "roller")
		add_prim(body, BOX, [0.05, 0.03, 0.012], Vector2(tip - 0.05, 0.0), 0.0, 10, 0, 0.0, "roller")
		rollers.append(body)
	# Guides keep pieces from bypassing the rollers (≥6 cm clear of the tooth tips).
	var lx := nip.x - 0.67
	var rx := nip.x + 0.66
	var yh := nip.y - 0.43
	add_segment(Vector2(lx, belt_top - 0.12), Vector2(lx, yh), 0.02, "wall")
	add_segment(Vector2(nip.x + 0.95, belt_top + 0.1), Vector2(rx, nip.y + 0.25), 0.02, "wall")
	# Hood: catches fragments thrown up by the teeth; pieces enter below it.
	add_segment(Vector2(belt_x.y + 0.25, belt_top + 0.32), Vector2(nip.x + 0.95, belt_top + 0.32), 0.02, "wall")
	add_segment(Vector2(rx, nip.y + 0.25), Vector2(rx, yh), 0.02, "wall")
	# Hopper at 45° (steeper than the 32° repose) into a 0.4 m neck above the rotor sweep.
	add_segment(Vector2(lx, yh), Vector2(nip.x - 0.2, yh - (nip.x - 0.2 - lx)), 0.02, "wall")
	add_segment(Vector2(rx, yh), Vector2(nip.x + 0.2, yh - (rx - nip.x - 0.2)), 0.02, "wall")


func _bowl() -> void:
	bowl_c = plan(550, 274) - Vector2(0.0, 0.35)
	bowl_r = 80 * S
	rotor_body = build_mixer(self, bowl_c, bowl_r)


## Open-top bowl with a side outlet on the lower left (OUTLET_A0..A1), rim up to
## 110° on the rising (left) side and 60° on the right, 3-blade rotor and a 40°
## outlet chute. Returns the rotor body.
static func build_mixer(m: Machine, c: Vector2, r: float, chute := true) -> int:
	var t := 0.025
	m.add_arc(c, r, t, deg_to_rad(110.0), deg_to_rad(OUTLET_A0), "wall")
	m.add_arc(c, r, t, deg_to_rad(OUTLET_A1), deg_to_rad(420.0), "wall")
	var body := m.add_body(c, 0.0, "rotor")
	m.rotor(body, ROTOR_OMEGA)
	m.add_prim(body, CIRCLE, [0.35], Vector2.ZERO, 0.0, 1, 0, 0.0, "rotor")
	m.add_prim(body, CAPSULE, [0.42, 0.035], Vector2(0.74, 0.0), deg_to_rad(-10.0), 3, 0, 0.0, "rotor")
	if chute:
		var dir := Vector2.from_angle(deg_to_rad(220.0))
		var lo := c + Vector2.from_angle(deg_to_rad(OUTLET_A1)) * r
		var hi := c + Vector2.from_angle(deg_to_rad(OUTLET_A0)) * (r + 0.02)
		m.add_segment(lo, lo + dir * 0.85, 0.02, "wall")
		m.add_segment(hi, hi + dir * 1.0, 0.02, "wall")
	return body


## Loose hex fill of the lower bowl, clear of all colliders. Left half palette
## colours 0-2 (material A), right half 3-5 (B).
static func fill_bowl(m: Machine, c: Vector2, r: float, n: int, rng: RandomNumberGenerator, top := 0.2) -> ParticleSet:
	var g := SimConst.R_MAX * 1.02
	var dy := 2.0 * g * sqrt(3.0) * 0.5
	var s := ParticleSet.new()
	var row := 0
	var y := c.y - r + 0.04
	while s.size() < n and y < c.y + top:
		var x := c.x - r + (g if row % 2 == 1 else 0.0)
		while x < c.x + r and s.size() < n:
			var p := Vector2(x, y)
			if p.distance_to(c) < r - 0.04 and m.sdf(p) > 1.5 * g:
				var half := 0 if x < c.x else 3
				s.add(p, Spawn.grain_radius(rng), GpuSolver.info_word(1, 0), Spawn.vary(Spawn.SORBET[half + rng.randi() % 3], rng))
			x += 2.0 * g
		y += dy
		row += 1
	return s


func _tray() -> void:
	var y := 0.30
	add_segment(Vector2(4.40, y), Vector2(9.75, y), 0.025, "wall")
	add_segment(Vector2(3.80, y - 0.05), Vector2(3.80, y + 0.45), 0.025, "wall")
	# Head bottom 2 mm above the floor surface: no grain fits under it.
	piston_body = add_body(Vector2(9.80, y + 0.025 + 0.002 + 0.12), 0.0, "piston")
	piston(piston_body, Vector2.LEFT, 4.6, PISTON_PERIOD)
	add_prim(piston_body, BOX, [0.05, 0.12, 0.01], Vector2.ZERO, 0.0, 1, 0, 0.0, "piston")
	add_prim(piston_body, BOX, [1.2, 0.025, 0.0], Vector2(1.25, 0.06), 0.0, 1, FLAG_VISUAL, 0.0, "rod")
	add_sink(Vector2(3.55, 0.0), Vector2(4.65, 0.2), 0)
	# Floor drain: anything that misses the tray is recycled too (counted separately).
	add_sink(Vector2(0.0, -0.1), Vector2(WORLD.x, 0.03), 1)


## Laser beam segment at time t (Vector2.ZERO pair when off).
func laser(t: float) -> Array:
	if fmod(t, LASER_PERIOD) < LASER_ON:
		return [laser_top, Vector2(LASER_X, belt_top - 0.002)]
	return [Vector2.ZERO, Vector2.ZERO]
