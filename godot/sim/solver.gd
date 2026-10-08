class_name GpuSolver
extends RefCounted
## XPBD granular solver on the main RenderingDevice. State never leaves the GPU
## except via explicit test/stat readbacks.

const TEX_W := 1024
const CELL_CAP := 8
const MAX_BONDS := 6
const WG := 256
const MAX_BODIES := 64
const MAX_PRIMS := 256
const KERNELS := ["integrate", "stabilize", "contacts", "finalize", "velocity"]
const STAT_KEYS := ["clamp", "overflow", "nan", "oob", "max_pen_r", "max_speed", "broken", "sunk"]

var rd: RenderingDevice
var capacity := 0
var world := Vector2.ZERO
var radius := SimConst.R
var r_max := SimConst.R_MAX
var grid := Vector2i.ZERO
var substeps := SimConst.SUBSTEPS
var iterations := SimConst.ITERATIONS
var omega := SimConst.OMEGA
var damping := SimConst.DAMPING
var stack_k := SimConst.STACK_K
var sleep := SimConst.SLEEP
var gravity := SimConst.GRAVITY
var n_prims := 0
## Laser beam segment for this frame (a == b: off).
var laser_a := Vector2.ZERO
var laser_b := Vector2.ZERO
var render_texture: Texture2DRD
var frames := 0
## Pre-stabilisation pass per substep (Macklin 2014 §4.4).
var stabilize := true
var sim_time := 0.0

var _pipes := {}
var _sets := {}
var _buf := {}
var _tex: RID
var _shaders: Array[RID] = []
var _parity := 0


func setup(cap: int, world_size: Vector2, materials: Array = SimConst.MATERIALS) -> void:
	rd = RenderingServer.get_rendering_device()
	assert(rd != null, "RenderingDevice unavailable (Compatibility renderer or --headless)")
	capacity = cap
	world = world_size
	grid = Vector2i(ceili(world.x / (2.0 * r_max)), ceili(world.y / (2.0 * r_max)))
	var cells := grid.x * grid.y
	for k in ["x", "pa", "pb", "v", "stab", "vn", "vold"]:
		_sbuf(k, cap * 8)
	for k in ["info", "color", "rad"]:
		_sbuf(k, cap * 4)
	# Grid double-buffered by substep parity (see common.glsli).
	_sbuf("cell_of", cap * 4 * 2)
	_sbuf("cell_count", cells * 4 * 2)
	_sbuf("cell_items", cells * CELL_CAP * 4)
	_sbuf("stats", 16 * 4)
	_sbuf("bonds", cap * MAX_BONDS * 8)
	_sbuf("bodies", MAX_BODIES * 32)
	_sbuf("prims", MAX_PRIMS * 64)
	var mat := PackedFloat32Array()
	for m in materials:
		mat.append_array([m.mu_s, m.mu_k, m.restitution, 1.0 / SimConst.mass(m.density, radius)])
		mat.append_array([m.get("compliance", 0.0), m.get("break_strain", 1e9), m.density, 0.0])
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


## Writes particles [offset, offset + x.size()). Empty rad = reference radius.
func write(offset: int, x: PackedVector2Array, v: PackedVector2Array, info: PackedInt32Array,
		color: PackedInt32Array, rad := PackedFloat32Array()) -> void:
	var n := x.size()
	assert(offset + n <= capacity and v.size() == n and info.size() == n and color.size() == n)
	if rad.is_empty():
		rad.resize(n)
		rad.fill(radius)
	rd.buffer_update(_buf.x, offset * 8, n * 8, x.to_byte_array())
	rd.buffer_update(_buf.v, offset * 8, n * 8, v.to_byte_array())
	rd.buffer_update(_buf.info, offset * 4, n * 4, info.to_byte_array())
	rd.buffer_update(_buf.color, offset * 4, n * 4, color.to_byte_array())
	rd.buffer_update(_buf.rad, offset * 4, n * 4, rad.to_byte_array())


## Writes a ParticleSet (sim/particle_set.gd) at offset, including bonds.
func write_set(offset: int, s: ParticleSet) -> void:
	write(offset, s.x, s.v, s.info, s.color, s.rad)
	var bb := s.bond_bytes(offset)
	rd.buffer_update(_buf.bonds, offset * MAX_BONDS * 8, bb.size(), bb)


## Machine colliders: bodies = 8 floats each, prims = 64 bytes each (see colliders.glsli).
func set_colliders(bodies: PackedFloat32Array, prims: PackedByteArray) -> void:
	assert(bodies.size() <= MAX_BODIES * 8 and prims.size() <= MAX_PRIMS * 64)
	if bodies.size() > 0:
		rd.buffer_update(_buf.bodies, 0, bodies.size() * 4, bodies.to_byte_array())
	if prims.size() > 0:
		rd.buffer_update(_buf.prims, 0, prims.size(), prims)
	n_prims = prims.size() / 64


func step(frame_dt: float = SimConst.DT) -> void:
	var h := frame_dt / substeps
	var groups := ceili(float(capacity) / WG)
	var cl := rd.compute_list_begin()
	for s in substeps:
		var last := s == substeps - 1
		var t := (s + 1) * h
		var nostab := 0 if stabilize else 2
		_parity = 1 - _parity
		var flags := (1 if last else 0) | nostab | (4 * _parity)
		var p := _push(h, t, flags)
		_dispatch(cl, "integrate", 0, p, groups)
		_dispatch(cl, "stabilize", 0, p, groups)
		var cur := 0
		for it in iterations:
			_dispatch(cl, "contacts", cur, _push(h, t, flags | 1) if last and it == iterations - 1 else _push(h, t, flags & ~1), groups)
			cur = 1 - cur
		_dispatch(cl, "finalize", cur, p, groups)
		_dispatch(cl, "velocity", cur, p, groups)
	rd.compute_list_end()
	frames += 1
	sim_time += frame_dt


func read_stats() -> Dictionary:
	var raw := rd.buffer_get_data(_buf.stats)
	var out := {}
	for k in STAT_KEYS.size():
		var key: String = STAT_KEYS[k]
		out[key] = snappedf(raw.decode_float(k * 4), 0.0001) if key.begins_with("max") else raw.decode_u32(k * 4)
	out["last_clamp_at"] = Vector2(raw.decode_float(48), raw.decode_float(52))
	out["last_overflow_at"] = Vector2(raw.decode_float(56), raw.decode_float(60))
	return out


## Per-sink removal counters (sink id 0..3).
func read_sinks() -> PackedInt32Array:
	return rd.buffer_get_data(_buf.stats, 32, 16).to_int32_array()


func reset_stats() -> void:
	rd.buffer_clear(_buf.stats, 0, 16 * 4)


func read_positions() -> PackedVector2Array:
	return _read_vec2("x")


func read_velocities() -> PackedVector2Array:
	return _read_vec2("v")


func read_radii() -> PackedFloat32Array:
	return rd.buffer_get_data(_buf.rad).to_float32_array()


func read_info() -> PackedInt32Array:
	return rd.buffer_get_data(_buf.info).to_int32_array()


func read_bonds() -> PackedInt32Array:
	return rd.buffer_get_data(_buf.bonds).to_int32_array()


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


func _read_vec2(key: String) -> PackedVector2Array:
	var f := rd.buffer_get_data(_buf[key]).to_float32_array()
	var out := PackedVector2Array()
	out.resize(capacity)
	for i in capacity:
		out[i] = Vector2(f[2 * i], f[2 * i + 1])
	return out


func _sbuf(key: String, bytes: int, data := PackedByteArray()) -> void:
	if data.is_empty():
		data.resize(bytes)
	_buf[key] = rd.storage_buffer_create(bytes, data)


func _make_set(shader: RID, p_in: String, p_out: String) -> RID:
	var order := ["x", p_in, p_out, "v", "info", "color", "cell_count", "cell_items", "cell_of", "stats", "mat",
		"", "rad", "bodies", "prims", "bonds", "stab", "vn", "vold"]
	var us: Array[RDUniform] = []
	for b in order.size():
		var u := RDUniform.new()
		u.binding = b
		if order[b] == "":
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u.add_id(_tex)
		else:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.add_id(_buf[order[b]])
		us.append(u)
	return rd.uniform_set_create(us, shader, 0)


func _dispatch(cl: int, kernel: String, variant: int, pc: PackedByteArray, groups: int) -> void:
	rd.compute_list_bind_compute_pipeline(cl, _pipes[kernel])
	rd.compute_list_bind_uniform_set(cl, _sets[kernel][variant], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func _push(h: float, t_sub: float, flags: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(96)
	b.encode_float(0, world.x)
	b.encode_float(4, world.y)
	b.encode_float(8, gravity.x)
	b.encode_float(12, gravity.y)
	b.encode_float(16, h)
	b.encode_float(20, radius)
	b.encode_float(24, 1.0 / (2.0 * r_max))
	b.encode_float(28, 0.5 * radius)
	b.encode_u32(32, capacity)
	b.encode_u32(36, grid.x)
	b.encode_u32(40, grid.y)
	b.encode_u32(44, flags)
	b.encode_float(48, exp(-damping * h))
	b.encode_float(52, stack_k)
	b.encode_float(56, omega)
	b.encode_float(60, t_sub)
	b.encode_u32(64, n_prims)
	b.encode_float(68, sleep * radius)
	b.encode_float(72, r_max)
	b.encode_float(76, 0.0)
	b.encode_float(80, laser_a.x)
	b.encode_float(84, laser_a.y)
	b.encode_float(88, laser_b.x)
	b.encode_float(92, laser_b.y)
	return b
