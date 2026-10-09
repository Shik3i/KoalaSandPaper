class_name Factory
extends Machine
## The kinetic line (world 12.288 × 6.912 m, y up), one closed loop:
## inclined bucket elevator (left) → head chute → belt A → press → two-stage
## shredder → mixer bowl → floor swept by a ram (telescopic cylinder from the
## furnace wall) ─┬─ left: elevator pit
##                └─ right: furnace (glow, burn)

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
## Pusher head (car-piston sized: 32 × 34 cm), sweep period and telescopic stages.
const PUSHER_HALF := Vector2(0.16, 0.17)
const PUSHER_PERIOD := 18.0
const STAGES := 6
## Collision half height of the ram's rod (all stages and the barrel, flush).
const ROD_HALF := 0.095

var belt_top := Y_A
var spawn_at := Vector2(4.5, Y_A + 0.08)
var bowl_c := Vector2(8.4, 2.45)
var bowl_r := 0.85
var rotor_body := 0
var press_body := 0
var pusher_body := 0
var stages: Array[int] = []
var stage_len := 1.0
var barrel := Rect2()
var rod_prim := -1
var rod_anchor := 0.0
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
## Map: "factory" (rotor mixer) or "galton" (Galton board with bins and a slide gate).
var map := "factory"
## Galton map: x of the bin centres, bins' bottom/top, gate body.
var bin_x: Array[float] = []
var bins := Rect2()
var gate_body := 0


func _init(map_name := "factory") -> void:
	super()
	world = WORLD
	map = map_name
	_elevator()
	conveyor(3.95, 7.8, Y_A, BELT_SPEED)
	_press()
	_shredder()
	if map == "galton":
		_galton()
	else:
		rotor_body = build_bowl(self, bowl_c, bowl_r)
	_pusher()
	_furnace()
	stations = {
		"01 / FORMEN": Vector2(4.3, 5.75), "02 / PRESSE": Vector2(5.65, 6.6),
		"03 / MAHLWERK": Vector2(9.4, 4.8), "04 / MISCHEN" if map != "galton" else "04 / GALTONBRETT": Vector2(9.4, 3.0),
		"05 / SCHIEBER": Vector2(4.6, 1.45), "06 / OFEN": Vector2(10.35, 2.75), "07 / AUFZUG": Vector2(2.6, 3.0),
	}
	update(0.0)


## Galton board under the shredder: 12 rows of pegs (each grain bounces left or
## right at every row), 13 bins below where the sand stacks up into a binomial
## (bell) profile, and a slide gate under the bins that opens every few seconds
## and drops the whole distribution onto the floor for the ram.
func _galton() -> void:
	var dx := 0.09
	var dy := dx * sqrt(3.0) * 0.5
	var rows := 12
	var n_bins := rows + 2
	var cx := bowl_c.x
	# Throat: the shredder outlet narrows to 10 cm (10 grains: 6 would arch and
	# jam, see T4), so every grain enters the board near the same point.
	add_segment(Vector2(cx - 0.15, 3.3), Vector2(cx - 0.05, 3.21), 0.012)
	add_segment(Vector2(cx + 0.15, 3.3), Vector2(cx + 0.05, 3.21), 0.012)
	# Pegs: a full-width staggered field (not a triangle), so grains keep bouncing
	# at every row and never slide down a side wall into the outer bins.
	var top := 3.14
	for r in rows:
		var cols := n_bins if r % 2 == 0 else n_bins - 1
		for k in cols:
			var x := cx + (k - (cols - 1) * 0.5) * dx
			add_prim(0, CIRCLE, [0.017], Vector2(x, top - r * dy), 0.0, 1, 0, 0.0, "peg")
	var y_bot := 1.48
	var y_top := top - rows * dy + 0.02
	var x0 := cx - (n_bins - 1) * 0.5 * dx
	# Side walls of the board and bin dividers (dividers end just under the last row).
	add_segment(Vector2(x0 - 0.5 * dx, y_bot + 0.004), Vector2(x0 - 0.5 * dx, top + 0.06), 0.012)
	add_segment(Vector2(x0 + (n_bins - 0.5) * dx, y_bot + 0.004), Vector2(x0 + (n_bins - 0.5) * dx, top + 0.06), 0.012)
	bin_x.clear()
	for k in n_bins:
		bin_x.append(x0 + k * dx)
		if k > 0:
			var x := x0 + (k - 0.5) * dx
			add_segment(Vector2(x, y_bot + 0.004), Vector2(x, y_top), 0.006)
	bins = Rect2(x0 - 0.5 * dx, y_bot, n_bins * dx, y_top - y_bot)
	# Slide gate: a plate under the bins (top face at y_bot, a wiper seal under the
	# dividers) that slides left out from under them.
	var half := Vector2(bins.size.x * 0.5 + 0.03, 0.02)
	var travel := bins.size.x + 0.1
	gate_body = add_body(Vector2(bins.get_center().x - travel, y_bot - half.y), 0.0, "gate")
	gate(gate_body, Vector2(1.0, 0.0), travel, 18.0, 0.7, 1.6)
	add_prim(gate_body, BOX, [half.x, half.y, 0.002], Vector2.ZERO, 0.0, 1, 0, 0.0, "piston")


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
	# Casing: straight walls continuing the pit arc up both strands, so spill from
	# the climbing buckets stays inside and slides back into the pit (a real bucket
	# elevator runs enclosed). Openings: below the right wall for the floor feed,
	# above it for the discharge onto the head chute.
	var up := u
	var left0 := b - nrm * pit
	add_segment(left0, left0 + up * ((t - b).length() + 0.25), 0.025)
	var right0 := b + nrm * pit
	var s_lo := (1.6 - right0.y) / up.y
	var s_hi := (5.3 - right0.y) / up.y
	add_segment(right0 + up * s_lo, right0 + up * s_hi, 0.025)
	# Head chute onto belt A (37°), ≥ 5 cm clear of the return-strand buckets and cleats.
	add_segment(Vector2(3.62, 5.74), Vector2(4.15, 5.33), 0.02)
	# Floor drain: spill that misses every machine is recycled (counted on sink 3).
	add_sink(Vector2(0.0, -0.1), Vector2(WORLD.x, 0.12), 3)


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
	add_path(PackedVector2Array([Vector2(7.3, 4.95), Vector2(7.8, 4.6), Vector2(7.8, 4.35)]), 0.02)
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
## outlet_half = 0 closes the bottom (mixing test).
static func build_bowl(m: Machine, c: Vector2, r: float, outlet_half := OUTLET_HALF) -> int:
	var t := 0.025
	if outlet_half > 0.0:
		m.add_arc(c, r, t, deg_to_rad(105.0), deg_to_rad(270.0 - outlet_half))
		m.add_arc(c, r, t, deg_to_rad(270.0 + outlet_half), deg_to_rad(435.0))
	else:
		m.add_arc(c, r, t, deg_to_rad(105.0), deg_to_rad(435.0))
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
	# Ram feeder: a heavy piston head on a six-stage hydraulic telescopic cylinder
	# whose barrel sits in the furnace's right wall. It sweeps the whole floor
	# without ever stopping: going left it shoves sand into the elevator pit, going
	# right into the furnace. Sand from the outlet lands on the side of the head
	# that faces the outlet; the stroke is phase-modulated so the head is left of
	# the outlet exactly half the time: a 50/50 split. Every stage collides.
	add_segment(Vector2(floor_x.x, Y_FLOOR), Vector2(floor_x.y, Y_FLOOR), 0.025)
	var half := PUSHER_HALF
	# Sole 1 mm into the floor plate: a wiper seal, nothing passes underneath.
	var y := Y_FLOOR + 0.025 - 0.001 + half.y
	var home := Vector2(floor_x.y + 0.02 + half.x, y)
	var stroke := home.x - (floor_x.x + 0.04 + half.x)
	pusher_body = add_body(home, 0.0, "pusher")
	var outlet := (home.x - bowl_c.x) / stroke
	piston_swept(pusher_body, Vector2(-1.0, 0.0), stroke, PUSHER_PERIOD, _split_modulation(outlet))
	# Sharp edges (2 mm): a rounded sole would wedge grains into the floor and pop them out.
	add_prim(pusher_body, BOX, [half.x, half.y, 0.002], Vector2.ZERO, 0.0, 1, 0, 0.0, "piston_head")
	# Barrel (static) from the retracted head to the furnace wall, flush with the
	# rod (ROD_HALF). The six stages are drawn only: nested colliders would stack
	# two springs where stages overlap and flick grains up at every joint. One rod
	# collider spans head to barrel, its length updated every frame (update()).
	var a := home.x + half.x + 0.04
	barrel = Rect2(a, y - ROD_HALF, furnace.end.x - a, 2.0 * ROD_HALF)
	var bk := add_prim(0, BOX, [barrel.size.x * 0.5, ROD_HALF, 0.002], barrel.get_center(), 0.0, 1, 0, 0.0, "barrel")
	prims[bk]["draw_hh"] = 0.12
	# Stages, thickest first: stage k spans [x_k, x_k + L] with
	# x_k = a + (h - a) (k + 1) / N, h = head's right face (the last stage carries the head).
	var n := STAGES
	var l := minf(barrel.size.x - 0.05, stroke / n + 0.12)
	stage_len = l
	stages.clear()
	for k in n:
		var body := add_body(Vector2(a + l * 0.5, y), 0.0, "stage")
		follow(body, pusher_body, Vector2(a, y), Vector2(half.x, 0.0), float(k + 1) / n, Vector2(l * 0.5, 0.0))
		var sk := add_prim(body, BOX, [l * 0.5, ROD_HALF, 0.002], Vector2.ZERO, 0.0, 1, FLAG_VISUAL, 0.0, "stage")
		prims[sk]["draw_hh"] = 0.106 - 0.004 * k
		stages.append(body)
	rod_anchor = a
	var rod := add_body(Vector2(a, y), 0.0, "rod")
	follow(rod, pusher_body, Vector2(a, y), Vector2(half.x, 0.0), 0.5, Vector2.ZERO)
	rod_prim = add_prim(rod, BOX, [stroke * 0.5, ROD_HALF, 0.002], Vector2.ZERO, 0.0, 1, 0, 0.0, "rodcol")


## Phase modulation a such that x = (1 - cos(τ + a sin τ)) / 2 exceeds `outlet`
## for half of the cycle: τ1 = π/2 must map to acos(1 - 2·outlet).
static func _split_modulation(outlet: float) -> float:
	return clampf(acos(1.0 - 2.0 * outlet) - PI * 0.5, -0.9, 0.9)


func _furnace() -> void:
	var f := furnace
	add_segment(Vector2(f.position.x, f.position.y), Vector2(f.end.x, f.position.y), 0.03)
	add_segment(Vector2(f.position.x, f.position.y - 0.03), Vector2(f.position.x, Y_FLOOR - 0.03), 0.03)
	add_segment(Vector2(f.position.x + 0.3, Y_FLOOR + 0.46), Vector2(f.position.x + 0.3, f.end.y), 0.03)
	add_segment(Vector2(f.end.x, f.position.y - 0.03), Vector2(f.end.x, f.end.y), 0.03)
	add_segment(Vector2(f.position.x + 0.3, f.end.y), Vector2(f.end.x, f.end.y), 0.03)
	add_heat(Vector2(f.position.x + 0.05, f.position.y + 0.02), Vector2(f.end.x - 0.05, 1.75), 2)
	# Chimney (drawn only).
	add_prim(0, BOX, [0.2, 2.25, 0.0], Vector2(f.end.x - 0.55, f.end.y + 2.25), 0.0, 1, FLAG_VISUAL, 0.0, "wall")


## Initial sand: the mixer bowl, or the Galton bins stacked to a binomial profile.
func prefill(n: int, rng: RandomNumberGenerator) -> ParticleSet:
	if map != "galton":
		return fill_bowl(self, bowl_c, bowl_r, n, rng)
	var s := ParticleSet.new()
	var g := SimConst.R_MAX * 1.02
	var dy := 2.0 * g * sqrt(3.0) * 0.5
	var rows := bin_x.size() - 1
	var pmf: Array[float] = []
	var peak := 0.0
	for k in bin_x.size():
		# Binomial(rows, 1/2) via the log-gamma-free product form.
		var c := 1.0
		for j in k:
			c = c * (rows - j) / (j + 1)
		pmf.append(c / pow(2.0, rows))
		peak = maxf(peak, pmf[k])
	var area := 0.0
	for p in pmf:
		area += p / peak
	var per_bin_h := minf(bins.size.y * 0.8, n * PI * g * g / 0.85 / (area * 0.09))
	for k in bin_x.size():
		var h := per_bin_h * pmf[k] / peak
		var row := 0
		var y := bins.position.y + g
		while y < bins.position.y + h and s.size() < n:
			var x := bin_x[k] - 0.045 + 0.006 + g + (g if row % 2 == 1 else 0.0)
			while x < bin_x[k] + 0.045 - 0.006 - g:
				s.add(Vector2(x, y), Spawn.grain_radius(rng), GpuSolver.info_word(1, 0), Spawn.vary(Spawn.SORBET[k % 6], rng))
				x += 2.0 * g
			y += dy
			row += 1
	return s


## Machine poses at t, then the ram rod collider stretched from the head's back
## face to the barrel mouth (+1 cm into each so there is no seam).
func update(t: float) -> void:
	super(t)
	if rod_prim >= 0:
		var h: float = bodies[pusher_body].pos.x + PUSHER_HALF.x
		set_prim_shape(rod_prim, [maxf((rod_anchor - h) * 0.5, 0.0) + 0.01, ROD_HALF, 0.002])


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
