extends Camera3D

@export var move_speed: float = 15.0
@export var fast_move_speed: float = 40.0
@export var mouse_sensitivity: float = 0.003
@export var scroll_speed: float = 5.0

var _yaw: float = 0.0
var _pitch: float = 0.0
var _captured: bool = false


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_captured = true
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_captured = false
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if _captured:
				move_speed = clampf(move_speed * 1.2, 1.0, 200.0)
				fast_move_speed = move_speed * 2.5
			else:
				position += -transform.basis.z * scroll_speed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if _captured:
				move_speed = clampf(move_speed / 1.2, 1.0, 200.0)
				fast_move_speed = move_speed * 2.5
			else:
				position += transform.basis.z * scroll_speed

	if event is InputEventMouseMotion and _captured:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * mouse_sensitivity
		_pitch -= mm.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	var speed := fast_move_speed if Input.is_key_pressed(KEY_SHIFT) else move_speed
	var direction := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		direction -= transform.basis.z
	if Input.is_key_pressed(KEY_S):
		direction += transform.basis.z
	if Input.is_key_pressed(KEY_A):
		direction -= transform.basis.x
	if Input.is_key_pressed(KEY_D):
		direction += transform.basis.x
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE):
		direction += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		direction += Vector3.DOWN

	if direction.length_squared() > 0.001:
		position += direction.normalized() * speed * delta
