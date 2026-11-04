
extends Node3D

@export var chunk_size: int = 16
@export var voxel_size: float = 1.0
@export var chunks_per_side: int = 4
@export var underground_chunks: int = 4

@export var terrain_height: float = 7.0
@export var noise_scale: float = 0.035

@export var brush_radius: float = 2.5
@export var brush_strength: float = 0.4

var noise := FastNoiseLite.new()

var density_edits: Dictionary = {}
var density_cache: Dictionary = {}

var chunks: Dictionary = {}
var dirty_chunks: Dictionary = {}
var dirty_queue: Array[Vector3i] = []

var terrain_material: StandardMaterial3D

# Only one worker is used initially.
var mesh_thread: Thread
var worker_busy: bool = false

const CORNERS = [
	Vector3i(0, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(1, 1, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, 0, 1),
	Vector3i(1, 0, 1),
	Vector3i(1, 1, 1),
	Vector3i(0, 1, 1)
]

const TETRAHEDRA = [
	[0, 5, 1, 6],
	[0, 1, 2, 6],
	[0, 2, 3, 6],
	[0, 3, 7, 6],
	[0, 7, 4, 6],
	[0, 4, 5, 6]
]


func _ready() -> void:
	noise.seed = 12345
	noise.frequency = noise_scale

	terrain_material = StandardMaterial3D.new()
	terrain_material.albedo_color = Color(
		0.35, 0.55, 0.28
	)
	terrain_material.cull_mode = \
		BaseMaterial3D.CULL_DISABLED

	# Build the initial surface before gameplay.
	# Underground chunks are solid and need no mesh
	# until mining creates an exposed surface.
	for cx in range(chunks_per_side):
		for cz in range(chunks_per_side):
			var key := Vector3i(cx, 0, cz)
			var samples := snapshot_chunk(key)
			var result := build_chunk_data(key, samples)
			apply_chunk_result(result)


func _process(_delta: float) -> void:
	# Collect a completed worker job.
	if worker_busy:
		if not mesh_thread.is_alive():
			var result: Dictionary = \
				mesh_thread.wait_to_finish()

			worker_busy = false
			mesh_thread = null

			apply_chunk_result(result)

	# Start the next job when the worker is free.
	if not worker_busy:
		start_next_chunk_job()


func _exit_tree() -> void:
	if mesh_thread != null:
		mesh_thread.wait_to_finish()
		mesh_thread = null
		worker_busy = false


func original_density(point: Vector3) -> float:
	var height: float = terrain_height + \
		noise.get_noise_2d(
			point.x, point.z
		) * 5.0

	return height - point.y


func density_at_grid(grid: Vector3i) -> float:
	if density_edits.has(grid):
		return float(density_edits[grid])

	if density_cache.has(grid):
		return float(density_cache[grid])

	var value: float = original_density(
		Vector3(grid) * voxel_size
	)

	density_cache[grid] = value
	return value


func sculpt(
	world_position: Vector3,
	add_terrain: bool
) -> void:
	var center: Vector3 = to_local(world_position)
	var center_grid: Vector3 = center / voxel_size
	var radius_grid: float = brush_radius / voxel_size

	var width: int = chunks_per_side * chunk_size
	var bottom: int = -underground_chunks * chunk_size
	var top: int = chunk_size

	var min_x: int = maxi(
		0, floori(center_grid.x - radius_grid)
	)
	var max_x: int = mini(
		width, ceili(center_grid.x + radius_grid)
	)

	var min_y: int = maxi(
		bottom, floori(center_grid.y - radius_grid)
	)
	var max_y: int = mini(
		top, ceili(center_grid.y + radius_grid)
	)

	var min_z: int = maxi(
		0, floori(center_grid.z - radius_grid)
	)
	var max_z: int = mini(
		width, ceili(center_grid.z + radius_grid)
	)

	var direction: float = \
		1.0 if add_terrain else -1.0

	var affected: Dictionary = {}

	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			for z in range(min_z, max_z + 1):
				var grid := Vector3i(x, y, z)

				var point: Vector3 = \
					Vector3(grid) * voxel_size

				var distance: float = \
					point.distance_to(center)

				if distance >= brush_radius:
					continue

				var falloff: float = \
					1.0 - distance / brush_radius

				falloff = falloff * falloff * \
					(3.0 - 2.0 * falloff)

				var old_value: float = \
					density_at_grid(grid)

				density_edits[grid] = \
					old_value + \
					direction * brush_strength * falloff

				# Queue every chunk sharing this point.
				var first_cx: int = maxi(
					0,
					ceili(float(x) / chunk_size) - 1
				)
				var last_cx: int = mini(
					chunks_per_side - 1,
					floori(float(x) / chunk_size)
				)

				var first_cy: int = maxi(
					-underground_chunks,
					ceili(float(y) / chunk_size) - 1
				)
				var last_cy: int = mini(
					0,
					floori(float(y) / chunk_size)
				)

				var first_cz: int = maxi(
					0,
					ceili(float(z) / chunk_size) - 1
				)
				var last_cz: int = mini(
					chunks_per_side - 1,
					floori(float(z) / chunk_size)
				)

				for cx in range(first_cx, last_cx + 1):
					for cy in range(first_cy, last_cy + 1):
						for cz in range(first_cz, last_cz + 1):
							affected[
								Vector3i(cx, cy, cz)
							] = true

	for key in affected:
		queue_chunk_rebuild(key)


func queue_chunk_rebuild(key: Vector3i) -> void:
	if dirty_chunks.has(key):
		return

	dirty_chunks[key] = true
	dirty_queue.append(key)


func start_next_chunk_job() -> void:
	if dirty_queue.is_empty():
		return

	var key: Vector3i = dirty_queue.pop_front()
	dirty_chunks.erase(key)

	# Take an immutable snapshot on the main thread.
	# The worker will not touch editable dictionaries.
	var samples: PackedFloat32Array = \
		snapshot_chunk(key)

	mesh_thread = Thread.new()

	var error: Error = mesh_thread.start(
		Callable(self, "build_chunk_data").bind(
			key, samples
		)
	)

	if error != OK:
		push_error(
            "Could not start terrain mesh worker."
		)
		mesh_thread = null
		queue_chunk_rebuild(key)
		return

	worker_busy = true


func snapshot_chunk(
	key: Vector3i
) -> PackedFloat32Array:
	var side: int = chunk_size + 1

	var samples := PackedFloat32Array()
	samples.resize(side * side * side)

	var origin: Vector3i = key * chunk_size

	for x in range(side):
		for y in range(side):
			for z in range(side):
				var grid: Vector3i = origin + \
					Vector3i(x, y, z)

				var index: int = \
					(x * side + y) * side + z

				samples[index] = density_at_grid(grid)

	return samples


func sample_local(
	samples: PackedFloat32Array,
	x: int,
	y: int,
	z: int
) -> float:
	var side: int = chunk_size + 1
	var index: int = (x * side + y) * side + z
	return samples[index]


# This function runs on the worker thread for edits.
# It must not access the scene tree or physics server.
func build_chunk_data(
	key: Vector3i,
	samples: PackedFloat32Array
) -> Dictionary:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()

	var origin: Vector3i = key * chunk_size

	for x in range(chunk_size):
		for y in range(chunk_size):
			for z in range(chunk_size):
				var points: Array[Vector3] = []
				var values: Array[float] = []

				for corner in CORNERS:
					var lx: int = x + corner.x
					var ly: int = y + corner.y
					var lz: int = z + corner.z

					var grid: Vector3i = origin + \
						Vector3i(lx, ly, lz)

					points.append(
						Vector3(grid) * voxel_size
					)

					values.append(
						sample_local(
							samples, lx, ly, lz
						)
					)

				for tetra in TETRAHEDRA:
					polygonize_tetra(
						points,
						values,
						tetra,
						vertices,
						normals
					)

	return {
		"key": key,
		"vertices": vertices,
		"normals": normals
	}


# Called on the main thread only.
func apply_chunk_result(result: Dictionary) -> void:
	var key: Vector3i = result["key"]

	var vertices: PackedVector3Array = \
		result["vertices"]

	var normals: PackedVector3Array = \
		result["normals"]

	var old_chunk: Node3D = \
		chunks.get(key) as Node3D

	# Construct the replacement before removing
	# the old chunk to minimize collision gaps.
	var new_chunk: Node3D = null

	if not vertices.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)

		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals

		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES,
			arrays
		)

		new_chunk = Node3D.new()
		new_chunk.name = "Chunk_%d_%d_%d" % [
			key.x, key.y, key.z
		]

		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.material_override = \
			terrain_material

		new_chunk.add_child(mesh_instance)

		var body := StaticBody3D.new()
		new_chunk.add_child(body)

		var collision := CollisionShape3D.new()
		var terrain_shape := mesh.create_trimesh_shape()
		terrain_shape.backface_collision = true
		collision.shape = terrain_shape

		body.add_child(collision)

	if old_chunk != null:
		for child in old_chunk.get_children():
			if child is StaticBody3D:
				child.collision_layer = 0
				child.collision_mask = 0

		old_chunk.queue_free()
		chunks.erase(key)

	if new_chunk != null:
		add_child(new_chunk)
		chunks[key] = new_chunk


func polygonize_tetra(
	points: Array[Vector3],
	values: Array[float],
	tetra: Array,
	vertices: PackedVector3Array,
	normals: PackedVector3Array
) -> void:
	var inside: Array[int] = []
	var outside: Array[int] = []

	for index in tetra:
		if values[index] > 0.0:
			inside.append(index)
		else:
			outside.append(index)

	if inside.is_empty() or inside.size() == 4:
		return

	var inside_center := Vector3.ZERO
	var outside_center := Vector3.ZERO

	for index in inside:
		inside_center += points[index]

	inside_center /= float(inside.size())

	for index in outside:
		outside_center += points[index]

	outside_center /= float(outside.size())

	var outward: Vector3 = (
		outside_center - inside_center
	).normalized()

	if inside.size() == 1:
		var a := interpolate(
			points, values,
			inside[0], outside[0]
		)
		var b := interpolate(
			points, values,
			inside[0], outside[1]
		)
		var c := interpolate(
			points, values,
			inside[0], outside[2]
		)

		add_triangle(
			vertices, normals,
			a, b, c, outward
		)

	elif inside.size() == 3:
		var a := interpolate(
			points, values,
			outside[0], inside[0]
		)
		var b := interpolate(
			points, values,
			outside[0], inside[1]
		)
		var c := interpolate(
			points, values,
			outside[0], inside[2]
		)

		add_triangle(
			vertices, normals,
			a, c, b, outward
		)

	elif inside.size() == 2:
		var a := interpolate(
			points, values,
			inside[0], outside[0]
		)
		var b := interpolate(
			points, values,
			inside[0], outside[1]
		)
		var c := interpolate(
			points, values,
			inside[1], outside[0]
		)
		var d := interpolate(
			points, values,
			inside[1], outside[1]
		)

		add_triangle(
			vertices, normals,
			a, b, c, outward
		)
		add_triangle(
			vertices, normals,
			b, d, c, outward
		)


func interpolate(
	points: Array[Vector3],
	values: Array[float],
	a: int,
	b: int
) -> Vector3:
	var denominator: float = \
		values[a] - values[b]

	if absf(denominator) < 0.00001:
		return (points[a] + points[b]) * 0.5

	var t: float = values[a] / denominator
	return points[a].lerp(points[b], t)


func add_triangle(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	outward: Vector3
) -> void:
	var normal: Vector3 = \
		(b - a).cross(c - a)

	if normal.length_squared() < 0.000001:
		return

	if normal.dot(outward) < 0.0:
		var temp := b
		b = c
		c = temp
		normal = -normal

	normal = normal.normalized()

	vertices.append(a)
	vertices.append(b)
	vertices.append(c)

	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
