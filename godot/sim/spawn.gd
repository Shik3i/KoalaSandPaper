class_name Spawn
## Deterministic particle spawners. All positions in m (y up).

const SORBET := [0xf6b17a, 0xed7e9a, 0xbea5ee, 0x8dccbc, 0xf0d487, 0x8cbbe2]


static func rng_for(rng_seed: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	return rng


static func grain_radius(rng: RandomNumberGenerator) -> float:
	return SimConst.R * (1.0 + rng.randf_range(-SimConst.POLY, SimConst.POLY))


## Loose hex-packed block of free grains, lower-left corner at origin, `cols` wide.
static func block(count: int, origin: Vector2, cols: int, rng_seed: int, palette := SORBET) -> ParticleSet:
	var rng := rng_for(rng_seed)
	var s := ParticleSet.new()
	var dx := 2.0 * SimConst.R_MAX * 1.02
	var dy := dx * sqrt(3.0) * 0.5
	var w := GpuSolver.info_word(1, 0)
	for i in count:
		var row := i / cols
		var c := i % cols
		var p := origin + Vector2(c * dx + (row % 2) * 0.5 * dx, row * dy)
		p += Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.05 * SimConst.R
		s.add(p, grain_radius(rng), w, vary(palette[(c * palette.size()) / cols], rng))
	return s


## Bonded hex cluster `cols` x `rows` grains (rigid if compliance is 0).
static func bonded_block(cols: int, rows: int, origin: Vector2, material: int, rgb: int, rng_seed: int) -> ParticleSet:
	var rng := rng_for(rng_seed)
	var s := ParticleSet.new()
	var r := SimConst.R
	var dx := 2.0 * r
	var dy := dx * sqrt(3.0) * 0.5
	var w := GpuSolver.info_word(2, material)
	for row in rows:
		for c in cols - (row % 2):
			s.add(origin + Vector2(r + c * dx + (row % 2) * r, r + row * dy), r, w, vary(rgb, rng))
	s.bond_neighbours(1.02)
	return s


## Lightness variation ±10% per grain.
static func vary(rgb: int, rng: RandomNumberGenerator) -> int:
	var c := Color.hex((rgb << 8) | 0xff)
	c.v = clampf(c.v * rng.randf_range(0.9, 1.1), 0.0, 1.0)
	return (c.r8 << 16) | (c.g8 << 8) | c.b8


static func info_array(n: int, word: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	a.fill(word)
	return a
