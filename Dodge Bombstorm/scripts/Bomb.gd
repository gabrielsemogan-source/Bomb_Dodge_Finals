extends Area2D

var countdown := randf_range(1.0, 3.0)
const EXPLOSION_RADIUS := 132.0
var explosion_radius := EXPLOSION_RADIUS
var exploded := false
var networked := false
var network_id := 0

@onready var label: Label = $Label

func _ready():
	set_process(false)
	label.text = str(int(ceil(countdown)))
	label.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0, 1.0))
	label.add_theme_color_override("font_outline_color", Color(0.025, 0.035, 0.055, 1.0))
	label.add_theme_constant_override("outline_size", 3)
	label.add_theme_font_size_override("font_size", 18)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func _process(delta):
	if exploded:
		return
	if networked and not NetworkManager.is_host():
		return
	countdown -= delta
	label.text = str(max(0, ceil(countdown)))
	queue_redraw()
	if countdown <= 0:
		explode()

func start_fuse() -> void:
	if not networked or NetworkManager.is_host():
		set_process(true)

func apply_network_state(new_countdown: float, is_exploded: bool) -> void:
	countdown = new_countdown
	label.text = str(max(0, ceil(countdown)))
	if is_exploded and not exploded:
		exploded = true
		set_process(false)
		label.visible = false
		monitoring = false
	queue_redraw()

func _draw():
	if exploded:
		draw_circle(Vector2.ZERO, explosion_radius, Color(0.92, 0.2, 0.08, 0.13))
		draw_arc(Vector2.ZERO, explosion_radius, 0.0, TAU, 48, Color(0.82, 0.19, 0.08, 0.72), 3.0)
		draw_circle(Vector2.ZERO, explosion_radius * 0.7, Color(1.0, 0.48, 0.12, 0.22))
		draw_arc(Vector2.ZERO, explosion_radius * 0.7, 0.0, TAU, 40, Color(1.0, 0.57, 0.14, 0.75), 2.0)
		return
	
	draw_circle(Vector2.ZERO, 24.0, Color(0.035, 0.045, 0.065, 1.0))
	draw_circle(Vector2.ZERO, 19.0, Color(0.01, 0.015, 0.025, 1.0))
	if countdown <= 1.0:
		var pulse := 0.5 + 0.5 * sin((1.0 - countdown) * TAU * 3.0)
		draw_circle(Vector2.ZERO, 7.0 + pulse * 3.0, Color(1.0, 0.24, 0.06, 0.75 + pulse * 0.25))
		draw_arc(Vector2.ZERO, 27.0, 0.0, TAU, 24, Color(1.0, 0.2, 0.04, 0.55 + pulse * 0.45), 2.0 + pulse * 2.0)
	else:
		draw_arc(Vector2.ZERO, 27.0, 0.0, TAU, 24, Color(0.32, 0.38, 0.48, 0.9), 2.0)

func explode():
	exploded = true
	set_process(false)
	label.visible = false
	monitoring = false
	
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		if player.alive and player.global_position.distance_to(global_position) <= explosion_radius:
			player.die()
	
	queue_redraw()
	await get_tree().create_timer(0.15).timeout
	queue_free()
