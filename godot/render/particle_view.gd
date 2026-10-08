class_name ParticleView
extends MultiMeshInstance2D
## Draws every solver particle as an instanced quad; positions come straight from
## the solver's render texture (Texture2DRD), no CPU readback.


func bind(solver: GpuSolver, px_per_m: float) -> void:
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
	mat.set_shader_parameter("radius_px", solver.radius * px_per_m)
	material = mat
