extends Node2D
## Runs one acceptance test: tools/run.sh res://tests/runner.tscn t=t2_repose [k=v ...]
## Prints one JSON line {test, pass, ...} and quits.

var test: SimTest
var args := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	test = load("res://tests/%s.gd" % args.get("t", "t1_free_fall")).new()
	test.args = args
	test.setup()
	var sz := get_viewport_rect().size
	var ppm := minf(sz.x / test.solver.world.x, sz.y / test.solver.world.y)
	if test.machine:
		var mv := MachineView.new()
		mv.machine = test.machine
		mv.px_per_m = ppm
		mv.world_h = test.solver.world.y
		add_child(mv)
	var view := ParticleView.new()
	add_child(view)
	view.bind(test.solver, ppm)


func _process(_d: float) -> void:
	if test == null:
		return
	var done := test.tick()
	if args.has("seq") and str(test.frame) in args.seq.split(","):
		get_viewport().get_texture().get_image().save_png(args.shot.replace(".png", "_f%d.png" % test.frame))
	if done:
		if args.has("shot"):
			var img := get_viewport().get_texture().get_image()
			img.resize(960, int(960.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_LANCZOS)
			img.save_png(args.shot)
		var r := test.result()
		r.merge({"test": args.get("t")}, false)
		print(JSON.stringify(r))
		test.cleanup()
		test = null
		get_tree().quit()
