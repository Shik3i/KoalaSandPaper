class_name GpuSolver
extends RefCounted
## DEM granular solver (sim/common.glsli) on the main RenderingDevice. State
## never leaves the GPU except via explicit test/stat readbacks.

const TEX_W := 1024
const CELL_CAP := 6
const MAX_BONDS := 6
const HIST_K := 8
const WG := 256
const MAX_BODIES := 256
const MAX_PRIMS := 512
const KERNELS := ["dem_order", "dem_step", "dem_rigid", "dem_spawn"]
const MAX_PIECES := 256
## Bodies per piece: the whole piece, then the chunks it breaks into (dem_rigid.glsl NSUB).
const BODIES_PER_PIECE := 8
const ACC_STRIDE := 12
const MAX_PIECE_GRAINS := 1024
## Breakage pass (dem_rigid) every this many steps.
const RIGID_EVERY := 4
const STAT_KEYS := ["clamp", "overflow", "nan", "oob", "max_pen_r", "max_speed", "broken", "sunk"]

var rd: RenderingDevice
var capacity := 0
## Piece slots ever used (dem_rigid dispatches over [0, pieces_used)).
var pieces_used := 0
## Highest used slot + 1: kernels are dispatched over [0, active_n).
var active_n := 0
var world := Vector2.ZERO
var radius := SimConst.R
var r_max := SimConst.R_MAX
var grid := Vector2i.ZERO
## DEM steps per 1/60 s frame.
var substeps := SimConst.SUBSTEPS
## Contact duration in steps (sets the stiffness: k = m_eff (pi / t_c)^2).
var tc_steps := SimConst.TC_STEPS
var damping := SimConst.DAMPING
var gravity := SimConst.GRAVITY
## Rigid piece breaks when squeezed by more than crush_g grain weights for a while.
var crush_g := SimConst.CRUSH_G
var n_prims := 0
var pgrid_dims := Vector2i.ONE
var render_texture: Texture2DRD
var frames := 0
var sim_time := 0.0
## Derived per-step constants (see _derive).
var kn := 0.0
var kt := 0.0
var dt := 0.0
var v_max := 0.0
var m_ref := 0.0

var _pipe := {}
var _set := {}
var _buf := {}
var _tex: RID
var _shaders: Array[RID] = []
var _step := 0
## Grid stamp (24 bit) of the next step; 0 never occurs in a valid count word.
var _stamp := 1
## Contact history buffer read this step (0: hist_a → hist_b, 1: reverse).
var _hist := 0
var _n_blocks := 0
## Mean contact force per step on the grains touching each sensor prim, from the
## last finished frame (async readback, 1-2 frames old).
var sensors: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
var _sense_pending := false


func setup(cap: int, world_size: Vector2, materials: Array = SimConst.MATERIALS) -> void:
	rd = RenderingServer.get_rendering_device()
	assert(rd != null, "RenderingDevice unavailable (Compatibility renderer or --headless)")
	capacity = cap
	world = world_size
	grid = Vector2i(ceili(world.x / (2.0 * r_max)), ceili(world.y / (2.0 * r_max)))
	var cells := grid.x * grid.y
	active_n = cap
	for k in ["vn", "rest"]:
		_sbuf(k, cap * 8)
	var none := PackedInt32Array()
	none.resize(cap)
	none.fill(-1)
	_sbuf("rank", cap * 4, none.to_byte_array())
	_sbuf("xv", cap * 16)
	for k in ["hkey_a", "hkey_b"]:
		_sbuf(k, cap * HIST_K * 4)
	for k in ["hxi_a", "hxi_b"]:
		_sbuf(k, cap * HIST_K * 8)
	_sbuf("body_of", cap * 4, none.to_byte_array())
	# Bodies: two halves (see body_now in common.glsli); force accumulators: three slots.
	_sbuf("rb", 2 * MAX_PIECES * BODIES_PER_PIECE * 64)
	_sbuf("acc", (3 * MAX_PIECES * BODIES_PER_PIECE * ACC_STRIDE + 64) * 4)
	_sbuf("pieces", MAX_PIECES * 16)
	_sbuf("plist", MAX_PIECES * MAX_PIECE_GRAINS * 4)
	_sbuf("stage", MAX_PIECE_GRAINS * 32)
	pgrid_dims = Vector2i(ceili(world.x / Machine.PCELL), ceili(world.y / Machine.PCELL))
	_sbuf("pgrid", pgrid_dims.x * pgrid_dims.y * (Machine.PCELL_CAP + 1) * 4)
	for k in ["info", "color"]:
		_sbuf(k, cap * 4)
	# Grid: two stamped halves of packed bins (see common.glsli).
	_sbuf("bin_count", cells * 4 * 2)
	_sbuf("bins", cells * CELL_CAP * 16 * 2)
	_n_blocks = ceili(grid.x / 8.0) * ceili(grid.y / 8.0)
	_sbuf("order", cap * 4)
	_sbuf("block_count", _n_blocks * 4)
	_sbuf("block_cursor", (_n_blocks + 1) * 4)
	_sbuf("stats", 24 * 4)
	_sbuf("bonds", cap * MAX_BONDS * 8)
	_sbuf("bodies", MAX_BODIES * 32)
	_sbuf("prims", MAX_PRIMS * 64)
	_sbuf("pbound", MAX_PRIMS * 32)
	var mat := PackedFloat32Array()
	for m in materials:
		var le := log(maxf(m.restitution, 1e-4))
		var zeta := -le / sqrt(PI * PI + le * le)
		mat.append_array([m.mu_s, m.mu_k, zeta, 1.0 / SimConst.mass(m.density, radius)])
		mat.append_array([0.0, m.get("break_strain", 1e9), m.density, 0.0])
	_sbuf("mat", mat.size() * 4, mat.to_byte_array())
	m_ref = SimConst.mass(materials[0].density, radius)

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
		var spirv := file.get_spirv()
		if spirv.compile_error_compute != "":
			push_error("%s.glsl: %s" % [k, spirv.compile_error_compute])
		var shader := rd.shader_create_from_spirv(spirv)
		assert(shader.is_valid(), "shader failed: " + k)
		_shaders.append(shader)
		_pipe[k] = rd.compute_pipeline_create(shader)
		_set[k] = [_make_set(shader, "a", "b"), _make_set(shader, "b", "a")]


func _sense_offset() -> int:
	return 3 * MAX_PIECES * BODIES_PER_PIECE * ACC_STRIDE * 4


## Stiffness from the contact duration: two reference grains (m_eff = m/2)
## stay in contact for t_c = tc_steps * dt (undamped half period).
func _derive(frame_dt: float) -> void:
	dt = frame_dt / substeps
	var tc := tc_steps * dt
	kn = 0.5 * m_ref * PI * PI / (tc * tc)
	kt = kn * 2.0 / 7.0
	v_max = 0.75 * radius / dt


## Writes particles [offset, offset + x.size()). Empty rad = reference radius.
## Clears their contact history.
func write(offset: int, x: PackedVector2Array, v: PackedVector2Array, info: PackedInt32Array,
		color: PackedInt32Array, rad := PackedFloat32Array()) -> void:
	var n := x.size()
	assert(offset + n <= capacity and v.size() == n and info.size() == n and color.size() == n)
	if rad.is_empty():
		rad.resize(n)
		rad.fill(radius)
	info = info.duplicate()
	var xv := PackedFloat32Array()
	xv.resize(n * 4)
	for i in n:
		info[i] = (info[i] & ~0xff0000) | (radius_code(rad[i]) << 16)
		xv[4 * i] = x[i].x
		xv[4 * i + 1] = x[i].y
		xv[4 * i + 2] = v[i].x
		xv[4 * i + 3] = v[i].y
	var none := PackedInt32Array()
	none.resize(n)
	none.fill(-1)
	rd.buffer_update(_buf.rank, offset * 4, n * 4, none.to_byte_array())
	rd.buffer_update(_buf.xv, offset * 16, n * 16, xv.to_byte_array())
	rd.buffer_update(_buf.info, offset * 4, n * 4, info.to_byte_array())
	rd.buffer_update(_buf.color, offset * 4, n * 4, color.to_byte_array())


## Writes a ParticleSet (sim/particle_set.gd) at offset, including bonds.
func write_set(offset: int, s: ParticleSet) -> void:
	write(offset, s.x, s.v, s.info, s.color, s.rad)
	var bb := s.bond_bytes(offset)
	rd.buffer_update(_buf.bonds, offset * MAX_BONDS * 8, bb.size(), bb)


## Spawns rigid piece `piece` from ParticleSet `s` (positions = rest layout placed
## at `origin`, rest frame = s.x - origin) into `slots` (any free slots, one per grain).
func spawn_piece(piece: int, slots: PackedInt32Array, s: ParticleSet, origin: Vector2, vel: Vector2) -> void:
	var n := s.size()
	assert(slots.size() == n and n <= MAX_PIECE_GRAINS)
	var c0 := Vector2.ZERO
	var mass := 0.0
	for i in n:
		var m := SimConst.mass(SimConst.MATERIALS[s.info[i] & 0xff].density, s.rad[i])
		c0 += (s.x[i] - origin) * m
		mass += m
	c0 /= mass
	var inertia := 0.0
	var stage := PackedFloat32Array()
	stage.resize(n * 8)
	for i in n:
		var rest := s.x[i] - origin
		inertia += SimConst.mass(SimConst.MATERIALS[s.info[i] & 0xff].density, s.rad[i]) * (rest - c0).length_squared()
		var info := (s.info[i] & ~0xffff00) | (4 << 8) | (radius_code(s.rad[i]) << 16)
		stage[8 * i] = s.x[i].x
		stage[8 * i + 1] = s.x[i].y
		stage[8 * i + 2] = vel.x
		stage[8 * i + 3] = vel.y
		stage[8 * i + 4] = rest.x
		stage[8 * i + 5] = rest.y
		var bits := PackedInt32Array([info, s.color[i]]).to_byte_array().to_float32_array()
		stage[8 * i + 6] = bits[0]
		stage[8 * i + 7] = bits[1]
	rd.buffer_update(_buf.stage, 0, stage.size() * 4, stage.to_byte_array())
	rd.buffer_update(_buf.plist, piece * MAX_PIECE_GRAINS * 4, n * 4, slots.to_byte_array())
	var c := origin + c0
	# Body 0 of the piece (leader = its first grain) in both halves; chunk slots and
	# force accumulators cleared.
	var body := PackedFloat32Array([c.x, c.y, 0.0, 1.0, vel.x, vel.y, 0.0, mass,
		0.0, float(slots[0]), 0.0, inertia, c0.x, c0.y, 0.0, n])
	var half := MAX_PIECES * BODIES_PER_PIECE * 64
	for h in 2:
		rd.buffer_clear(_buf.rb, h * half + piece * BODIES_PER_PIECE * 64, BODIES_PER_PIECE * 64)
		rd.buffer_update(_buf.rb, h * half + piece * BODIES_PER_PIECE * 64, 64, body.to_byte_array())
	var slot := MAX_PIECES * BODIES_PER_PIECE * ACC_STRIDE * 4
	for k in 3:
		rd.buffer_clear(_buf.acc, k * slot + piece * BODIES_PER_PIECE * ACC_STRIDE * 4, BODIES_PER_PIECE * ACC_STRIDE * 4)
	pieces_used = maxi(pieces_used, piece + 1)
	var pd := PackedInt32Array([piece * MAX_PIECE_GRAINS, n, 1, 0])
	rd.buffer_update(_buf.pieces, piece * 16, 16, pd.to_byte_array())
	var p := _push(0.0, 0)
	p.encode_u32(32, n)
	p.encode_u32(104, piece)
	var cl := rd.compute_list_begin()
	_dispatch(cl, "dem_spawn", p, ceili(n / 64.0), 0)
	rd.compute_list_end()


## Slots offset .. offset + n - 1 (contiguous placement, tests).
static func slot_range(offset: int, n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	for i in n:
		out[i] = offset + i
	return out


## Machine colliders: bodies = 8 floats each, prims = 64 bytes each (see colliders.glsli),
## grid = coarse collider grid (Machine.pack_grid) of `dims` cells.
func set_colliders(bodies: PackedFloat32Array, prims: PackedByteArray, grid: PackedInt32Array, dims: Vector2i,
		bounds: PackedFloat32Array, sensor_cfg := PackedFloat32Array()) -> void:
	if sensor_cfg.size() == 16:
		rd.buffer_update(_buf.acc, _sense_offset() + 48 * 4, 64, sensor_cfg.to_byte_array())
	assert(bodies.size() <= MAX_BODIES * 8 and prims.size() <= MAX_PRIMS * 64)
	assert(dims == pgrid_dims, "machine.world must match the solver world")
	rd.buffer_update(_buf.pgrid, 0, grid.size() * 4, grid.to_byte_array())
	if bodies.size() > 0:
		rd.buffer_update(_buf.bodies, 0, bodies.size() * 4, bodies.to_byte_array())
	if prims.size() > 0:
		rd.buffer_update(_buf.prims, 0, prims.size(), prims)
		rd.buffer_update(_buf.pbound, 0, bounds.size() * 4, bounds.to_byte_array())
	n_prims = prims.size() / 64


func step(frame_dt: float = SimConst.DT) -> void:
	_derive(frame_dt)
	if _stamp + substeps + 2 >= (1 << 24):
		# Stamp wrap (after ~45 min): forget the grid, it is rebuilt in one step.
		rd.buffer_clear(_buf.bin_count, 0, grid.x * grid.y * 4 * 2)
		_stamp = 1
	var groups := ceili(float(active_n) / WG)
	rd.buffer_clear(_buf.acc, _sense_offset(), 32)
	var cl := rd.compute_list_begin()
	# Spatial processing order for this frame (count, scan, scatter).
	var p0 := _push(0.0, 0)
	_dispatch(cl, "dem_order", p0, ceili(float(active_n) / 1024.0), 0)
	_dispatch(cl, "dem_order", _push(0.0, 1 << 16), 1, 0)
	_dispatch(cl, "dem_order", _push(0.0, 2 << 16), ceili(float(active_n) / 1024.0), 0)
	_dispatch(cl, "dem_order", _push(0.0, 3 << 16), ceili(float(active_n) / 1024.0), _hist)
	_hist = 1 - _hist
	for s in substeps:
		var last := s == substeps - 1
		var p := _push(s * dt, (1 if last else 0) | (_step << 8))
		_dispatch(cl, "dem_step", p, groups, _hist)
		if pieces_used > 0 and (s + 1) % RIGID_EVERY == 0:
			_dispatch(cl, "dem_rigid", p, pieces_used, _hist)
		_hist = 1 - _hist
		_stamp += 1
		_step = (_step + 1) % 240
	rd.compute_list_end()
	frames += 1
	sim_time += frame_dt
	if not _sense_pending:
		_sense_pending = true
		var steps := substeps
		rd.buffer_get_data_async(_buf.acc, func(data: PackedByteArray) -> void:
			var f := data.to_float32_array()
			for k in 4:
				sensors[k] = Vector2(f[2 * k], f[2 * k + 1]) / steps
			_sense_pending = false, _sense_offset(), 32)


## State of rigid body b after the last step: (c.x, c.y, angle, alive, v.x, v.y, omega, mass, ...16 floats).
func read_body(b: int) -> PackedFloat32Array:
	var h := (_stamp - 1) & 1
	return read_floats("rb", h * MAX_PIECES * BODIES_PER_PIECE * 64 + b * 64, 64)


func read_stats() -> Dictionary:
	var raw := rd.buffer_get_data(_buf.stats)
	var out := {}
	for k in STAT_KEYS.size():
		var key: String = STAT_KEYS[k]
		out[key] = snappedf(raw.decode_float(k * 4), 0.0001) if key.begins_with("max") else raw.decode_u32(k * 4)
	out["last_clamp_at"] = Vector2(raw.decode_float(48), raw.decode_float(52))
	out["last_overflow_at"] = Vector2(raw.decode_float(56), raw.decode_float(60))
	out["last_crush_at"] = Vector2(raw.decode_float(64), raw.decode_float(68))
	out["last_clamp_prim"] = raw.decode_u32(72)
	out["last_oob_at"] = Vector2(raw.decode_float(80), raw.decode_float(84))
	return out


## Per-sink removal counters (sink id 0..3).
func read_sinks() -> PackedInt32Array:
	return rd.buffer_get_data(_buf.stats, 32, 16).to_int32_array()


func reset_stats() -> void:
	rd.buffer_clear(_buf.stats, 0, 24 * 4)


func read_positions() -> PackedVector2Array:
	return _read_xv(0)


func read_velocities() -> PackedVector2Array:
	return _read_xv(2)


func _read_xv(at: int) -> PackedVector2Array:
	var f := rd.buffer_get_data(_buf.xv).to_float32_array()
	var out := PackedVector2Array()
	out.resize(capacity)
	for i in capacity:
		out[i] = Vector2(f[4 * i + at], f[4 * i + at + 1])
	return out


func read_floats(key: String, offset := 0, size := 0) -> PackedFloat32Array:
	return rd.buffer_get_data(_buf[key], offset, size).to_float32_array()


func read_radii() -> PackedFloat32Array:
	var info := read_info()
	var out := PackedFloat32Array()
	out.resize(info.size())
	var poly := r_max / radius - 1.0
	for i in info.size():
		out[i] = radius * (1.0 + poly * (((info[i] >> 16) & 0xff) / 127.5 - 1.0))
	return out


func read_info() -> PackedInt32Array:
	return rd.buffer_get_data(_buf.info).to_int32_array()


func read_bonds() -> PackedInt32Array:
	return rd.buffer_get_data(_buf.bonds).to_int32_array()


func free_all() -> void:
	if rd == null:
		return
	render_texture.texture_rd_rid = RID()
	for k in _set:
		for us in _set[k]:
			if rd.uniform_set_is_valid(us):
				rd.free_rid(us)
	for k in _pipe:
		rd.free_rid(_pipe[k])
	for s in _shaders:
		rd.free_rid(s)
	for k in _buf:
		rd.free_rid(_buf[k])
	rd.free_rid(_tex)
	rd = null


## 8-bit radius code (see rad_of in common.glsli).
func radius_code(r: float) -> int:
	var poly := r_max / radius - 1.0
	return clampi(roundi((r / radius - 1.0) / poly * 127.5 + 127.5), 0, 255)


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


func _make_set(shader: RID, h_in: String, h_out: String) -> RID:
	var order := {2: "vn", 3: "hxi_" + h_out, 4: "info", 5: "color", 6: "bin_count", 7: "bins",
		9: "stats", 10: "mat", 11: "", 12: "xv", 13: "bodies", 14: "prims", 15: "bonds", 16: "hkey_" + h_in,
		17: "hkey_" + h_out, 18: "hxi_" + h_in, 19: "rest",
		20: "body_of", 21: "rb", 22: "pieces", 24: "pgrid", 25: "pbound", 26: "order", 27: "block_count", 28: "block_cursor", 29: "acc", 30: "plist", 31: "stage", 32: "rank"}
	var us: Array[RDUniform] = []
	for b in order:
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


const STATE_BUFFERS := ["xv", "rank", "info", "color", "bonds", "hkey_a", "hkey_b", "hxi_a", "hxi_b", "rest", "body_of", "rb", "acc", "pieces", "plist"]


## Snapshot of the full particle/body state (zstd-compressed var file) plus
## caller data `extra`. Used to start captures from a run-in machine.
func save_state(path: String, extra: Dictionary) -> void:
	var bufs := {}
	for k in STATE_BUFFERS:
		bufs[k] = rd.buffer_get_data(_buf[k])
	var d := {"version": 2, "capacity": capacity, "world": world, "frames": frames, "sim_time": sim_time,
		"pieces_used": pieces_used, "active_n": active_n, "stamp": _stamp, "hist": _hist, "buffers": bufs, "extra": extra}
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	f.store_var(d)
	f.close()


## Restores a snapshot written by save_state; returns its `extra` dictionary.
func load_state(path: String) -> Dictionary:
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	assert(f != null, "cannot open state " + path)
	var d: Dictionary = f.get_var()
	f.close()
	assert(d.capacity == capacity and d.world == world, "state does not match this solver")
	for k in STATE_BUFFERS:
		var b: PackedByteArray = d.buffers[k]
		rd.buffer_update(_buf[k], 0, b.size(), b)
	frames = d.frames
	_stamp = d.get("stamp", 1)
	_hist = d.get("hist", 0)
	sim_time = d.sim_time
	pieces_used = d.pieces_used
	active_n = d.active_n
	return d.extra


## Profiling aid: kernels listed here are not dispatched (results become wrong).
var skip_kernels: Array = []
## Profiling aid: no explicit barriers between dispatches.
var no_barrier := false


func _dispatch(cl: int, kernel: String, pc: PackedByteArray, groups: int, variant: int) -> void:
	if kernel in skip_kernels:
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe[kernel])
	rd.compute_list_bind_uniform_set(cl, _set[kernel][variant], 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	if not no_barrier:
		rd.compute_list_add_barrier(cl)


func _push(t_sub: float, flags: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(112)
	b.encode_float(0, world.x)
	b.encode_float(4, world.y)
	b.encode_float(8, gravity.x)
	b.encode_float(12, gravity.y)
	b.encode_float(16, dt)
	b.encode_float(20, radius)
	b.encode_float(24, 1.0 / (2.0 * r_max))
	b.encode_float(28, v_max)
	b.encode_u32(32, active_n)
	b.encode_u32(36, grid.x)
	b.encode_u32(40, grid.y)
	b.encode_u32(44, flags)
	b.encode_float(48, kn)
	b.encode_float(52, kt)
	b.encode_float(56, kn)
	b.encode_float(60, exp(-damping * dt))
	b.encode_float(64, t_sub)
	b.encode_u32(68, capacity)
	b.encode_float(72, r_max)
	b.encode_float(76, 1.0 / Machine.PCELL)
	b.encode_u32(80, pieces_used)
	b.encode_float(84, crush_g * m_ref * SimConst.G)
	b.encode_u32(88, pgrid_dims.x | (pgrid_dims.y << 16))
	b.encode_float(92, SimConst.RIGID_DAMP_MASS)
	b.encode_u32(96, maxi(1, substeps / 6))
	b.encode_u32(100, _stamp)
	b.encode_float(104, 0.0)
	b.encode_float(108, 0.0)
	return b
