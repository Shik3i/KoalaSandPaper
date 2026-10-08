class_name Factory
extends Machine
## The kinetic line (world 12.288 × 6.912 m, y up), one closed loop:
## bucket elevator (left) → chute → belt A (top) → press → two-stage shredder →
## mixer bowl → sweeping pusher ─┬─ belt L (←) → elevator boot
##                               └─ belt R (→) → furnace (grains glow and burn).

const WORLD := Vector2(12.288, 6.912)
const S := 0.016  # legacy plan scale (T5 geometry)

const BELT_SPEED := 0.45
const PRESS_X := 4.4
const ROTOR_OMEGA := -0.8
const OUTLET_HALF := 4.5  # deg, bottom outlet half aperture
const OUTLET_A0 := 206.8  # side outlet (T5 mixer test geometry)
const OUTLET_A1 := 220.3

const Y_A := 5.40
const Y_LOW := 0.95

var belt_top := Y_A
var spawn_at := Vector2(2.1, Y_A + 0.08)
var bowl_c := Vector2(7.6, 2.35)
var bowl_r := 0.85
var rotor_body := 0
var press_body := 0
var pusher_body := 0
var rollers: Array[int] = []
var buckets: Array[int] = []
var elev_bottom := Vector2(0.6, 0.75)
var elev_top := Vector2(0.6, 6.30)
var elev_rs := 0.2
var furnace := Rect2(9.7, 0.2, 2.5, 2.4)
## Station label anchors (world m).
var stations := {}


func _init() -> void:
	super()
	world = WORLD
	_elevator()
	_belts()
	_press()
	_shredder()
	rotor_body = build_bowl(self, bowl_c, bowl_r)
	_pusher()
	_furnace()
	stations = {
		"01 / FORMEN": Vector2(1.9, 5.95), "02 / PRESSE": Vector2(PRESS_X - 0.3, 6.45),
		"03 / MAHLWERK": Vector2(8.6, 5.0), "04 / MISCHEN": Vector2(8.6, 2.8),
		"05 / WEICHE": Vector2(8.2, 1.45), "06 / OFEN": Vector2(9.75, 2.95), "07 / AUFZUG": Vector2(1.25, 3.4),
	}
	update(0.0)


func _elevator() -> void:
	# Clockwise: up the left strand, over the head to the right, down the right.
	# Buckets are fixed to the chain, mouth in the direction of travel: they
	# scoop through the boot like shovels and throw their load off at the head.
	var b := elev_bottom
	var t := elev_top
	var rs := elev_rs
	var speed := -1.6
	var l := chain_length(b, t, rs)
	var n := 15
	for k in n:
		var body := add_body(Vector2.ZERO, 0.0, "bucket")
		chain_fixed(body, b, t, rs, speed, k * l / n)
		# Local frame: +y = travel (mouth), -x = outside of the loop.
		add_prim(body, BOX, [0.13, 0.012, 0.006], Vector2(-0.13, -0.21), 0.0, 1, 0, 0.0, "bucket")
		add_prim(body, BOX, [0.012, 0.11, 0.006], Vector2(-0.012, -0.11), 0.0, 1, 0, 0.0, "bucket")
		add_prim(body, BOX, [0.012, 0.11, 0.006], Vector2(-0.248, -0.11), 0.0, 1, 0, 0.0, "bucket")
		buckets.append(body)
	for c in [b, t]:
		var sp := add_body(c, 0.0, "sprocket")
		rotor(sp, speed / rs, 0.0)
		add_prim(sp, CIRCLE, [rs * 0.9], Vector2.ZERO, 0.0, 1, FLAG_VISUAL, 0.0, "drum")
	# Boot: round pit under the bottom sprocket, open towards belt L on the right.
	var pit := rs + 0.26 + 0.05
	add_arc(b, pit, 0.025, deg_to_rad(165.0), TAU)
	# Floor drain: spill that misses every machine is recycled (counted on sink 3).
	add_sink(Vector2(0.0, -0.1), Vector2(WORLD.x, 0.04), 3)
	# Discharge chute from the head down onto belt A.
	add_segment(Vector2(1.15, 6.42), Vector2(1.78, 5.62), 0.02)


func _belts() -> void:
	conveyor(1.3, 7.0, Y_A, BELT_SPEED)
	add_segment(Vector2(1.25, Y_A - 0.03), Vector2(1.25, Y_A + 0.35), 0.02)
	conveyor(1.05, 7.3, Y_LOW, -0.6)
	conveyor(7.9, 10.1, Y_LOW, 0.6)


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
	# Head bottom travels from 6.07 down to 5.57 (17 cm above the belt): flat
	# pieces pass, tall ones are crushed and shatter.
	press_body = add_body(Vector2(PRESS_X, 6.12), 0.0, "press")
	piston(press_body, Vector2(0.0, -1.0), 0.50, 3.3)
	add_prim(press_body, BOX, [0.26, 0.05, 0.01], Vector2.ZERO, 0.0, 1, 0, 0.0, "piston")
	add_prim(press_body, BOX, [0.035, 0.3, 0.0], Vector2(0.0, 0.35), 0.0, 1, FLAG_VISUAL, 0.0, "rod")


func _roller_pair(nip: Vector2, core: float, tip: float, half: float, teeth: int, tooth: Vector3, omega: float) -> void:
	for k in 2:
		var side := -1.0 if k == 0 else 1.0
		var body := add_body(nip + Vector2(side * half, 0.0), 0.0 if k == 0 else PI / teeth, "roller")
		# Left turns clockwise, right counter-clockwise: both feed the nip from above.
		rotor(body, -omega * side, 1.0)
		add_prim(body, CIRCLE, [core], Vector2.ZERO, 0.0, 1, 0, 0.0, "roller")
		add_prim(body, BOX, [tooth.x, tooth.y, tooth.z], Vector2(tip - tooth.x, 0.0), 0.0, teeth, 0, 0.0, "roller")
		rollers.append(body)


func _shredder() -> void:
	# Stage 1: coarse rollers (tip-to-core clearance 4 cm).
	var n1 := Vector2(7.6, 4.8)
	_roller_pair(n1, 0.20, 0.27, 0.255, 10, Vector3(0.045, 0.028, 0.01), 2.2)
	# Left guide catches spray under the belt end and leads it into the hopper.
	add_path(PackedVector2Array([Vector2(6.55, 5.22), Vector2(7.0, 4.98), Vector2(7.0, 4.55)]), 0.02)
	add_path(PackedVector2Array([Vector2(8.45, 5.55), Vector2(8.195, 5.05), Vector2(8.195, 4.55)]), 0.02)
	add_segment(Vector2(7.2, 5.86), Vector2(8.45, 5.86), 0.02)  # hood
	add_segment(Vector2(7.0, 4.55), Vector2(7.45, 4.1), 0.02)
	add_segment(Vector2(8.195, 4.55), Vector2(7.75, 4.1), 0.02)
	# Stage 2: fine fast rollers (clearance 3 cm).
	var n2 := Vector2(7.6, 3.75)
	_roller_pair(n2, 0.11, 0.15, 0.145, 8, Vector3(0.025, 0.018, 0.006), 4.5)
	add_path(PackedVector2Array([Vector2(7.45, 4.1), Vector2(7.245, 4.0), Vector2(7.245, 3.55), Vector2(7.45, 3.35)]), 0.02)
	add_path(PackedVector2Array([Vector2(7.75, 4.1), Vector2(7.955, 4.0), Vector2(7.955, 3.55), Vector2(7.75, 3.35)]), 0.02)


## Open-top bowl (rim open between 50° and 100°) with a bottom outlet and a 3-blade rotor.
static func build_bowl(m: Machine, c: Vector2, r: float) -> int:
	var t := 0.025
	m.add_arc(c, r, t, deg_to_rad(100.0), deg_to_rad(270.0 - OUTLET_HALF))
	m.add_arc(c, r, t, deg_to_rad(270.0 + OUTLET_HALF), deg_to_rad(410.0))
	var body := m.add_body(c, 0.0, "rotor")
	m.rotor(body, ROTOR_OMEGA)
	m.add_prim(body, CIRCLE, [0.2], Vector2.ZERO, 0.0, 1, 0, 0.0, "rotor")
	m.add_prim(body, CAPSULE, [0.27, 0.03], Vector2(0.48, 0.0), deg_to_rad(-10.0), 3, 0, 0.0, "rotor")
	return body


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
	# The outlet stream lands on a shelf; a pusher plate sweeps left and right and
	# shoves the sand over the edges: left onto belt L (back to the elevator),
	# right onto belt R (into the furnace). A mechanical 50/50 split.
	var y := 1.2
	add_segment(Vector2(7.25, y), Vector2(7.95, y), 0.015)
	pusher_body = add_body(Vector2(7.2, y + 0.09), 0.0, "pusher")
	piston(pusher_body, Vector2(1.0, 0.0), 0.8, 4.0)
	add_prim(pusher_body, BOX, [0.018, 0.075, 0.006], Vector2.ZERO, 0.0, 1, 0, 0.0, "piston")
	add_prim(pusher_body, BOX, [0.6, 0.012, 0.0], Vector2(0.62, 0.05), 0.0, 1, FLAG_VISUAL, 0.0, "rod")


func _furnace() -> void:
	var f := furnace
	add_segment(Vector2(f.position.x, f.position.y), Vector2(f.end.x, f.position.y), 0.03)
	add_segment(Vector2(f.position.x, f.position.y - 0.03), Vector2(f.position.x, 0.62), 0.03)
	add_segment(Vector2(f.position.x, Y_LOW + 0.3), Vector2(f.position.x, f.end.y), 0.03)
	add_segment(Vector2(f.end.x, f.position.y - 0.03), Vector2(f.end.x, f.end.y), 0.03)
	add_segment(Vector2(f.position.x, f.end.y), Vector2(f.end.x, f.end.y), 0.03)
	add_heat(Vector2(f.position.x + 0.05, f.position.y + 0.02), Vector2(f.end.x - 0.05, 1.3), 2)
	# Chimney (drawn only).
	add_prim(0, BOX, [0.22, 2.1, 0.0], Vector2(f.end.x - 0.6, f.end.y + 2.1), 0.0, 1, FLAG_VISUAL, 0.0, "wall")


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
