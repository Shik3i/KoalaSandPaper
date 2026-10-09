extends SimTest
## Press quality: a standing piece (28 cm tall) under the factory press geometry
## (hydraulic, force-limited, plate down to 17 cm above the bed), one blow. Only
## the loaded region may fail: pass if something broke and the largest remaining
## body still holds at least half of the piece (no whole-piece explosion).

const BED := 0.325
var press := 0
var n := 0


func setup() -> void:
	machine = Machine.new()
	machine.world = Vector2(2.0, 1.4)
	machine.add_segment(Vector2(0.1, BED - 0.025), Vector2(1.9, BED - 0.025), 0.025)
	press = machine.add_body(Vector2(1.0, BED + 0.17 + 0.50 + 0.05), 0.0, "press")
	machine.hydraulic(press, Vector2(0.0, -1.0), 0.50, 3.3, 0.32, 0.5,
		float(args.get("pf", Factory.PRESS_FORCE)) * SimConst.mass(SimConst.SAND_DENSITY) * SimConst.G, 0)
	var pk := machine.add_prim(press, Machine.BOX, [0.26, 0.05, 0.01], Vector2.ZERO, 0.0, 1, Machine.FLAG_SENSE, 0.0, "piston")
	machine.prims[pk].sink_id = 0
	machine.update(0.0)
	make_solver(4000, machine.world)
	var rng := Spawn.rng_for(int(args.get("seed", 5)))
	var origin := Vector2(0.86, BED + 0.002)
	var piece := Tetromino.make(args.get("shape", "T"), origin, 14, Spawn.SORBET[1], rng)
	n = piece.size()
	solver.spawn_piece(0, GpuSolver.slot_range(0, n), piece, origin, Vector2.ZERO)


var log_rows: Array = []


func tick() -> bool:
	step()
	if args.has("log"):
		var st := solver.read_stats()
		var mo: Dictionary = machine.bodies[press].motion
		var info := solver.read_info()
		var rigid := 0
		for i in n:
			rigid += int((info[i] >> 8) & 0xff == 4)
		var bodies := []
		if frame >= 70 and frame <= 78:
			for k in 8:
				var b := solver.read_body(k)
				if b[3] > 0.5:
					bodies.append([k, int(b[15]), snappedf(b[14], 0.1), int(b[8]), int(b[10]), solver._stamp])
		log_rows.append([frame, str(st.last_crush_at), str(st.last_oob_at), st.broken, snappedf(mo.y, 0.001), mo.state, rigid, snappedf((solver.sensors[0] as Vector2).dot(Vector2(0, -1)), 0.1), bodies])
	return done()


func done() -> bool:
	return frame >= 200


func result() -> Dictionary:
	var info := solver.read_info()
	var body := solver.read_floats("body_of").to_byte_array().to_int32_array()
	var sizes := {}
	var rigid := 0
	for i in n:
		if (info[i] >> 8) & 0xff == 4:
			rigid += 1
			sizes[body[i]] = sizes.get(body[i], 0) + 1
	var chunks: Array = sizes.values()
	chunks.sort()
	chunks.reverse()
	var st := solver.read_stats()
	var mo: Dictionary = machine.bodies[press].motion
	if args.has("log"):
		var changes := []
		var last := -1
		for r in log_rows:
			if r[3] != last or (r[0] >= 70 and r[0] <= 78):
				changes.append(r)
				last = r[3]
		return {"log": changes.slice(0, 60)}
	return {"stalls": mo.stalls, "max_load": mo.get("max_load", 0.0), "f_max": mo.f_max, "pass": st.broken >= 1 and not chunks.is_empty() and chunks[0] >= 0.5 * n, "grains": n, "rigid_fraction": snappedf(float(rigid) / n, 0.01),
		"chunks": chunks, "breaks": st.broken, "max_speed": st.max_speed, "clamp": st.clamp}
