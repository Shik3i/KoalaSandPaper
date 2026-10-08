extends SceneTree
## Headless compile check of every compute shader: prints errors, exits 1 on failure.


func _init() -> void:
	var bad := 0
	for f in DirAccess.get_files_at("res://sim"):
		if not f.ends_with(".glsl"):
			continue
		var file: RDShaderFile = load("res://sim/" + f)
		var err := file.get_spirv().compile_error_compute
		if err != "":
			print("%s: %s" % [f, err.strip_edges().split("\n").slice(0, 4)])
			bad += 1
	quit(1 if bad > 0 else 0)
