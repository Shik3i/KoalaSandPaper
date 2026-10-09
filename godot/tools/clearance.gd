extends SceneTree
## Headless machine audit: smallest open gap (≥ 4 mm) between any moving collider
## and the static geometry over one full pusher cycle. Prints one JSON line.
## A gap under 3 cm is a pinch where grains get crushed. Also: no moving part may
## touch another part (Machine.touching).


func _init() -> void:
	var map := "factory"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("map="):
			map = a.substr(4)
	var f := Factory.new(map)
	var per_body := {}
	var r := f.clearance(Factory.PUSHER_PERIOD + 2.0, 400)
	var touch := f.touching(Factory.PUSHER_PERIOD + 2.0, 200)
	var ok: bool = not r.pinch and touch.is_empty()
	print(JSON.stringify({"test": "clearance", "map": map, "pass": ok, "result": r, "touching": touch}))
	quit(0 if ok else 1)
