class_name Tetromino
## Bonded tetromino pieces: hex-packed grains filling the union of 4 cells,
## every touching pair bonded. Shredding emerges from bond strain only.

const SHAPES := {
	"I": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)],
	"O": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
	"T": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, 1)],
	"S": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(2, 1)],
	"Z": [Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1)],
	"L": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(2, 1)],
	"J": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1)],
}
const MATERIAL := 1


## Piece with its lower-left corner at origin. block = grains per cell edge.
static func make(shape: String, origin: Vector2, block: int, rgb: int, rng: RandomNumberGenerator,
		vel := Vector2.ZERO) -> ParticleSet:
	var cells: Array = SHAPES[shape]
	var r := SimConst.R
	var cell := block * 2.0 * r
	var w := GpuSolver.info_word(2, MATERIAL)
	var s := ParticleSet.new()
	var h := 0
	for c in cells:
		h = maxi(h, c.y + 1)
	var rows := int(floor((h * cell - 2.0 * r) / (sqrt(3.0) * r))) + 1
	var cols := 4 * block
	for j in rows:
		var y := r + j * sqrt(3.0) * r
		for i in cols:
			var x := r + i * 2.0 * r + (r if j % 2 == 1 else 0.0)
			var key := Vector2i(floori(x / cell), floori(y / cell))
			if key in cells:
				s.add(origin + Vector2(x, y), r, w, Spawn.vary(rgb, rng), vel)
	s.bond_neighbours(1.02)
	return s
