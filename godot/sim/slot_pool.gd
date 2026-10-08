class_name SlotPool
extends RefCounted
## CPU bookkeeping of free particle slots. Sinks free slots on the GPU; the pool
## learns about them from periodic async INFO snapshots (bookkeeping only, never
## used for rendering). Slots allocated after a snapshot was requested stay used.

var used := PackedByteArray()
var alloc_frame := PackedInt32Array()
var frame := 0
var _pending := -1
var _cursor := 0
## One past the highest slot ever allocated (dispatch range for the solver).
var high_water := 0


func _init(capacity: int) -> void:
	used.resize(capacity)
	alloc_frame.resize(capacity)
	alloc_frame.fill(-1)


## First contiguous run of n free slots, or -1.
func alloc(n: int) -> int:
	var cap := used.size()
	for pass_i in 2:
		var run := 0
		var start := _cursor if pass_i == 0 else 0
		var stop := cap if pass_i == 0 else _cursor + n
		for i in range(start, mini(stop, cap)):
			run = run + 1 if used[i] == 0 else 0
			if run == n:
				var first := i - n + 1
				for k in range(first, i + 1):
					used[k] = 1
					alloc_frame[k] = frame
				_cursor = (i + 1) % cap
				high_water = maxi(high_water, i + 1)
				return first
	return -1


func free_count() -> int:
	return used.count(0)


func request_refresh(solver: GpuSolver) -> void:
	if _pending >= 0:
		return
	_pending = frame
	var at := frame
	solver.rd.buffer_get_data_async(solver._buf.info, func(data: PackedByteArray) -> void: _on_info(data, at))


func _on_info(data: PackedByteArray, at: int) -> void:
	var info := data.to_int32_array()
	for i in mini(info.size(), used.size()):
		if (info[i] >> 8) & 0xff == 0 and alloc_frame[i] < at:
			used[i] = 0
	_pending = -1
