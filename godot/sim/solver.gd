class_name GpuSolver
extends RefCounted
## XPBD granular solver on the main RenderingDevice. State never leaves the GPU
## except via explicit test/stat readbacks.

const TEX_W := 1024
const CELL_CAP := 8
const WG := 256
const KERNELS := ["integrate", "contacts", "finalize"]
const STAT_NAMES := ["clamp", "overflow", "nan", "oob", "max_pen_r", "max_speed"]

var rd: RenderingDevice
var capacity := 0
var world := Vector2.ZERO
var radius := SimConst.R
var grid := Vector2i.ZERO
var substeps := SimConst.SUBSTEPS
var iterations := SimConst.ITERATIONS
var omega := SimConst.OMEGA
var damping := SimConst.DAMPING
var stack_k := SimConst.STACK_K
var gravity := SimConst.GRAVITY
var render_texture: Texture2DRD
var frames := 0
var split_lists := false

var _pipes := {}
var _sets := {}
var _buf := {}
var _tex: RID
var _shaders: Array[RID] = []


func setup(cap: int, world_size: Vector2, r: float = SimConst.R, materials: Array = SimConst.MATERIALS) -> void:
	rd = RenderingServer.get_rendering_device()
	assert(rd != null, "RenderingDevice unavailable (Compatibility renderer or --headless)")
	capacity = cap
	world = world_size
	radius = r
	grid = Vector2i(ceili(world.x / (2.0 * r)), ceili(world.y / (2.0 * r)))
	var cells := grid.x * grid.y
	_sbuf("x", cap * 8)
	_sbuf("pa", cap * 8)
	_sbuf("pb", cap * 8)
	_sbuf("v", cap * 8)
	_sbuf("info", cap * 4)
	_sbuf("color", cap * 4)
	_sbuf("cell_count", cells * 4)
	_sbuf("cell_items", cells * CELL_CAP * 4)
	_sbuf("cell_of", cap * 4)
	_sbuf("stats", 16 * 4)
	var mat := PackedFloat32Array()
	for m in materials:
		mat.append_array([m.mu_s, m.mu_k, m.restitution, 1.0 / SimConst.mass(m.density, r)])
	_sbuf("mat", mat.size() * 4, mat.to_byte_array())

	var fmt := RDTextureFormat.new()
	fmt.width = TEX_W
	fmt.height = ceili(float(cap) / TEX_W)
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zeros := PackedByteArray()
	zeros.resize(fmt.width * fmt.height * 16)
	_tex = rd.texture_create(fmt, RDTextureView.new(), [zeros])
	render_texture = Texture2DRD.new()
	render_texture.texture_rd_rid = _tex

	for k in KERNELS:
		var file: RDShaderFile = load("res://sim/%s.glsl" % k)
		var shader := rd.shader_create_from_spirv(file.get_spirv())
		assert(shader.is_valid(), "shader failed: " + k)
		_shaders.append(shader)
		_pipes[k] = rd.compute_pipeline_create(shader)
		_sets[k] = [_make_set(shader, "pa", "pb"), _make_set(shader, "pb", "pa")]


func upload(x: PackedVector2Array, v: PackedVector2Array, info: PackedInt32Array, color: PackedInt32Array) -> void:
	assert(x.size() <= capacity)
	rd.buffer_update(_buf.x, 0, x.size() * 8, x.to_byte_array())
	rd.buffer_update(_buf.v, 0, v.size() * 8, v.to_byte_array())
	rd.buffer_update(_buf.info, 0, info.size() * 4, info.to_byte_array())
	rd.buffer_update(_buf.color, 0, color.size() * 4, color.to_byte_array())


func step(frame_dt: float = SimConst.DT) -> void:
	var h := frame_dt / substeps
	var pc := _push(h, 0)
	var pc_last := _push(h, 1)
	var groups := ceili(float(capacity) / WG)
	var cl := rd.compute_list_begin()
	for s in substeps:
		var last := s == substeps - 1
		var p := pc_last if last else pc
		_dispatch(cl, "integrate", 0, p, groups)
		var cur := 0
		for it in iterations:
			_dispatch(cl, "contacts", cur, pc_last if last and it == iterations - 1 else pc, groups)
			cur = 1 - cur
		_dispatch(cl, "finalize", cur, p, groups)
	rd.compute_list_end()
	frames += 1


func read_stats() -> Dictionary:
	var raw := rd.buffer_get_data(_buf.stats)
	var u := raw.to_int32_array()
	var f := raw.to_float32_array()
	return {"clamp": u[0], "overflow": u[1], "nan": u[2], "oob": u[3], "max_pen_r": f[4], "max_speed": f[5]}


func reset_stats() -> void:
	rd.buffer_clear(_buf.stats, 0, 16 * 4)


func read_positions() -> PackedVector2Array:
	var f := rd.buffer_get_data(_buf.x).to_float32_array()
	var out := PackedVector2Array()
	out.resize(capacity)
	for i in capacity:
		out[i] = Vector2(f[2 * i], f[2 * i + 1])
	return out


func read_velocities() -> PackedVector2Array:
	var f := rd.buffer_get_data(_buf.v).to_float32_array()
	var out := PackedVector2Array()
	out.resize(capacity)
	for i in capacity:
		out[i] = Vector2(f[2 * i], f[2 * i + 1])
	return out


func free_all() -> void:
	if rd == null:
		return
	render_texture.texture_rd_rid = RID()
	for k in _sets:
		for s in _sets[k]:
			if rd.uniform_set_is_valid(s):
				rd.free_rid(s)
	for k in _pipes:
		rd.free_rid(_pipes[k])
	for s in _shaders:
		rd.free_rid(s)
	for k in _buf:
		rd.free_rid(_buf[k])
	rd.free_rid(_tex)
	rd = null


static func info_word(kind: int, material: int) -> int:
	return (kind << 8) | material


func _sbuf(key: String, bytes: int, data := PackedByteArray()) -> void:
	if data.is_empty():
		data.resize(bytes)
	_buf[key] = rd.storage_buffer_create(bytes, data)


func _make_set(shader: RID, p_in: String, p_out: String) -> RID:
	var order := ["x", p_in, p_out, "v", "info", "color", "cell_count", "cell_items", "cell_of", "stats", "mat"]
	var us: Array[RDUniform] = []
	for b in order.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = b
		u.add_id(_buf[order[b]])
		us.append(u)
	var img := RDUniform.new()
	img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	img.binding = order.size()
	img.add_id(_tex)
	us.append(img)
	return rd.uniform_set_create(us, shader, 0)


func _dispatch(cl: int, kernel: String, variant: int, pc: PackedByteArray, groups: int) -> void:
	if split_lists:
		rd.compute_list_end()
		cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipes[kernel])
	rd.compute_list_bind_uniform_set(cl, _sets[kernel][variant], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func _push(h: float, flags: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(64)
	b.encode_float(0, world.x)
	b.encode_float(4, world.y)
	b.encode_float(8, gravity.x)
	b.encode_float(12, gravity.y)
	b.encode_float(16, h)
	b.encode_float(20, radius)
	b.encode_float(24, 1.0 / (2.0 * radius))
	b.encode_float(28, 0.5 * radius)
	b.encode_u32(32, capacity)
	b.encode_u32(36, grid.x)
	b.encode_u32(40, grid.y)
	b.encode_u32(44, flags)
	b.encode_float(48, exp(-damping * h))
	b.encode_float(52, stack_k)
	b.encode_float(56, omega)
	b.encode_float(60, 0.0)
	return b
