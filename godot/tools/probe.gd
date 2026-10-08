class_name Probe
## CPU-side analysis of solver readbacks (tests only).


## Pairwise overlap stats via a hash grid. Returns max penetration in units of r.
static func overlap(pos: PackedVector2Array, r: float, active := -1) -> Dictionary:
	var n := pos.size() if active < 0 else active
	var cell := 2.0 * r
	var g := {}
	for i in n:
		var k := Vector2i(floori(pos[i].x / cell), floori(pos[i].y / cell))
		if not g.has(k):
			g[k] = []
		g[k].append(i)
	var max_pen := 0.0
	var over := 0
	var pairs := 0
	for i in n:
		var k := Vector2i(floori(pos[i].x / cell), floori(pos[i].y / cell))
		for oy in [-1, 0, 1]:
			for ox in [-1, 0, 1]:
				var kk := k + Vector2i(ox, oy)
				if not g.has(kk):
					continue
				for j in g[kk]:
					if j <= i:
						continue
					var d := pos[i].distance_to(pos[j])
					if d < 2.0 * r:
						pairs += 1
						var pen := (2.0 * r - d) / r
						max_pen = maxf(max_pen, pen)
						if pen > 0.25:
							over += 1
	return {"max_pen_r": snappedf(max_pen, 0.001), "pairs_over_quarter_r": over, "contacts": pairs}


static func extent(pos: PackedVector2Array, active := -1) -> Rect2:
	var n := pos.size() if active < 0 else active
	var rect := Rect2(pos[0], Vector2.ZERO)
	for i in n:
		rect = rect.expand(pos[i])
	return rect
