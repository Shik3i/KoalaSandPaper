extends Node2D
## KoalaSandPaper factory scene: endless line, physics only.
## Optional args (after --): frames=N (run N sim frames, print one JSON line, quit),
## shot=/abs/base.png shots=300,900 (screenshots at those frames), prefill=20000.

const CAPACITY := 120000
const PIECE_PERIOD := 3.0
const BLOCK := 14
const SHAPE_KEYS := ["I", "O", "T", "S", "Z", "L", "J"]

var args := {}
var factory: Factory
var solver: GpuSolver
var pool: SlotPool
var rng := Spawn.rng_for(2718)
var view: ParticleView
var mview: MachineView
var next_piece := 0.5
var spawned := 0
var piece_slot := 0
var cpu_machine_us := 0
var cpu_step_us := 0
var t0 := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	# Interactive: real time (one 1/60 s sim frame per display frame, capped at 60).
	# Batch runs (frames=N) go as fast as possible.
	if args.has("frames"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
		Engine.max_fps = 60
	factory = Factory.new()
	solver = GpuSolver.new()
	solver.substeps = int(args.get("sub", 48))
	solver.setup(CAPACITY, Factory.WORLD)
	pool = SlotPool.new(CAPACITY)
	_prefill(int(args.get("prefill", 8000)))

	var sz := get_viewport_rect().size
	var ppm := minf(sz.x / Factory.WORLD.x, sz.y / Factory.WORLD.y)
	mview = MachineView.new()
	mview.machine = factory
	mview.px_per_m = ppm
	mview.world_h = Factory.WORLD.y
	add_child(mview)
	view = ParticleView.new()
	add_child(view)
	view.bind(solver, ppm)
	_labels(ppm)
	t0 = Time.get_ticks_msec()


func _prefill(n: int) -> void:
	var s := Factory.fill_bowl(factory, factory.bowl_c, factory.bowl_r, n, rng)
	solver.write_set(pool.alloc(s.size()), s)


func _spawn_piece() -> void:
	var shape: String = SHAPE_KEYS[rng.randi() % SHAPE_KEYS.size()]
	var piece := Tetromino.make(shape, factory.spawn_at, BLOCK, Spawn.SORBET[rng.randi() % 6], rng)
	var at := pool.alloc(piece.size())
	if at < 0:
		return
	solver.spawn_piece(piece_slot, at, piece, factory.spawn_at, Vector2(Factory.BELT_SPEED, 0.0))
	piece_slot = (piece_slot + 1) % GpuSolver.MAX_PIECES
	spawned += piece.size()


func _process(_d: float) -> void:
	var t := solver.sim_time
	if t >= next_piece:
		_spawn_piece()
		next_piece += PIECE_PERIOD
	var c0 := Time.get_ticks_usec()
	factory.update(t)
	factory.upload(solver)
	solver.active_n = maxi(pool.high_water, 1)
	var c1 := Time.get_ticks_usec()
	solver.step()
	cpu_machine_us += c1 - c0
	cpu_step_us += Time.get_ticks_usec() - c1
	pool.frame = solver.frames
	if args.has("reset_at") and solver.frames == int(args.reset_at):
		solver.reset_stats()
	if solver.frames % 60 == 0:
		pool.request_refresh(solver)
	if args.has("shots") and str(solver.frames) in args.shots.split(","):
		_shot(args.shot.replace(".png", "_f%d.png" % solver.frames))
	if args.has("frames") and solver.frames >= int(args.frames):
		_report()


func _labels(ppm: float) -> void:
	var title := Label.new()
	title.text = "KOALASANDPAPER / KINETIC STUDY 001"
	title.position = Vector2(1.2, 0.18) * ppm
	title.add_theme_font_size_override("font_size", int(0.16 * ppm))
	title.modulate = Color("#8fa3a8")
	add_child(title)
	for k in factory.stations:
		var l := Label.new()
		l.text = k
		var p: Vector2 = factory.stations[k]
		l.position = Vector2(p.x, Factory.WORLD.y - p.y) * ppm
		l.add_theme_font_size_override("font_size", int(0.11 * ppm))
		l.modulate = Color("#6f8388")
		add_child(l)


func _shot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if args.get("full", "0") == "1":
		img.save_png(path)
		return
	img.resize(960, int(960.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_LANCZOS)
	img.save_png(path)


func _report() -> void:
	var info := solver.read_info()
	var active := 0
	var bonded := 0
	for w in info:
		var k := (w >> 8) & 0xff
		active += int(k != 0)
		bonded += int(k == 2)
	var st := solver.read_stats()
	if args.get("diag", "0") == "1":
		st["diag"] = _diag(info)
	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	print(JSON.stringify({"scene": "factory", "frames": solver.frames, "sinks": Array(solver.read_sinks()), "pgrid_overflow": factory.grid_overflow, "cpu_machine_ms": snappedf(cpu_machine_us / 1000.0 / solver.frames, 0.01), "cpu_step_ms": snappedf(cpu_step_us / 1000.0 / solver.frames, 0.01), "sim_s": snappedf(solver.sim_time, 0.01),
		"fps": snappedf(solver.frames / wall, 0.1), "active": active, "bonded": bonded, "spawned": spawned,
		"sunk": st.sunk, "stats": st, "free": pool.free_count()}))
	solver.free_all()
	get_tree().quit()


## Particles inside machine colliders and the densest cells (debug).
func _diag(info: PackedInt32Array) -> Dictionary:
	var pos := solver.read_positions()
	var inside := 0
	var samples := []
	var cells := {}
	for i in pos.size():
		if (info[i] >> 8) & 0xff == 0:
			continue
		var d := factory.sdf(pos[i])
		if d < 0.0:
			inside += 1
			if samples.size() < 6:
				samples.append([snappedf(pos[i].x, 0.001), snappedf(pos[i].y, 0.001), snappedf(d, 0.0001)])
		var k := Vector2i(floori(pos[i].x / 0.011), floori(pos[i].y / 0.011))
		cells[k] = cells.get(k, 0) + 1
	var worst := []
	for k in cells:
		if cells[k] > 6:
			worst.append([k.x * 0.011, k.y * 0.011, cells[k]])
	var vel := solver.read_velocities()
	var fast := []
	var nfast := 0
	for i in vel.size():
		if (info[i] >> 8) & 0xff != 0 and vel[i].length() > 2.5:
			nfast += 1
			if fast.size() < 8:
				fast.append([snappedf(pos[i].x, 0.01), snappedf(pos[i].y, 0.01), snappedf(vel[i].x, 0.01), snappedf(vel[i].y, 0.01), (info[i] >> 8) & 0xff])
	var at: Vector2 = solver.read_stats().last_overflow_at
	var near := []
	for i in pos.size():
		if (info[i] >> 8) & 0xff != 0 and pos[i].distance_to(at) < 0.03 and near.size() < 12:
			near.append([i, snappedf(pos[i].x, 0.0001), snappedf(pos[i].y, 0.0001), snappedf(vel[i].length(), 0.01), (info[i] >> 8) & 0xff, snappedf(factory.sdf(pos[i]), 0.0001)])
	return {"near_overflow": near, "fast": nfast, "fast_samples": fast, "inside": inside, "inside_samples": samples, "dense_cells": worst.size(), "dense_samples": worst.slice(0, 6)}
