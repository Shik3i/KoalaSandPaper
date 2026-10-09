extends Node2D
## M0/T9 benchmark: N grains free-fall onto the floor of a 1280x720-diameter box.
## Args (after --): n=50000 sub=6 it=1 frames=600 warm=120
## Prints one JSON line and quits.

var solver: GpuSolver
var args := {"n": 50000, "sub": SimConst.SUBSTEPS, "it": 1, "frames": 600, "warm": 120, }
var times: Array[float] = []
var last_us := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1] if not kv[1].is_valid_float() else (float(kv[1]) if "." in kv[1] else int(kv[1]))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var r := SimConst.R
	var wc: int = args.get("cols", 1280)
	var world := Vector2(wc, wc * 9 / 16) * 2.0 * r
	solver = GpuSolver.new()
	solver.substeps = args.sub
	solver.setup(args.n, world)
	solver.no_barrier = args.get("nobar", 0) == 1
	if args.has("skip"):
		solver.skip_kernels = str(args.skip).split("+")
	var cols := int(wc * 0.78)
	solver.write_set(0, Spawn.block(args.n, Vector2(wc * 0.11, wc * 9 / 16 * 0.38) * 2.0 * r, cols, 1))
	var view := ParticleView.new()
	add_child(view)
	view.bind(solver, get_viewport_rect().size.x / world.x)


func _process(_d: float) -> void:
	var now := Time.get_ticks_usec()
	if last_us > 0 and solver.frames > args.warm:
		times.append((now - last_us) / 1000.0)
	last_us = now
	for k in int(args.get("spf", 1)):
		solver.step()
	if args.has("shot_at") and solver.frames == args.shot_at:
		_shot(args.shot.replace(".png", "_f%d.png" % solver.frames))
	if times.size() >= args.frames:
		_report()



func _report() -> void:
	if args.has("shot"):
		_shot(args.shot)
	var st := solver.read_stats()
	if args.get("probe", 0) == 1:
		var pos := solver.read_positions()
		st["cpu"] = Probe.overlap(pos, solver.read_radii())
		var e := Probe.extent(pos)
		st["top_r"] = snappedf(e.end.y / solver.radius, 0.1)
		var vel := solver.read_velocities()
		var vmax := 0.0
		for v in vel:
			vmax = maxf(vmax, v.length())
		st["cpu_vmax"] = vmax
	times.sort()
	var mean := 0.0
	for t in times:
		mean += t
	mean /= times.size()
	var out := {
		"test": "T9", "n": args.n, "sub": args.sub, "it": args.it,
		"fps": snappedf(1000.0 / mean, 0.1), "spf": args.get("spf", 1), "ms_per_sim_frame": snappedf(times[times.size() / 2] / float(args.get("spf", 1)), 0.01), "frame_ms_p50": snappedf(times[times.size() / 2], 0.01),
		"frame_ms_p95": snappedf(times[int(times.size() * 0.95)], 0.01),
		"res": "%dx%d" % [get_viewport_rect().size.x, get_viewport_rect().size.y],
		"device": solver.rd.get_device_name(), "stats": st,
	}
	print(JSON.stringify(out))
	solver.free_all()
	get_tree().quit()


func _shot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.resize(960, int(960.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_LANCZOS)
	img.save_png(path)
