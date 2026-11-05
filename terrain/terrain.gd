
extends Node3D

# ============================================================
# VOXEL PROJECT — VOLUMETRIC TERRAIN
# ============================================================
# This script controls:
# - Procedural landscape generation
# - Editable terrain density
# - Mining and building
# - Chunk mesh generation
# - Background threading
# - Terrain collision
#
# LANDSCAPE UPDATE:
# We now combine multiple noise layers to generate
# plains, rolling hills, ridges, and valleys.
#
# The marching-tetrahedra geometry and Godot triangle
# winding are preserved from our working version.
# ============================================================


# ============================================================
# WORLD SETTINGS
# ============================================================

# Number of terrain cells along each chunk axis.
@export var chunk_size: int = 16

# Physical size of each voxel cell.
@export var voxel_size: float = 1.0

# Number of chunks across X and Z.
@export var chunks_per_side: int = 4

# Number of underground chunk layers.
@export var underground_chunks: int = 4

# Average elevation of the Overworld.
@export var terrain_height: float = 7.0

# Main noise frequency.
# Smaller values create broader terrain features.
@export var noise_scale: float = 0.035

# Mining and building brush settings.
@export var brush_radius: float = 2.5
@export var brush_strength: float = 0.4

# Delay before rebuilding edited chunks.
@export var update_delay: float = 0.06


# ============================================================
# LANDSCAPE SETTINGS
# ============================================================

# Change this to generate a different landscape.
# Keeping it fixed makes the same world appear each run.
@export var world_seed: int = 12345

# Controls the amount of relatively flat terrain.
# Larger values create more plains.
@export_range(0.0, 1.0, 0.05)
var plains_amount: float = 0.45

# Height variation of ordinary rolling hills.
@export_range(0.0, 10.0, 0.5)
var hill_strength: float = 2.5

# Height variation of rugged mountain regions.
@export_range(0.0, 12.0, 0.5)
var mountain_strength: float = 6.0

# Small-scale variation added to the surface.
@export_range(0.0, 3.0, 0.1)
var detail_strength: float = 0.35


# ============================================================
# TERRAIN DATA
# ============================================================

# Different noise generators create different terrain shapes.
var region_noise := FastNoiseLite.new()
var hill_noise := FastNoiseLite.new()
var mountain_noise := FastNoiseLite.new()
var detail_noise := FastNoiseLite.new()

# Material shared by every terrain chunk.
var terrain_material: StandardMaterial3D

# Stores modified density values.
# Positive = solid terrain.
# Negative = empty space.
var density_edits: Dictionary = {}

# Currently generated terrain chunk nodes.
var chunks: Dictionary = {}

# Chunks waiting to be rebuilt.
var dirty_chunks: Dictionary = {}

# Countdown before another mesh update.
var pending_time: float = 0.0


# ============================================================
# BACKGROUND MESH WORKER
# ============================================================

# Mesh calculations run in a separate thread.
var mesh_thread: Thread = null

# True while the worker is running.
var worker_busy: bool = false

# Chunk coordinates being processed.
var worker_keys: Array[Vector3i] = []


# ============================================================
# MARCHING TETRAHEDRA CONSTANTS
# ============================================================

# Eight corners of a cubic voxel cell.
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

# Six tetrahedra that completely fill a cube.
# Every chunk uses the same subdivision.
const TETRAHEDRA = [
	[0, 1, 2, 6],
	[0, 2, 3, 6],
	[0, 3, 7, 6],
	[0, 7, 4, 6],
	[0, 4, 5, 6],
	[0, 5, 1, 6]
]

# Six edges of a tetrahedron.
const TETRA_EDGES = [
	[0, 1],
	[0, 2],
	[0, 3],
	[1, 2],
	[1, 3],
	[2, 3]
]

# Keeps density classification stable near zero.
const DENSITY_EPSILON: float = 0.00001


# ============================================================
# INITIAL SETUP
# ============================================================

func _ready() -> void:
	setup_noise()
	setup_material()

	# Build the starting surface chunks.
	# Underground chunks are generated when mining
	# exposes a surface inside them.
	var jobs: Array = []

	for cx in range(chunks_per_side):
		for cz in range(chunks_per_side):
			var key := Vector3i(cx, 0, cz)

			jobs.append({
				"key": key,
				"samples": snapshot_chunk(key),
				"size": chunk_size,
				"scale": voxel_size
			})

	# Generate the starting terrain before gameplay.
	apply_batch(build_batch(jobs))


# ============================================================
# CONFIGURE LANDSCAPE NOISE
# ============================================================

func setup_noise() -> void:
	# REGION NOISE
	# Controls which parts of the world are relatively
	# flat and which parts become mountainous.
	region_noise.seed = world_seed
	region_noise.frequency = noise_scale * 0.45
	region_noise.fractal_octaves = 3

	# HILL NOISE
	# Creates smooth rolling elevations.
	hill_noise.seed = world_seed + 100
	hill_noise.frequency = noise_scale
	hill_noise.fractal_octaves = 3

	# MOUNTAIN NOISE
	# Produces sharper, ridge-like features.
	mountain_noise.seed = world_seed + 200
	mountain_noise.frequency = noise_scale * 0.75
	mountain_noise.fractal_type = \
		FastNoiseLite.FRACTAL_RIDGED
	mountain_noise.fractal_octaves = 4

	# DETAIL NOISE
	# Adds small variations so the ground isn't
	# completely uniform.
	detail_noise.seed = world_seed + 300
	detail_noise.frequency = noise_scale * 3.0
	detail_noise.fractal_octaves = 2


# ============================================================
# CONFIGURE TERRAIN MATERIAL
# ============================================================

func setup_material() -> void:
	terrain_material = StandardMaterial3D.new()

	# Temporary grass-green material.
	terrain_material.albedo_color = Color(
		0.35, 0.55, 0.28
	)

	# Only render front-facing triangles.
	# The mesh generator uses Godot's clockwise winding.
	terrain_material.cull_mode = BaseMaterial3D.CULL_BACK

	# Avoid metallic or shiny-looking terrain.
	terrain_material.roughness = 1.0
	terrain_material.metallic = 0.0


# ============================================================
# GENERATE LANDSCAPE HEIGHT
# ============================================================

# Calculates the surface height at an X/Z position.
#
# This is the main function controlling the appearance
# of the landscape.
func get_landscape_height(x: float, z: float) -> float:

	# STEP 1: Determine the region type.
	#
	# Noise returns approximately -1 to +1.
	# Convert it to a value between 0 and 1.
	var region: float = (
		region_noise.get_noise_2d(x, z) + 1.0
	) * 0.5

	# STEP 2: Create a smooth transition between
	# plains and rugged terrain.
	#
	# Higher plains_amount means more regions stay flat.
	var ruggedness: float = smoothstep(
		plains_amount,
		minf(plains_amount + 0.35, 1.0),
		region
	)

	# STEP 3: Generate rolling hills.
	var hills: float = \
		hill_noise.get_noise_2d(x, z) * hill_strength

	# STEP 4: Generate mountain ridges.
	#
	# Ridged noise creates sharper formations than
	# ordinary smooth noise.
	var ridges: float = \
		mountain_noise.get_noise_2d(x, z)

	# Convert ridges into upward elevation.
	ridges = maxf(ridges, 0.0)

	var mountains: float = \
		ridges * mountain_strength

	# STEP 5: Blend plains and mountains.
	#
	# Plains receive smaller hills.
	# Rugged regions receive stronger hills and ridges.
	var plains_height: float = hills * 0.35

	var rugged_height: float = hills + mountains

	var elevation: float = lerpf(
		plains_height,
		rugged_height,
		ruggedness
	)

	# STEP 6: Add subtle surface detail.
	var detail: float = \
		detail_noise.get_noise_2d(x, z) * detail_strength

	# STEP 7: Combine everything.
	var final_height: float = \
		terrain_height + elevation + detail

	# Keep the prototype terrain inside the existing
	# Y = 0 to Y = 16 surface chunk.
	#
	# Later, vertical chunk streaming will allow
	# mountains to grow far beyond these limits.
	return clampf(final_height, 2.0, 14.0)


# ============================================================
# TERRAIN DENSITY
# ============================================================

# Returns the original density before player edits.
func original_density(point: Vector3) -> float:
	var height: float = get_landscape_height(
		point.x,
		point.z
	)

	# Positive values are underground.
	# Negative values are above the surface.
	return height - point.y


# Returns the current density at a grid coordinate.
func density_at_grid(grid: Vector3i) -> float:
	# Player edits override the original landscape.
	if density_edits.has(grid):
		return float(density_edits[grid])

	return original_density(
		Vector3(grid) * voxel_size
	)


# Prevent extremely small density values from causing
# unstable zero-crossing classifications.
func stable_density(value: float) -> float:
	if value == 0.0:
		return -DENSITY_EPSILON

	if value > 0.0 and value < DENSITY_EPSILON:
		return DENSITY_EPSILON

	if value < 0.0 and value > -DENSITY_EPSILON:
		return -DENSITY_EPSILON

	return value


# ============================================================
# FRAME UPDATE AND THREAD MANAGEMENT
# ============================================================

func _process(delta: float) -> void:
	# Check whether the background worker has finished.
	if worker_busy and not mesh_thread.is_alive():
		var results: Array = mesh_thread.wait_to_finish()

		mesh_thread = null
		worker_busy = false

		# Detect whether any chunk in this batch
		# was edited again while the worker ran.
		var outdated: bool = false

		for key in worker_keys:
			if dirty_chunks.has(key):
				outdated = true
				break

		if outdated:
			# Keep the old visible geometry and
			# rebuild the affected chunks together.
			for key in worker_keys:
				dirty_chunks[key] = true

			pending_time = update_delay
		else:
			# Install all completed chunks together.
			apply_batch(results)

		worker_keys.clear()

	# Start another job if chunks need updating.
	if not worker_busy and not dirty_chunks.is_empty():
		pending_time -= delta

		if pending_time <= 0.0:
			start_batch()


# Stop the worker safely when the scene closes.
func _exit_tree() -> void:
	if mesh_thread != null:
		mesh_thread.wait_to_finish()
		mesh_thread = null
		worker_busy = false


# ============================================================
# MINING AND BUILDING
# ============================================================

# Called by the player's Terrain Cannon.
#
# add_terrain = true: build.
# add_terrain = false: mine.
func sculpt(
	world_position: Vector3,
	add_terrain: bool
) -> void:

	# Convert the hit position into terrain coordinates.
	var center: Vector3 = to_local(world_position)

	# Convert the brush size into grid units.
	var radius: float = maxf(brush_radius, 0.01)
	var radius_grid: float = radius / voxel_size
	var center_grid: Vector3 = center / voxel_size

	# Current prototype world boundaries.
	var width: int = chunks_per_side * chunk_size
	var bottom: int = -underground_chunks * chunk_size
	var top: int = chunk_size

	# Calculate the grid points near the brush.
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

	# Positive density builds; negative density mines.
	var direction: float = \
		1.0 if add_terrain else -1.0

	# Collect every chunk touched by the edit.
	var affected: Dictionary = {}

	# Visit grid points inside the brush's bounding box.
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			for z in range(min_z, max_z + 1):

				var grid := Vector3i(x, y, z)
				var point := Vector3(grid) * voxel_size

				var distance: float = \
					point.distance_to(center)

				# Ignore points outside the spherical brush.
				if distance >= radius:
					continue

				# Smooth falloff creates rounded excavation.
				var falloff: float = 1.0 - distance / radius

				falloff = falloff * falloff * \
					(3.0 - 2.0 * falloff)

				# Store the new density.
				density_edits[grid] = \
					density_at_grid(grid) + \
					direction * brush_strength * falloff

				# A grid point can belong to several chunks.
				# Mark all chunks sharing this point.
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

	# Nothing changed if the brush missed the terrain.
	if affected.is_empty():
		return

	# Schedule all affected chunks for regeneration.
	for key in affected:
		dirty_chunks[key] = true

	if not worker_busy and pending_time <= 0.0:
		pending_time = update_delay


# ============================================================
# CHUNK DENSITY SNAPSHOTS
# ============================================================

# Copies a chunk's density values into an array.
# This array can safely be read by the worker thread.
func snapshot_chunk(
	key: Vector3i
) -> PackedFloat32Array:

	# A chunk of 16 cells needs 17 corner samples.
	var side: int = chunk_size + 1

	var samples := PackedFloat32Array()
	samples.resize(side * side * side)

	# Convert chunk position into grid coordinates.
	var origin: Vector3i = key * chunk_size

	for x in range(side):
		for y in range(side):
			for z in range(side):

				# Convert 3D coordinates into an array index.
				var index: int = \
					(x * side + y) * side + z

				# Shared grid coordinates ensure
				# neighboring chunks use matching values.
				samples[index] = stable_density(
					density_at_grid(
						origin + Vector3i(x, y, z)
					)
				)

	return samples


# ============================================================
# START BACKGROUND MESH GENERATION
# ============================================================

func start_batch() -> void:
	var jobs: Array = []
	worker_keys.clear()

	# Snapshot every chunk that needs updating.
	for key in dirty_chunks:
		var typed_key: Vector3i = key

		worker_keys.append(typed_key)

		jobs.append({
			"key": typed_key,
			"samples": snapshot_chunk(typed_key),
			"size": chunk_size,
			"scale": voxel_size
		})

	# New edits during the worker job will be
	# collected for a later batch.
	dirty_chunks.clear()
	pending_time = 0.0

	mesh_thread = Thread.new()

	# Generate the triangle arrays in the background.
	var error: Error = mesh_thread.start(
		Callable(self, "build_batch").bind(jobs)
	)

	if error != OK:
		push_error("Terrain worker failed to start.")
		mesh_thread = null

		# Restore the queued chunks if startup fails.
		for key in worker_keys:
			dirty_chunks[key] = true

		worker_keys.clear()
		pending_time = update_delay
		return

	worker_busy = true


# ============================================================
# BACKGROUND CHUNK MESH GENERATION
# ============================================================

# This runs on the worker thread during gameplay.
# It only generates arrays, not scene nodes.
func build_batch(jobs: Array) -> Array:
	var results: Array = []

	for job in jobs:
		results.append(
			build_chunk_data(
				job["key"],
				job["samples"],
				job["size"],
				job["scale"]
			)
		)

	return results


# Converts one chunk's density grid into triangles.
func build_chunk_data(
	key: Vector3i,
	samples: PackedFloat32Array,
	size: int,
	scale: float
) -> Dictionary:

	# Vertex positions and lighting normals.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()

	var side: int = size + 1
	var origin: Vector3i = key * size

	# Examine every cubic cell.
	for x in range(size):
		for y in range(size):
			for z in range(size):

				var points: Array[Vector3] = []
				var values: Array[float] = []

				var has_solid: bool = false
				var has_air: bool = false

				# Read all eight corners.
				for corner in CORNERS:
					var lx: int = x + corner.x
					var ly: int = y + corner.y
					var lz: int = z + corner.z

					var index: int = \
						(lx * side + ly) * side + lz

					var value: float = samples[index]
					values.append(value)

					if value > 0.0:
						has_solid = true
					else:
						has_air = true

					points.append(
						Vector3(
							origin + Vector3i(lx, ly, lz)
						) * scale
					)

				# Skip completely solid or empty cells.
				if not has_solid or not has_air:
					continue

				# Convert six tetrahedra into surface triangles.
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


# ============================================================
# INSTALL FINISHED MESHES AND COLLISION
# ============================================================

# This function runs on the main thread.
func apply_batch(results: Array) -> void:
	var replacements: Dictionary = {}

	# Prepare all replacement chunks first.
	for result in results:
		var key: Vector3i = result["key"]

		var vertices: PackedVector3Array = \
			result["vertices"]

		var normals: PackedVector3Array = \
			result["normals"]

		# Solid or empty chunks have no visible surface.
		if vertices.is_empty():
			replacements[key] = null
			continue

		# Godot mesh data format.
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)

		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals

		# Create the visible triangle mesh.
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES,
			arrays
		)

		# Parent node for the chunk.
		var chunk_node := Node3D.new()
		chunk_node.name = "Chunk_%d_%d_%d" % [
			key.x, key.y, key.z
		]

		# Visible geometry.
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.material_override = \
			terrain_material

		chunk_node.add_child(mesh_instance)

		# Physical collision.
		var body := StaticBody3D.new()
		chunk_node.add_child(body)

		var collision := CollisionShape3D.new()
		var shape := mesh.create_trimesh_shape()

		# Permit collision from both sides.
		shape.backface_collision = true
		collision.shape = shape

		body.add_child(collision)

		replacements[key] = chunk_node

	# Remove old chunks.
	for key in replacements:
		var old_chunk: Node3D = \
			chunks.get(key) as Node3D

		if old_chunk != null:
			for child in old_chunk.get_children():
				if child is StaticBody3D:
					child.collision_layer = 0
					child.collision_mask = 0

			old_chunk.visible = false
			old_chunk.queue_free()
			chunks.erase(key)

	# Install every replacement together.
	for key in replacements:
		var new_chunk: Node3D = \
			replacements[key] as Node3D

		if new_chunk != null:
			add_child(new_chunk)
			chunks[key] = new_chunk


# ============================================================
# MARCHING TETRAHEDRA
# ============================================================

# Converts one tetrahedron into one or two triangles.
func polygonize_tetra(
	points: Array[Vector3],
	values: Array[float],
	tetra: Array,
	vertices: PackedVector3Array,
	normals: PackedVector3Array
) -> void:

	# Count solid corners.
	var solid_count: int = 0

	for index in tetra:
		if values[index] > 0.0:
			solid_count += 1

	# No surface if all corners are solid or empty.
	if solid_count == 0 or solid_count == 4:
		return

	# Estimate which direction points toward air.
	var solid_center := Vector3.ZERO
	var air_center := Vector3.ZERO

	for index in tetra:
		if values[index] > 0.0:
			solid_center += points[index]
		else:
			air_center += points[index]

	solid_center /= float(solid_count)
	air_center /= float(4 - solid_count)

	var outward: Vector3 = (
		air_center - solid_center
	).normalized()

	# Find edges crossing the solid/air boundary.
	var crossings: Array[Vector3] = []

	for edge in TETRA_EDGES:
		var a: int = tetra[edge[0]]
		var b: int = tetra[edge[1]]

		var a_solid: bool = values[a] > 0.0
		var b_solid: bool = values[b] > 0.0

		if a_solid != b_solid:
			crossings.append(
				interpolate(points, values, a, b)
			)

	if crossings.size() < 3:
		return

	# Find the center of the intersection polygon.
	var center := Vector3.ZERO

	for point in crossings:
		center += point

	center /= float(crossings.size())

	# Create axes for sorting the polygon's corners.
	var axis_u: Vector3 = crossings[0] - center

	if axis_u.length_squared() < 0.000000000001:
		return

	axis_u = axis_u.normalized()

	var axis_v: Vector3 = outward.cross(axis_u)

	if axis_v.length_squared() < 0.000000000001:
		return

	axis_v = axis_v.normalized()

	# Sort corners around the center.
	# This prevents crossed quadrilaterals.
	var ordered: Array = []

	for point in crossings:
		var relative: Vector3 = point - center

		var angle: float = atan2(
			relative.dot(axis_v),
			relative.dot(axis_u)
		)

		ordered.append({
			"point": point,
			"angle": angle
		})

	ordered.sort_custom(
		func(a, b):
			return a["angle"] < b["angle"]
	)

	# Generate one or two triangles.
	for i in range(1, ordered.size() - 1):
		var a: Vector3 = ordered[0]["point"]
		var b: Vector3 = ordered[i]["point"]
		var c: Vector3 = ordered[i + 1]["point"]

		add_triangle(
			vertices,
			normals,
			a,
			b,
			c,
			outward
		)


# ============================================================
# FIND SURFACE INTERSECTION
# ============================================================

func interpolate(
	points: Array[Vector3],
	values: Array[float],
	a: int,
	b: int
) -> Vector3:

	var denominator: float = values[a] - values[b]

	# Avoid division by zero.
	if absf(denominator) < 0.000000000001:
		return (points[a] + points[b]) * 0.5

	# Find where density crosses zero.
	var t: float = values[a] / denominator

	return points[a].lerp(points[b], t)


# ============================================================
# ADD A TRIANGLE WITH CORRECT GODOT WINDING
# ============================================================

func add_triangle(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	outward: Vector3
) -> void:

	# Calculate the triangle's geometric normal.
	var cross_normal: Vector3 = \
		(b - a).cross(c - a)

	# Skip only truly degenerate triangles.
	if cross_normal.length_squared() < 0.000000000001:
		return

	# Godot uses clockwise front-facing triangles.
	# Reverse winding if the cross product points outward.
	if cross_normal.dot(outward) > 0.0:
		var temp: Vector3 = b
		b = c
		c = temp

		cross_normal = -cross_normal

	# Lighting normals point toward empty space.
	var lighting_normal: Vector3 = \
		-cross_normal.normalized()

	# Add triangle positions.
	vertices.append(a)
	vertices.append(b)
	vertices.append(c)

	# Flat normals preserve our low-poly appearance.
	normals.append(lighting_normal)
	normals.append(lighting_normal)
	normals.append(lighting_normal)
