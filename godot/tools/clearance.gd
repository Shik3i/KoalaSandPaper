extends SceneTree
## Headless machine audit: smallest open gap (≥ 4 mm) between any moving collider
## and the static geometry over one full pusher cycle. Prints one JSON line.
## A gap under 3 cm is a pinch where grains get crushed.


func _init() -> void:
	var f := Factory.new()
	var per_body := {}
	var r := f.clearance(22.0, 220)
	print(JSON.stringify({"test": "clearance", "pass": not r.pinch, "result": r}))
	quit(0 if not r.pinch else 1)
