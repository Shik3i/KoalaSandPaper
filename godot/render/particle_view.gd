class_name ParticleView
extends MultiMeshInstance2D
## Draws every solver particle as an instanced quad; positions come straight from
## the solver's render texture (Texture2DRD), no CPU readback. shadow = soft
## offset dark discs drawn under the grains.


var _solver: GpuSolver


## Only the used slot range is drawn (the instance buffer stays at capacity).
func _process(_d: float) -> void:
	if _solver and multimesh:
		multimesh.visible_instance_count = mini(_solver.active_n, _solver.capacity)


func bind(solver: GpuSolver, px_per_m: float, shadow := false) -> void:
	_solver = solver
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.mesh = quad
	mm.instance_count = solver.capacity
	mm.custom_aabb = AABB(Vector3(-1e5, -1e5, -1.0), Vector3(2e5, 2e5, 2.0))
	multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = load("res://render/particles.gdshader")
	mat.set_shader_parameter("state_tex", solver.render_texture)
	mat.set_shader_parameter("px_per_m", px_per_m)
	mat.set_shader_parameter("world_h", solver.world.y)
	mat.set_shader_parameter("ref_d_px", 2.0 * solver.radius * px_per_m)
	mat.set_shader_parameter("poly", solver.r_max / solver.radius - 1.0)
	mat.set_shader_parameter("shadow", shadow)
	material = mat
