class_name GranularSimulator
extends RefCounted

const DOWN := Vector2i(0, 1)
const DOWN_LEFT := Vector2i(-1, 1)
const DOWN_RIGHT := Vector2i(1, 1)

var world: CellWorld
var tick_index: int = 0
var sleep_after_stable_ticks: int
var last_movements: int = 0
var total_movements: int = 0
var last_scanned_chunks: int = 0
var last_scanned_cells: int = 0


func _init(
	cell_world: CellWorld,
	sleep_threshold: int = WorldConfig.CHUNK_SLEEP_AFTER_STABLE_TICKS
) -> void:
	assert(cell_world != null)
	assert(sleep_threshold > 0)
	world = cell_world
	sleep_after_stable_ticks = sleep_threshold


func step() -> int:
	var active_coordinates := world.get_active_chunk_coordinates()
	var coordinates_by_y: Dictionary = {}
	for coordinate in active_coordinates:
		if not coordinates_by_y.has(coordinate.y):
			coordinates_by_y[coordinate.y] = [] as Array[Vector2i]
		var band: Array[Vector2i] = coordinates_by_y[coordinate.y]
		band.append(coordinate)

	var chunk_rows: Array[int] = []
	for chunk_y in coordinates_by_y.keys():
		chunk_rows.append(chunk_y as int)
	chunk_rows.sort()
	chunk_rows.reverse()

	var moved_chunks: Dictionary = {}
	last_movements = 0
	last_scanned_chunks = active_coordinates.size()
	last_scanned_cells = active_coordinates.size() * WorldConfig.CELLS_PER_CHUNK
	var scan_left_to_right := (tick_index & 1) == 0

	for chunk_y in chunk_rows:
		var row_chunks: Array[Vector2i] = coordinates_by_y[chunk_y]
		row_chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.x < b.x if scan_left_to_right else a.x > b.x
		)
		for local_y in range(WorldConfig.CHUNK_SIZE - 1, -1, -1):
			for chunk_coordinate in row_chunks:
				_simulate_chunk_row(
					world.get_chunk(chunk_coordinate),
					local_y,
					scan_left_to_right,
					moved_chunks
				)

	for coordinate in active_coordinates:
		var chunk := world.get_chunk(coordinate)
		chunk.record_simulation_result(moved_chunks.has(coordinate), sleep_after_stable_ticks)

	tick_index += 1
	total_movements += last_movements
	return last_movements


func _simulate_chunk_row(
	chunk: SimChunk,
	local_y: int,
	scan_left_to_right: bool,
	moved_chunks: Dictionary
) -> void:
	var x_start := 0 if scan_left_to_right else WorldConfig.CHUNK_SIZE - 1
	var x_end := WorldConfig.CHUNK_SIZE if scan_left_to_right else -1
	var x_step := 1 if scan_left_to_right else -1
	for local_x in range(x_start, x_end, x_step):
		var index := local_y * WorldConfig.CHUNK_SIZE + local_x
		var material_id := chunk.material_ids[index]
		if world.materials.get_category(material_id) != MaterialDefinition.Category.GRANULAR:
			continue
		var source := WorldConfig.chunk_local_to_world(chunk.coordinate, Vector2i(local_x, local_y))
		var destination := _choose_destination(source)
		if destination == source or not world.move_cell_if_empty(source, destination):
			continue
		last_movements += 1
		moved_chunks[chunk.coordinate] = true
		moved_chunks[WorldConfig.world_to_chunk(destination)] = true


func _choose_destination(source: Vector2i) -> Vector2i:
	var direct := source + DOWN
	if world.get_cell(direct) == MaterialRegistry.EMPTY_ID:
		return direct

	var prefer_left := (DeterministicHash.hash_2d(world.seed, source, tick_index) & 1) == 0
	var first := source + (DOWN_LEFT if prefer_left else DOWN_RIGHT)
	if world.get_cell(first) == MaterialRegistry.EMPTY_ID:
		return first
	var second := source + (DOWN_RIGHT if prefer_left else DOWN_LEFT)
	if world.get_cell(second) == MaterialRegistry.EMPTY_ID:
		return second
	return source
