class_name Hud
extends CanvasLayer
## Title, station labels with leader lines, live counters (async stats readback,
## bookkeeping only). German UI strings.

const INK := Color("#9fb3b8")
const DIM := Color("#5f7479")
const ACCENT := Color("#e0a93b")

var factory: Factory
var ppm := 100.0
var _burned: Label
var _active: Label
var _lift: Label
var _pending := false
var _total := 0


func setup(f: Factory, px_per_m: float) -> void:
	factory = f
	ppm = px_per_m
	layer = 5
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_label(root, "KOALASANDPAPER", Vector2(4.25, 6.64), 0.16, INK)
	_label(root, "KINETIC STUDY 001", Vector2(4.25, 6.42), 0.09, DIM)
	var lines := Lines.new()
	lines.hud = self
	root.add_child(lines)
	for k in f.stations:
		_label(root, k, f.stations[k], 0.095, INK)
	_burned = _label(root, "", Vector2(9.55, 6.62), 0.095, ACCENT)
	_active = _label(root, "", Vector2(9.55, 6.44), 0.095, INK)
	_lift = _label(root, "", Vector2(9.55, 6.26), 0.095, DIM)


func to_px(p: Vector2) -> Vector2:
	return Vector2(p.x, Factory.WORLD.y - p.y) * ppm


func _label(root: Control, text: String, at: Vector2, size_m: float, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = to_px(at) - Vector2(0, size_m * ppm * 0.7)
	var ls := LabelSettings.new()
	ls.font_size = maxi(8, int(size_m * ppm))
	ls.font_color = col
	l.label_settings = ls
	root.add_child(l)
	return l


## Reads the stats buffer asynchronously and updates the counters.
func request(solver: GpuSolver, total_in: int) -> void:
	if _pending:
		return
	_pending = true
	_total = total_in
	solver.rd.buffer_get_data_async(solver._buf.stats, _on_stats)


func _on_stats(data: PackedByteArray) -> void:
	_pending = false
	var burned := data.decode_u32(8 * 4 + 2 * 4)
	var drained := data.decode_u32(8 * 4 + 3 * 4)
	_burned.text = "VERBRANNT  %s" % _group(burned)
	_active.text = "IM UMLAUF  %s" % _group(maxi(_total - burned - drained, 0))
	_lift.text = "KÖRNER GESAMT  %s" % _group(_total)


static func _group(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "." + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


class Lines:
	extends Control
	## Thin leader ticks under each station label.
	var hud: Hud

	func _draw() -> void:
		for k in hud.factory.stations:
			var p: Vector2 = hud.to_px(hud.factory.stations[k]) + Vector2(0, 0.025 * hud.ppm)
			draw_line(p, p + Vector2(0.55 * hud.ppm, 0), Hud.ACCENT.darkened(0.3), maxf(1.0, 0.006 * hud.ppm))
