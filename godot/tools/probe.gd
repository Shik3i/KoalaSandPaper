class_name Probe
## CPU-side analysis of solver readbacks (tests only).


## Pairwise overlap stats via a hash grid. Returns max penetration in units of r.
static func overlap(pos: PackedVector2Array, rad: PackedFloat32Array, info := PackedInt32Array()) -> Dictionary:
	var n := pos.size()
	var r := SimConst.R
	var cell := 2.0 * SimConst.R_MAX
	var g := {}
	for i in n:
		if not info.is_empty() and (info[i] >> 8) & 0xff == 0:
			continue
		var k := Vector2i(floori(pos[i].x / cell), floori(pos[i].y / cell))
		if not g.has(k):
			g[k] = []
		g[k].append(i)
	var max_pen := 0.0
	var max_at := Vector2.ZERO
	var over := 0
	var pairs := 0
	for i in n:
		if not info.is_empty() and (info[i] >> 8) & 0xff == 0:
			continue
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
					var d0 := rad[i] + rad[j]
					if d < d0:
						pairs += 1
						var pen := (d0 - d) / minf(rad[i], rad[j])
						if pen > max_pen:
							max_pen = pen
							max_at = pos[i]
						if pen > 0.25:
							over += 1
	return {"max_pen_r": snappedf(max_pen, 0.001), "max_at": max_at, "pairs_over_quarter_r": over, "contacts": pairs}


static func extent(pos: PackedVector2Array, info := PackedInt32Array()) -> Rect2:
	var rect := Rect2()
	var first := true
	for i in pos.size():
		if not info.is_empty() and (info[i] >> 8) & 0xff == 0:
			continue
		rect = Rect2(pos[i], Vector2.ZERO) if first else rect.expand(pos[i])
		first = false
	return rect
