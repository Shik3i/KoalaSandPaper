class_name SimTest
extends RefCounted
## Base for physical acceptance tests. The runner calls setup(), then tick()
## once per rendered frame until it returns true, then result().

var args := {}
var solver: GpuSolver
var machine: Machine
var frame := 0


func setup() -> void:
	pass


## Default: one sim frame per call; override done().
func tick() -> bool:
	step()
	return done()


func done() -> bool:
	return true


func result() -> Dictionary:
	return {}


func make_solver(cap: int, world: Vector2, sub := SimConst.SUBSTEPS) -> GpuSolver:
	var s := GpuSolver.new()
	s.substeps = int(args.get("sub", sub))
	s.tc_steps = float(args.get("tc", s.tc_steps))
	s.damping = float(args.get("damp", s.damping))
	s.crush_g = float(args.get("crush", s.crush_g))
	var mats: Array = SimConst.MATERIALS.duplicate(true)
	for m in mats:
		m.mu_s = float(args.get("mu", m.mu_s))
		m.mu_k = float(args.get("muk", args.get("mu", m.mu_k)))
		m.restitution = float(args.get("e", m.restitution))
		if m.name == "sand":
			m.mu_roll = float(args.get("mur", m.get("mu_roll", 0.0)))
	s.setup(cap, world, mats)
	solver = s
	return s


func step() -> void:
	if machine:
		machine.world = solver.world
		machine.drive(SimConst.DT, solver.sim_time, solver.sensors)
		machine.update(solver.sim_time)
		machine.upload(solver)
	solver.step()
	frame += 1


func count_active(info: PackedInt32Array) -> int:
	var n := 0
	for w in info:
		if (w >> 8) & 0xff != 0:
			n += 1
	return n


func cleanup() -> void:
	if solver:
		solver.free_all()
