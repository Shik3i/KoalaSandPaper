class_name Factory
extends Machine
## The kinetic line (world 12.288 × 6.912 m, y up), one closed loop:
## inclined bucket elevator (left) → head chute → belt A → press → two-stage
## shredder → mixer bowl → floor with a chain-driven pusher blade ─┬─ left: elevator pit
##                                                                 └─ right: furnace (glow, burn)

const WORLD := Vector2(12.288, 6.912)
const S := 0.016  # legacy plan scale (T5 geometry)

const BELT_SPEED := 0.45
const PRESS_X := 6.0
const ROTOR_OMEGA := -0.8
const OUTLET_HALF := 12.0  # deg, bottom outlet half aperture (35 cm)
const OUTLET_A0 := 206.8  # side outlet (T5 mixer test geometry)
const OUTLET_A1 := 220.3

const Y_A := 5.20
const Y_FLOOR := 0.90
const ELEV_SPEED := 0.5

var belt_top := Y_A
var spawn_at := Vector2(4.5, Y_A + 0.08)
var bowl_c := Vector2(8.4, 2.45)
var bowl_r := 0.85
var rotor_body := 0
var press_body := 0
var pusher_body := 0
var rollers: Array[int] = []
var buckets: Array[int] = []
# Leaning ~24° right: the empty return strand moves out from under the head, so
# the gravity discharge falls clear onto the chute.
var elev_bottom := Vector2(0.8, 0.75)
var elev_top := Vector2(3.2, 6.25)
var elev_rs := 0.2
var floor_x := Vector2(1.5, 10.2)
var furnace := Rect2(10.0, 0.2, 2.2, 2.2)
## Station label anchors (world m).
var stations := {}


func _init() -> void:
	super()
	world = WORLD
	_elevator()
	conveyor(3.95, 7.8, Y_A, BELT_SPEED)
	_press()
	_shredder()
	rotor_body = build_bowl(self, bowl_c, bowl_r)
	_pusher()
	_furnace()
	stations = {
		"01 / FORMEN": Vector2(4.3, 5.75), "02 / PRESSE": Vector2(5.65, 6.6),
		"03 / MAHLWERK": Vector2(9.4, 4.8), "04 / MISCHEN": Vector2(9.4, 3.0),
		"05 / SCHIEBER": Vector2(4.6, 1.45), "06 / OFEN": Vector2(10.35, 2.75), "07 / AUFZUG": Vector2(2.6, 3.0),
	}
	update(0.0)


func _elevator() -> void:
	# Clockwise (negative speed): up the upper-left strand, over the head, down the
	# lower-right strand. Buckets are fixed to the chain with the mouth in the
	# direction of travel: they scoop through the pit like shovels and empty by
	# gravity once inverted past the head.
	var b := elev_bottom
	var t := elev_top
	var rs := elev_rs
	var l := chain_length(b, t, rs)
	var n := int(l / 0.7)
	for k in n:
		var body := add_body(Vector2.ZERO, 0.0, "bucket")
		chain_fixed(body, b, t, rs, -ELEV_SPEED, k * l / n)
		# Local frame: +y = travel (mouth), -x = outside of the loop.
		add_prim(body, BOX, [0.13, 0.012, 0.006], Vector2(-0.13, -0.21), 0.0, 1, 0, 0.0, "bucket")
		add_prim(body, BOX, [0.012, 0.11, 0.006], Vector2(-0.012, -0.11), 0.0, 1, 0, 0.0, "bucket")
		add_prim(body, BOX, [0.012, 0.11, 0.006], Vector2(-0.248, -0.11), 0.0, 1, 0, 0.0, "bucket")
		buckets.append(body)
	for c in [b, t]:
		var sp := add_body(c, 0.0, "sprocket")
		rotor(sp, -ELEV_SPEED / rs, 0.0)
		add_prim(sp, CIRCLE, [rs * 0.9], Vector2.ZERO, 0.0, 1, FLAG_VISUAL, 0.0, "drum")
	# Pit: arc under the boot sprocket from the -n side (156°) round to the +n side (336°).
	var u := (t - b).normalized()
	var nrm := Vector2(u.y, -u.x)
	# Bucket corner radius around the sprocket: sqrt((rs + depth)² + length²), + 7.5 cm (5 cm clear of the 2.5 cm wall).
	var pit := Vector2(rs + 0.26, 0.222).length() + 0.075
	add_arc(b, pit, 0.025, (-nrm).angle(), nrm.angle() + TAU)
	# Feed plate (43°) from the floor end down into the pit, outside the bucket sweep.
	var pit_end := b + nrm * pit
	add_segment(Vector2(floor_x.x + 0.1, Y_FLOOR - 0.04), pit_end, 0.02)
	# Head chute onto belt A (37°), ≥ 5 cm clear of the return-strand buckets and cleats.
	add_segment(Vector2(3.62, 5.74), Vector2(4.15, 5.33), 0.02)
	# Floor drain: spill that misses every machine is recycled (counted on sink 3).
	add_sink(Vector2(0.0, -0.1), Vector2(WORLD.x, 0.04), 3)


## Belt slab (friction drive on its top face) plus cleats that circulate around
## both drums at belt speed and visibly push the load.
func conveyor(x0: float, x1: float, top: float, speed: float, spacing := 0.5) -> void:
	var t := 0.04
	add_belt(x0, x1, top, speed, t)
	var p0 := Vector2(x0 + t, top - t)
	var p1 := Vector2(x1 - t, top - t)
	var l := loop_length(p0, p1, t)
	var n := maxi(int(l / spacing), 2)
	for k in n:
		var body := add_body(Vector2.ZERO, 0.0, "cleat")
		loop(body, p0, p1, t, speed, k * l / n)
		add_prim(body, BOX, [0.01, 0.022, 0.006], Vector2(0.0, 0.02), 0.0, 1, 0, 0.0, "cleat")
	for x in [x0 + t, x1 - t]:
		var drum := add_body(Vector2(x, top - t), 0.0, "drum")
		rotor(drum, -speed / t, 0.0)
		add_prim(drum, CIRCLE, [t * 0.8], Vector2.ZERO, 0.0, 1, FLAG_VISUAL, 0.0, "drum")


func _press() -> void:
	# Head bottom travels from 5.87 down to 5.37 (17 cm above the belt): flat
	# pieces pass, tall ones are crushed and shatter.
	press_body = add_body(Vector2(PRESS_X, 5.92), 0.0, "press")
	piston(press_body, Vector2(0.0, -1.0), 0.50, 3.3)
	add_prim(press_body, BOX, [0.26, 0.05, 0.01], Vector2.ZERO, 0.0, 1, 0, 0.0, "piston")
	add_prim(press_body, BOX, [0.035, 0.3, 0.0], Vector2(0.0, 0.35), 0.0, 1, FLAG_VISUAL, 0.0, "rod")


func _roller_pair(nip: Vector2, core: float, tip: float, half: float, teeth: int, tooth: Vector3, omega: float) -> void:
	for k in 2:
		var side := -1.0 if k == 0 else 1.0
		var body := add_body(nip + Vector2(side * half, 0.0), 0.0 if k == 0 else PI / teeth, "roller")
		# Left turns clockwise (ω < 0), right counter-clockwise: both tops run into the nip.
		rotor(body, omega * side, 1.0)
		add_prim(body, CIRCLE, [core], Vector2.ZERO, 0.0, 1, 0, 0.0, "roller")
		add_prim(body, BOX, [tooth.x, tooth.y, tooth.z], Vector2(tip - tooth.x, 0.0), 0.0, teeth, 0, 0.0, "roller")
		rollers.append(body)


func _shredder() -> void:
	# Stage 1: coarse rollers (tip-to-core clearance 5 cm).
	var n1 := Vector2(8.4, 4.6)
	_roller_pair(n1, 0.20, 0.27, 0.26, 10, Vector3(0.045, 0.028, 0.01), 2.4)
	# Left guide catches spray under the belt end and leads it into the hopper.
	add_path(PackedVector2Array([Vector2(7.2, 5.04), Vector2(7.8, 4.6), Vector2(7.8, 4.35)]), 0.02)
	# Housing: hood over the rollers closed down the right side (no spray escapes).
	add_path(PackedVector2Array([Vector2(8.0, 5.66), Vector2(9.25, 5.66), Vector2(9.25, 5.35), Vector2(8.995, 4.85), Vector2(8.995, 4.35)]), 0.02)
	add_segment(Vector2(7.8, 4.35), Vector2(8.25, 3.9), 0.02)
	add_segment(Vector2(8.995, 4.35), Vector2(8.55, 3.9), 0.02)
	# Stage 2: fine fast rollers (clearance 5 cm).
	var n2 := Vector2(8.4, 3.66)
	_roller_pair(n2, 0.11, 0.15, 0.155, 8, Vector3(0.025, 0.018, 0.006), 5.5)
	add_path(PackedVector2Array([Vector2(8.25, 3.9), Vector2(8.035, 3.86), Vector2(8.035, 3.5), Vector2(8.25, 3.3)]), 0.02)
	add_path(PackedVector2Array([Vector2(8.55, 3.9), Vector2(8.765, 3.86), Vector2(8.765, 3.5), Vector2(8.55, 3.3)]), 0.02)


## Bowl with a bottom outlet and a 3-blade rotor; the top opening (75°..105°) is
## only as wide as the feed neck, so the rotor cannot fling sand out.
static func build_bowl(m: Machine, c: Vector2, r: float) -> int:
	var t := 0.025
	m.add_arc(c, r, t, deg_to_rad(105.0), deg_to_rad(270.0 - OUTLET_HALF))
	m.add_arc(c, r, t, deg_to_rad(270.0 + OUTLET_HALF), deg_to_rad(435.0))
	var body := m.add_body(c, 0.0, "rotor")
	m.rotor(body, ROTOR_OMEGA)
	m.add_prim(body, CIRCLE, [0.2], Vector2.ZERO, 0.0, 1, 0, 0.0, "rotor")
	m.add_prim(body, CAPSULE, [0.27, 0.03], Vector2(0.48, 0.0), deg_to_rad(-10.0), 3, 0, 0.0, "rotor")
	return body


## Side-outlet bowl used by the T5 mixer test (legacy geometry).
static func build_mixer(m: Machine, c: Vector2, r: float, chute := true) -> int:
	var t := 0.025
	m.add_arc(c, r, t, deg_to_rad(110.0), deg_to_rad(OUTLET_A0))
	m.add_arc(c, r, t, deg_to_rad(OUTLET_A1), deg_to_rad(420.0))
	var body := m.add_body(c, 0.0, "rotor")
	m.rotor(body, -0.6)
	m.add_prim(body, CIRCLE, [0.35], Vector2.ZERO, 0.0, 1, 0, 0.0, "rotor")
	m.add_prim(body, CAPSULE, [0.42, 0.035], Vector2(0.74, 0.0), deg_to_rad(-10.0), 3, 0, 0.0, "rotor")
	if chute:
		var dir := Vector2.from_angle(deg_to_rad(220.0))
		var lo := c + Vector2.from_angle(deg_to_rad(OUTLET_A1)) * r
		var hi := c + Vector2.from_angle(deg_to_rad(OUTLET_A0)) * (r + 0.02)
		m.add_segment(lo, lo + dir * 0.85, 0.02)
		m.add_segment(hi, hi + dir * 1.0, 0.02)
	return body


func _pusher() -> void:
	# A heavy pusher blade on a telescopic cylinder sweeps the whole floor without
	# ever stopping: sand from the outlet ahead of it is shoved right into the
	# furnace, sand that falls behind it while it is on the furnace side is shoved
	# left into the elevator pit. It runs slower on the furnace side (phase
	# modulation a = 0.643), so it is right of the outlet exactly half the time:
	# a 50/50 split.
	add_segment(Vector2(floor_x.x, Y_FLOOR), Vector2(floor_x.y, Y_FLOOR), 0.025)
	var half := Vector2(0.045, 0.13)
	var y := Y_FLOOR + 0.025 + 0.003 + half.y
	var x0 := floor_x.x + 0.18
	var stroke := floor_x.y - 0.08 - x0
	pusher_body = add_body(Vector2(x0, y), 0.0, "pusher")
	var outlet := (bowl_c.x - x0) / stroke
	piston_swept(pusher_body, Vector2(1.0, 0.0), stroke, 16.0, _split_modulation(outlet))
	add_prim(pusher_body, BOX, [half.x, half.y, 0.003], Vector2.ZERO, 0.0, 1, 0, 0.0, "piston")


## Phase modulation a such that x = (1 - cos(τ + a sin τ)) / 2 exceeds `outlet`
## for half of the cycle: τ1 = π/2 must map to acos(1 - 2·outlet).
static func _split_modulation(outlet: float) -> float:
	return clampf(acos(1.0 - 2.0 * outlet) - PI * 0.5, -0.9, 0.9)


func _furnace() -> void:
	var f := furnace
	add_segment(Vector2(f.position.x, f.position.y), Vector2(f.end.x, f.position.y), 0.03)
	add_segment(Vector2(f.position.x, f.position.y - 0.03), Vector2(f.position.x, Y_FLOOR - 0.03), 0.03)
	add_segment(Vector2(f.position.x + 0.3, Y_FLOOR + 0.4), Vector2(f.position.x + 0.3, f.end.y), 0.03)
	add_segment(Vector2(f.end.x, f.position.y - 0.03), Vector2(f.end.x, f.end.y), 0.03)
	add_segment(Vector2(f.position.x + 0.3, f.end.y), Vector2(f.end.x, f.end.y), 0.03)
	add_heat(Vector2(f.position.x + 0.05, f.position.y + 0.02), Vector2(f.end.x - 0.05, 1.2), 2)
	# Chimney (drawn only).
	add_prim(0, BOX, [0.2, 2.25, 0.0], Vector2(f.end.x - 0.55, f.end.y + 2.25), 0.0, 1, FLAG_VISUAL, 0.0, "wall")


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
