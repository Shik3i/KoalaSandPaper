class_name SlotPool
extends RefCounted
## CPU bookkeeping of free particle slots. Sinks free slots on the GPU; the pool
## learns about them from periodic async INFO snapshots (bookkeeping only, never
## used for rendering). Slots allocated after a snapshot was requested stay used.

var used := PackedByteArray()
var alloc_frame := PackedInt32Array()
var frame := 0
var _pending := -1
## One past the highest used slot (dispatch range for the solver).
var high_water := 0


func _init(capacity: int) -> void:
	used.resize(capacity)
	alloc_frame.resize(capacity)
	alloc_frame.fill(-1)


## Lowest contiguous run of n free slots, or -1. First fit keeps the used range
## compact, so the solver's dispatch range (high_water) stays near the live count.
func alloc(n: int) -> int:
	var cap := used.size()
	var i := used.find(0)
	while i >= 0 and i + n <= cap:
		var nxt := used.find(1, i)
		var end := cap if nxt < 0 else nxt
		if end - i >= n:
			for k in range(i, i + n):
				used[k] = 1
				alloc_frame[k] = frame
			high_water = maxi(high_water, i + n)
			return i
		i = used.find(0, end)
	return -1


## The n lowest free slots (not necessarily contiguous), or empty if too few.
func alloc_any(n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var i := used.find(0)
	while i >= 0 and out.size() < n:
		out.append(i)
		i = used.find(0, i + 1)
	if out.size() < n:
		return PackedInt32Array()
	for k in out:
		used[k] = 1
		alloc_frame[k] = frame
	high_water = maxi(high_water, out[n - 1] + 1)
	return out


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
	high_water = used.rfind(1) + 1
	_pending = -1
