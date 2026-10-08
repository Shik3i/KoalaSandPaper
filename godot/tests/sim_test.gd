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
	s.stack_k = float(args.get("stack", s.stack_k))
	s.sleep = float(args.get("sleep", s.sleep))
	s.omega = float(args.get("omega", s.omega))
	s.iterations = int(args.get("it", s.iterations))
	s.damping = float(args.get("damp", s.damping))
	s.stabilize = args.get("stab", "1") == "1"
	s.setup(cap, world)
	solver = s
	return s


func step() -> void:
	if machine:
		machine.world = solver.world
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
