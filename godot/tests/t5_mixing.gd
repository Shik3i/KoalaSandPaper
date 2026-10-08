extends SimTest
## T5: bowl + rotor only. Two colour halves; Lacey mixing index per rotor
## revolution must rise from < 0.2 to > 0.8 within 6 revolutions; over 60 s no
## grain may leave the bowl except through the outlet (sink 0 at the gap; sink 1
## = everything else). Also reports grain speed percentiles inside the bowl.

const N := 14000
const SAMPLE := 0.08
var c := Vector2(2.0, 1.6)
var r := 80 * Factory.S
var rotor := 0
var lacey: Array = []
var speed: Array = []
var is_a := PackedByteArray()
var max_p99 := 0.0
var dirs := {"down": 0, "up": 0, "side": 0}
var up_samples := []


func setup() -> void:
	machine = Machine.new()
	rotor = Factory.build_mixer(machine, c, r, false)
	# Outlet exits land in sink 0 right outside the gap; anything else in sink 1.
	var gap := c + Vector2.from_angle(deg_to_rad(0.5 * (Factory.OUTLET_A0 + Factory.OUTLET_A1))) * (r + 0.12)
	machine.add_sink(gap - Vector2(0.1, 0.1), gap + Vector2(0.1, 0.1), 0)
	machine.add_sink(Vector2(0.0, -0.1), Vector2(4.0, 0.15), 1)
	machine.update(0.0)
	make_solver(N, Vector2(4.0, 3.4), int(args.get("sub", 48)))
	var s := Factory.fill_bowl(machine, c, r, N, Spawn.rng_for(int(args.get("seed", 5))), float(args.get("top", 0.2)))
	solver.write_set(0, s)
	is_a.resize(s.size())
	for i in s.size():
		is_a[i] = 1 if s.x[i].x < c.x else 0
	_sample()


func tick() -> bool:
	step()
	var rev := TAU / absf(Factory.ROTOR_OMEGA)
	if frame % 30 == 0:
		_speeds()
	if is_equal_approx(fmod(solver.sim_time + 1e-6, rev), 0.0) or fmod(solver.sim_time, rev) < SimConst.DT:
		_sample()
	return solver.sim_time >= float(args.get("secs", 60.0))


func _sample() -> void:
	var pos := solver.read_positions()
	var info := solver.read_info()
	var cells := {}
	for i in is_a.size():
		if (info[i] >> 8) & 0xff == 0 or pos[i].distance_to(c) > r:
			continue
		var k := Vector2i(floori(pos[i].x / SAMPLE), floori(pos[i].y / SAMPLE))
		var e: Array = cells.get(k, [0, 0])
		e[0] += 1
		e[1] += is_a[i]
		cells[k] = e
	var tot := 0
	var ta := 0
	for k in cells:
		tot += cells[k][0]
		ta += cells[k][1]
	if tot == 0:
		return
	var f := float(ta) / tot
	var s2 := 0.0
	var m := 0
	var nmean := 0.0
	for k in cells:
		var e: Array = cells[k]
		if e[0] < 20:
			continue
		s2 += pow(float(e[1]) / e[0] - f, 2)
		nmean += e[0]
		m += 1
	if m == 0:
		return
	s2 /= m
	nmean /= m
	var s0 := f * (1.0 - f)
	var sr := s0 / nmean
	lacey.append({"t": snappedf(solver.sim_time, 0.1), "M": snappedf((s0 - s2) / (s0 - sr), 0.001), "in_bowl": tot})


func _speeds() -> void:
	var v := solver.read_velocities()
	var pos := solver.read_positions()
	var info := solver.read_info()
	var sp: Array[float] = []
	var ang: float = machine.bodies[rotor].angle
	for i in is_a.size():
		if (info[i] >> 8) & 0xff != 0 and pos[i].distance_to(c) < r:
			var vl := v[i].length()
			sp.append(vl)
			if vl > 2.0:
				var key := "down" if v[i].y < -0.7 * vl else ("up" if v[i].y > 0.3 * vl else "side")
				dirs[key] += 1
				if key != "down" and up_samples.size() < 12:
					var rel := pos[i] - c
					# Position in rotor frame: angle relative to blade 0, radius.
					up_samples.append([key, snappedf(rel.length(), 0.01), snappedf(rad_to_deg(wrapf(rel.angle() - ang, -PI / 3, PI / 3)), 1), snappedf(v[i].x, 0.01), snappedf(v[i].y, 0.01), snappedf(machine.sdf(pos[i]) / SimConst.R, 0.1)])
	if sp.is_empty():
		return
	sp.sort()
	var p99 := sp[int(sp.size() * 0.99)]
	max_p99 = maxf(max_p99, p99)
	speed.append([snappedf(solver.sim_time, 0.1), snappedf(sp[sp.size() / 2], 0.01), snappedf(p99, 0.01), snappedf(sp[-1], 0.01)])


func result() -> Dictionary:
	var sinks := solver.read_sinks()
	var st := solver.read_stats()
	var m0: float = lacey[0].M if lacey.size() > 0 else -1.0
	var reached := false
	for k in mini(lacey.size(), 7):
		reached = reached or lacey[k].M > 0.8
	return {"pass": m0 < 0.2 and reached and sinks[1] == 0, "lacey_per_rev": lacey, "outlet": sinks[0], "leaked": sinks[1],
		"tip_speed": snappedf(absf(Factory.ROTOR_OMEGA) * 1.195, 0.01), "speed_t_p50_p99_max": speed.slice(0, 40, 4),
		"max_p99": snappedf(max_p99, 0.01), "fast_dirs": dirs, "fast_not_down": up_samples, "clamp": st.clamp, "overflow": st.overflow}
