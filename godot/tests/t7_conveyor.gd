extends SimTest
## T7: a grain dropped on a moving belt reaches belt speed in the friction-limited
## time t = v / (mu_k g) (within 50 %), then rides at belt speed (within 3 %).
## The belt only acts through contact friction: positions are never assigned
## (checked by grepping the kernels for the belt speed field).

const SPEED := 0.45
var vx: Array = []


func setup() -> void:
	machine = Machine.new()
	machine.add_belt(0.2, 2.8, 0.3, SPEED)
	machine.update(0.0)
	make_solver(8, Vector2(3.0, 1.0))
	var s := ParticleSet.new()
	for k in 5:
		s.add(Vector2(0.5 + 0.2 * k, 0.3 + SimConst.R + 0.0005), SimConst.R, GpuSolver.info_word(1, 0), 0xf6b17a)
	solver.write_set(0, s)


func tick() -> bool:
	step()
	vx.append(solver.read_velocities()[0].x)
	return frame >= 60


func result() -> Dictionary:
	var g := SimConst.G
	var mu_k: float = 0.5 * (SimConst.MATERIALS[0].mu_k + Machine.MU.y)
	var t_theory := SPEED / (mu_k * g)
	var t_reach := -1.0
	for i in vx.size():
		if vx[i] >= 0.95 * SPEED:
			t_reach = (i + 1) * SimConst.DT
			break
	var final_v: float = vx[-1]
	var src := ""
	for f in ["integrate", "contacts", "finalize", "velocity"]:
		src += FileAccess.get_file_as_string("res://sim/%s.glsl" % f)
	# Belt speed (surf.w) may only appear inside friction/velocity terms (vs), never in X writes.
	var assigns := src.count("X[i] = pr.surf") + src.count("X[i] += pr.surf")
	var ok := t_reach > 0.0 and absf(t_reach - t_theory) <= 0.5 * t_theory + SimConst.DT \
		and absf(final_v - SPEED) <= 0.03 * SPEED and assigns == 0
	return {"pass": ok, "t_reach_s": snappedf(t_reach, 0.001), "t_theory_s": snappedf(t_theory, 0.001),
		"final_vx": snappedf(final_v, 0.0001), "belt_speed": SPEED, "direct_assignments": assigns}
