extends SimTest
## T6: a rigid I-piece (thicker than the 5 cm roller gap) falls onto the factory's
## coarse roller pair. It must be pulled in and torn: after 4 s at least half of
## it crumbled to free sand (the rest in rigid chunks), ≥ 90 % below the rollers,
## and no grain inside a roller (no tunnelling through the teeth).
## Jam/torque limit: motors are kinematic (ideal), so a jam is not modelled.

var n := 0
var first := 0


func setup() -> void:
	machine = Machine.new()
	machine.world = Vector2(3.0, 2.4)
	var nip := Vector2(1.5, 1.4)
	# Same geometry as Factory._shredder stage 1, shifted.
	for k in 2:
		var side := -1.0 if k == 0 else 1.0
		var body := machine.add_body(nip + Vector2(side * 0.26, 0.0), 0.0 if k == 0 else PI / 10.0, "roller")
		machine.rotor(body, 2.4 * side, 0.5)
		machine.add_prim(body, Machine.CIRCLE, [0.20], Vector2.ZERO)
		machine.add_prim(body, Machine.BOX, [0.045, 0.028, 0.01], Vector2(0.27 - 0.045, 0.0), 0.0, 10)
	machine.add_segment(Vector2(nip.x - 0.6, nip.y + 0.6), Vector2(nip.x - 0.6, 0.3), 0.02)
	machine.add_segment(Vector2(nip.x + 0.6, nip.y + 0.6), Vector2(nip.x + 0.6, 0.3), 0.02)
	machine.update(0.0)
	make_solver(4000, Vector2(3.0, 2.4))
	var rng := Spawn.rng_for(3)
	var origin := Vector2(nip.x - 0.28, nip.y + 0.35)
	var piece := Tetromino.make("I", origin, 14, Spawn.SORBET[1], rng)
	n = piece.size()
	solver.spawn_piece(0, GpuSolver.slot_range(0, piece.size()), piece, origin, Vector2.ZERO)


func done() -> bool:
	return frame >= 240


func result() -> Dictionary:
	var pos := solver.read_positions()
	var info := solver.read_info()
	var body := solver.read_floats("body_of").to_byte_array().to_int32_array()
	var bodies := {}
	var free := 0
	var below := 0
	var inside := 0
	for i in n:
		var k := (info[i] >> 8) & 0xff
		if k == 0:
			continue
		if k == 4:
			bodies[body[i]] = true
		else:
			free += 1
		below += int(pos[i].y < 1.4)
		if machine.sdf(pos[i]) < -0.25 * SimConst.R:
			inside += 1
	return {"pass": free >= n / 2 and inside == 0 and below > 0.9 * n, "free_grains": free, "rigid_chunks": bodies.size(),
		"grains": n, "below_rollers": below, "inside_rollers": inside, "stats": solver.read_stats()}
