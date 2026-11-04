
extends CharacterBody3D

@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var jump_velocity: float = 5.0
@export var mouse_sensitivity: float = 0.002

@export var sculpt_interval: float = 0.05

@onready var head: Node3D = $Head

@onready var terrain_cannon: Node3D = \
	$Head/Camera3D/TerrainCannon

@onready var terrain_ray: RayCast3D = \
	$Head/Camera3D/TerrainRay

@onready var terrain = get_parent().get_node("Terrain")

var gravity: float = 9.8
var cannon_equipped: bool = true
var sculpt_timer: float = 0.0


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	terrain_cannon.visible = cannon_equipped


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			rotate_y(-event.relative.x * mouse_sensitivity)
			head.rotate_x(-event.relative.y * mouse_sensitivity)

			head.rotation.x = clamp(
				head.rotation.x,
				deg_to_rad(-89),
				deg_to_rad(89)
			)

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	if event is InputEventMouseButton:
		if event.pressed:
			if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				return

			if cannon_equipped:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					change_brush_size(0.5)

				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					change_brush_size(-0.5)

	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_F:
				cannon_equipped = not cannon_equipped
				terrain_cannon.visible = cannon_equipped


func _physics_process(delta: float) -> void:
	handle_movement(delta)
	handle_terrain_cannon(delta)


func handle_movement(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var speed: float = walk_speed

	if Input.is_action_pressed("sprint"):
		speed = sprint_speed

	var input_dir: Vector2 = Input.get_vector(
		"move_left",
		"move_right",
		"move_forward",
        "move_backward"
	)

	var direction: Vector3 = (
		transform.basis *
		Vector3(input_dir.x, 0, input_dir.y)
	).normalized()

	if direction.length() > 0.0:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(
			velocity.x, 0.0, speed * delta * 10.0
		)

		velocity.z = move_toward(
			velocity.z, 0.0, speed * delta * 10.0
		)

	move_and_slide()


func handle_terrain_cannon(delta: float) -> void:
	if not cannon_equipped:
		return

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return

	sculpt_timer -= delta

	if sculpt_timer > 0.0:
		return

	var mining: bool = Input.is_mouse_button_pressed(
		MOUSE_BUTTON_LEFT
	)

	var building: bool = Input.is_mouse_button_pressed(
		MOUSE_BUTTON_RIGHT
	)

	if not mining and not building:
		return

	terrain_ray.force_raycast_update()

	if not terrain_ray.is_colliding():
		return

	var hit_position: Vector3 = \
		terrain_ray.get_collision_point()

	var hit_normal: Vector3 = \
		terrain_ray.get_collision_normal()

	var brush_position: Vector3

	if mining:
		brush_position = hit_position - hit_normal * 0.35
		terrain.sculpt(brush_position, false)

	elif building:
		brush_position = hit_position + hit_normal * 0.35
		terrain.sculpt(brush_position, true)

	sculpt_timer = sculpt_interval


func change_brush_size(amount: float) -> void:
	var current_radius: float = terrain.brush_radius

	var new_radius: float = clampf(
		current_radius + amount,
		1.0,
		5.0
	)

	terrain.brush_radius = new_radius
	print("Terrain brush radius: ", new_radius)
