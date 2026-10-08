class_name Spawn
## Deterministic particle spawners. All positions in m (y up).

const SORBET := [0xf6b17a, 0xed7e9a, 0xbea5ee, 0x8dccbc, 0xf0d487, 0x8cbbe2]


## Hex-packed block of `count` grains with lower-left corner `origin`.
static func block(count: int, origin: Vector2, cols: int, r: float, gap: float, jitter: float, rng_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var dx := 2.0 * r * (1.0 + gap)
	var dy := dx * sqrt(3.0) * 0.5
	var x := PackedVector2Array()
	var col := PackedInt32Array()
	for i in count:
		var row := i / cols
		var c := i % cols
		var p := origin + Vector2(c * dx + (row % 2) * 0.5 * dx, row * dy)
		p += Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * jitter * r
		x.append(p)
		col.append(vary(SORBET[(c * 6) / cols], rng))
	return {"x": x, "color": col}


## Lightness variation ±10% per grain.
static func vary(rgb: int, rng: RandomNumberGenerator) -> int:
	var c := Color.hex((rgb << 8) | 0xff)
	c.v = clampf(c.v * rng.randf_range(0.9, 1.1), 0.0, 1.0)
	return (c.r8 << 16) | (c.g8 << 8) | c.b8


static func fill(n: int, value) -> Array:
	var a := []
	a.resize(n)
	a.fill(value)
	return a
