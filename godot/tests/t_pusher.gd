extends SimTest
## Pusher: a strip of sand lies on the floor ahead of the factory's pusher blade.
## After the blade has advanced 1.2 m, no grain may be behind the blade face or
## inside the blade (no tunnelling through the piston), and the sand must have
## moved with it (pile front ahead of the blade).

const N := 1200
var body := 0
var face_start := 0.0


func setup() -> void:
	machine = Machine.new()
	machine.world = Vector2(4.0, 1.2)
	machine.add_segment(Vector2(0.2, 0.3), Vector2(3.8, 0.3), 0.025)
	var half := Vector2(0.045, 0.13)
	body = machine.add_body(Vector2(0.5, 0.3 + 0.025 + 0.003 + half.y), 0.0, "pusher")
	machine.piston_swept(body, Vector2(1.0, 0.0), 2.4, 8.0, 0.0)
	machine.add_prim(body, Machine.BOX, [half.x, half.y, 0.003])
	machine.update(0.0)
	make_solver(N, Vector2(4.0, 1.2))
	solver.write_set(0, Spawn.block(N, Vector2(0.7, 0.33), 140, 4))
	face_start = 0.5 + half.x


func done() -> bool:
	return machine.bodies[body].pos.x > 0.5 + 1.2


func result() -> Dictionary:
	var face: float = machine.bodies[body].pos.x + 0.045
	var pos := solver.read_positions()
	var behind := 0
	var front := 0.0
	for p in pos:
		if p.y < 0.3 + 0.025 + 0.26 and p.x < face - SimConst.R:
			behind += 1
		front = maxf(front, p.x)
	return {"pass": behind == 0, "blade_face_m": snappedf(face, 0.001), "grains_behind_blade": behind,
		"pile_front_m": snappedf(front, 0.001), "stats": solver.read_stats()}
