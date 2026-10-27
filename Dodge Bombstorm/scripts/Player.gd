extends CharacterBody2D

signal player_eliminated(player: Node)

const SPEED := 450.0
const DASH_SPEED := 1150.0
const DASH_TIME := 0.22
const DASH_COOLDOWN := 5.0

var alive := true
var player_name := "Player"
var player_id := 1
var player_color := Color(0, 0.8, 1, 1)
var dash_timer := 0.0
var dash_cooldown := 0.0
var last_move_direction := Vector2.RIGHT
var dash_direction := Vector2.RIGHT
var dash_key_was_pressed := false
var networked := false
var network_owner_id := 1
var remote_move_direction := Vector2.ZERO
var network_input_timer := 0.0
var dash_bar_fill: StyleBoxFlat
var player_hud_base_position := Vector2.ZERO
var dash_bar_base_position := Vector2.ZERO

@onready var player_hud: Label = $PlayerHUD
@onready var dash_cooldown_bar: ProgressBar = $DashCooldown

func _ready() -> void:
	add_to_group("players")
	_update_player_colors()
	player_hud.custom_minimum_size = Vector2(280.0, player_hud.custom_minimum_size.y)
	player_hud.size = Vector2(280.0, player_hud.size.y)
	player_hud.add_theme_font_size_override("font_size", 15)
	player_hud.add_theme_color_override("font_outline_color", Color(0.025, 0.045, 0.08, 1.0))
	player_hud.add_theme_constant_override("outline_size", 5)
	dash_cooldown_bar.max_value = DASH_COOLDOWN
	dash_cooldown_bar.value = DASH_COOLDOWN
	var bar_background := StyleBoxFlat.new()
	bar_background.bg_color = Color(0.025, 0.045, 0.08, 1.0)
	bar_background.set_corner_radius_all(3)
	dash_cooldown_bar.add_theme_stylebox_override("background", bar_background)
	dash_bar_fill = StyleBoxFlat.new()
	dash_bar_fill.bg_color = Color(0.18, 0.72, 0.9, 1.0)
	dash_bar_fill.set_corner_radius_all(3)
	dash_cooldown_bar.add_theme_stylebox_override("fill", dash_bar_fill)
	player_hud.z_index = 10
	dash_cooldown_bar.z_index = 10
	var camera := get_viewport().get_camera_2d()
	var counter_scale := Vector2.ONE
	if camera != null:
		counter_scale = Vector2(1.0 / camera.zoom.x, 1.0 / camera.zoom.y)
	player_hud.scale = counter_scale
	dash_cooldown_bar.scale = counter_scale
	player_hud_base_position = Vector2(
		-player_hud.size.x * counter_scale.x * 0.5,
		-74.0 * counter_scale.y
	)
	dash_bar_base_position = Vector2(
		-dash_cooldown_bar.size.x * counter_scale.x * 0.5,
		-25.0 * counter_scale.y
	)
	player_hud.position = player_hud_base_position
	dash_cooldown_bar.position = dash_bar_base_position

func _process(_delta: float) -> void:
	if not is_inside_tree() or not is_instance_valid(player_hud):
		return
	var dash_state := "DASHING" if dash_timer > 0.0 else (
		"READY" if dash_cooldown <= 0.0 else "COOLDOWN %.1fs" % dash_cooldown
	)
	player_hud.text = "%s\n%s" % [player_name, dash_state]
	dash_cooldown_bar.value = DASH_COOLDOWN - dash_cooldown
	if dash_timer > 0.0:
		dash_bar_fill.bg_color = Color(0.2, 0.88, 1.0, 1.0)
	elif dash_cooldown <= 0.0:
		dash_bar_fill.bg_color = Color(0.3, 0.84, 0.58, 1.0)
	else:
		dash_bar_fill.bg_color = Color(0.18, 0.72, 0.9, 1.0)
	_position_indicators()

func _position_indicators() -> void:
	var viewport := get_viewport()
	var camera := viewport.get_camera_2d()
	if camera == null:
		return
	var zoom := camera.zoom
	var view_size := get_viewport_rect().size
	var player_screen_position := viewport.get_canvas_transform() * global_position
	var label_size := player_hud.size
	var label_center_x := player_screen_position.x
	var label_top := player_screen_position.y + player_hud_base_position.y * zoom.y

	for other in get_tree().get_nodes_in_group("players"):
		if other == self or not other.alive or not is_instance_valid(other.player_hud):
			continue
		var other_screen_position: Vector2 = viewport.get_canvas_transform() * other.global_position
		var other_label_width: float = other.player_hud.size.x * other.player_hud.scale.x * zoom.x
		var other_label_height: float = other.player_hud.size.y * other.player_hud.scale.y * zoom.y
		var other_label_center_x: float = (
			other_screen_position.x
			+ (other.player_hud.position.x + other.player_hud.size.x * other.player_hud.scale.x * 0.5) * zoom.x
		)
		var other_label_top: float = other_screen_position.y + other.player_hud.position.y * zoom.y
		if (
			absf(label_center_x - other_label_center_x) < (label_size.x + other_label_width) * 0.5
			and absf(label_top - other_label_top) < (label_size.y + other_label_height) * 0.5
		):
			label_top += label_size.y + 4.0 if player_id > other.player_id else -(label_size.y + 4.0)

	var half_label_width := label_size.x * 0.5
	label_center_x = clampf(label_center_x, half_label_width + 8.0, view_size.x - half_label_width - 8.0)
	label_top = clampf(label_top, 8.0, view_size.y - label_size.y - 8.0)
	var label_position := player_hud_base_position + Vector2(
		(label_center_x - player_screen_position.x) / zoom.x,
		(label_top - (player_screen_position.y + player_hud_base_position.y * zoom.y)) / zoom.y
	)
	player_hud.position = label_position

	var bar_size := dash_cooldown_bar.size
	var bar_center_x := clampf(player_screen_position.x, bar_size.x * 0.5 + 8.0, view_size.x - bar_size.x * 0.5 - 8.0)
	var bar_top := player_screen_position.y + dash_bar_base_position.y * zoom.y
	if bar_top + bar_size.y > label_top and bar_top < label_top + label_size.y:
		bar_top = label_top + label_size.y + 4.0
		if bar_top + bar_size.y > view_size.y - 8.0:
			bar_top = label_top - bar_size.y - 4.0
	bar_top = clampf(bar_top, 8.0, view_size.y - bar_size.y - 8.0)
	dash_cooldown_bar.position = dash_bar_base_position + Vector2(
		(bar_center_x - player_screen_position.x) / zoom.x,
		(bar_top - (player_screen_position.y + dash_bar_base_position.y * zoom.y)) / zoom.y
	)

func _physics_process(delta: float) -> void:
	if not alive:
		return
	var game: Object = get_tree().get_first_node_in_group("game")
	if game != null and not game.get("round_active"):
		return

	var move := Vector2.ZERO
	var dash_key_pressed := false
	if networked:
		if not NetworkManager.is_host():
			if network_owner_id != multiplayer.get_unique_id():
				return
			move = _read_movement_input(true)
			dash_key_pressed = Input.is_key_pressed(KEY_SHIFT)
			if dash_key_pressed and not dash_key_was_pressed:
				NetworkManager.request_player_dash()
			dash_key_was_pressed = dash_key_pressed
			network_input_timer -= delta
			if network_input_timer <= 0.0:
				NetworkManager.submit_player_input(move)
				network_input_timer = 0.05
			return
		elif network_owner_id != 1:
			move = remote_move_direction
		else:
			move = _read_movement_input(true)
			dash_key_pressed = Input.is_key_pressed(KEY_SHIFT)
	else:
		move = _read_movement_input(false)
		dash_key_pressed = Input.is_key_pressed(KEY_SHIFT) if player_id == 1 else Input.is_key_pressed(KEY_SPACE)
	
	dash_cooldown = maxf(0.0, dash_cooldown - delta)
	
	if move.length_squared() > 0.0:
		move = move.normalized()
		last_move_direction = move
	
	if dash_key_pressed and not dash_key_was_pressed and dash_cooldown <= 0.0:
		_start_dash(move)
	dash_key_was_pressed = dash_key_pressed
	
	if dash_timer > 0.0:
		velocity = dash_direction * DASH_SPEED * minf(1.0, dash_timer / delta)
	else:
		velocity = move * SPEED
	move_and_slide()
	dash_timer = maxf(0.0, dash_timer - delta)

func _read_movement_input(online_controls: bool) -> Vector2:
	var move := Vector2.ZERO
	if online_controls or player_id == 1:
		if Input.is_key_pressed(KEY_W):
			move.y -= 1.0
		if Input.is_key_pressed(KEY_S):
			move.y += 1.0
		if Input.is_key_pressed(KEY_A):
			move.x -= 1.0
		if Input.is_key_pressed(KEY_D):
			move.x += 1.0
	else:
		if Input.is_key_pressed(KEY_UP):
			move.y -= 1.0
		if Input.is_key_pressed(KEY_DOWN):
			move.y += 1.0
		if Input.is_key_pressed(KEY_LEFT):
			move.x -= 1.0
		if Input.is_key_pressed(KEY_RIGHT):
			move.x += 1.0
	return move.normalized() if move.length_squared() > 0.0 else move

func _start_dash(direction: Vector2) -> void:
	if dash_cooldown > 0.0:
		return
	dash_direction = direction if direction.length_squared() > 0.0 else last_move_direction
	dash_timer = DASH_TIME
	dash_cooldown = DASH_COOLDOWN

func configure_networked(owner_id: int) -> void:
	networked = true
	network_owner_id = owner_id

func set_remote_move_direction(direction: Vector2) -> void:
	remote_move_direction = direction.normalized() if direction.length_squared() > 0.0 else Vector2.ZERO

func request_authoritative_dash() -> void:
	if networked and NetworkManager.is_host() and network_owner_id != 1 and alive:
		_start_dash(remote_move_direction)

func set_player_name(name_text: String):
	player_name = name_text

func get_player_name() -> String:
	return player_name

func set_player_id(id: int):
	player_id = id

func set_player_color(color: Color):
	player_color = color
	_update_player_colors()

func _update_player_colors() -> void:
	if has_node("ColorRect"):
		$ColorRect.color = player_color
	if has_node("Outline"):
		$Outline.color = player_color.lightened(0.35)
	if is_instance_valid(player_hud):
		player_hud.add_theme_color_override("font_color", player_color.lightened(0.22))

func die():
	if not alive:
		return
	alive = false
	player_eliminated.emit(self)
	visible = false
	set_physics_process(false)
