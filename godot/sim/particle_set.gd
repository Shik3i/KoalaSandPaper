class_name ParticleSet
extends RefCounted
## CPU-side batch of particles to upload (spawns, tests). Bonds use local indices.

var x := PackedVector2Array()
var v := PackedVector2Array()
var info := PackedInt32Array()
var color := PackedInt32Array()
var rad := PackedFloat32Array()
## Per particle: Array of [local_partner, rest_length].
var bonds: Array = []


func size() -> int:
	return x.size()


func add(p: Vector2, r: float, info_word: int, rgb: int, vel := Vector2.ZERO) -> int:
	x.append(p)
	v.append(vel)
	info.append(info_word)
	color.append(rgb)
	rad.append(r)
	bonds.append([])
	return x.size() - 1


func has_bonds() -> bool:
	for b in bonds:
		if not b.is_empty():
			return true
	return false


## Bond every pair closer than (ri + rj) * tol. Returns bond count.
func bond_neighbours(tol := 1.05) -> int:
	var n := 0
	for i in size():
		for j in range(i + 1, size()):
			var d := x[i].distance_to(x[j])
			if d < (rad[i] + rad[j]) * tol and bonds[i].size() < GpuSolver.MAX_BONDS and bonds[j].size() < GpuSolver.MAX_BONDS:
				bonds[i].append([j, d])
				bonds[j].append([i, d])
				n += 1
	return n


func bond_bytes(offset: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(size() * GpuSolver.MAX_BONDS * 8)
	for i in size():
		for k in bonds[i].size():
			var at: int = (i * GpuSolver.MAX_BONDS + k) * 8
			b.encode_u32(at, offset + bonds[i][k][0] + 1)
			b.encode_float(at + 4, bonds[i][k][1])
	return b


func append(o: ParticleSet) -> void:
	var base := size()
	x.append_array(o.x)
	v.append_array(o.v)
	info.append_array(o.info)
	color.append_array(o.color)
	rad.append_array(o.rad)
	for b in o.bonds:
		var nb := []
		for e in b:
			nb.append([e[0] + base, e[1]])
		bonds.append(nb)


func translate(d: Vector2) -> void:
	for i in size():
		x[i] += d
