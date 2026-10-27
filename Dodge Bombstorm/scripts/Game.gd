extends Node2D

const PLAYER_SCENE = preload("res://scenes/Player.tscn")
const BOMB_SCENE = preload("res://scenes/Bomb.tscn")

const ARENA_WIDTH = 2400
const ARENA_HEIGHT = 1350
const ARENA_CAMERA_ZOOM = 0.52
const INITIAL_BOMB_COUNT = 25
const BOMBS_PER_WAVE = 15
const BOMB_SPAWN_INTERVAL = 1.0
const PRE_GAME_COUNTDOWN = 5.0
const BOMB_PLAYER_SAFE_DISTANCE = 64.0
const BOMB_EDGE_MARGIN = 60.0
const SPAWN_COLUMNS = 4
const SPAWN_ROWS = 3

const COLOR_OPTIONS = [
	{"name": "Red", "color": Color(1.0, 0.32, 0.32)},
	{"name": "Orange", "color": Color(1.0, 0.62, 0.2)},
	{"name": "Yellow", "color": Color(1.0, 0.88, 0.25)},
	{"name": "Green", "color": Color(0.28, 0.88, 0.42)},
	{"name": "Blue", "color": Color(0.26, 0.62, 1.0)},
	{"name": "Indigo", "color": Color(0.38, 0.42, 0.93)},
	{"name": "Violet", "color": Color(0.76, 0.52, 1.0)},
]

enum GameMode {
	SOLO,
	LOCAL_MULTIPLAYER,
	ONLINE_MULTIPLAYER,
}

var world_root: Node2D
var ui_root: CanvasLayer
var network_status_label: Label
var network_status := ""
var game_mode := GameMode.SOLO
var match_started := false
var round_active := false
var match_ended := false
var pregame_remaining := 0.0
var elapsed_time := 0.0
var online_snapshot_timer := 0.0
var next_bomb_id := 1
var players: Array = []
var bombs: Array = []
var network_bombs: Dictionary = {}
var elimination_records: Array[Dictionary] = []
var final_leaderboard: Array[Dictionary] = []
var spawn_region_order: Array[Vector2i] = []
var bomb_timer: Timer
var timer_label: Label
var remaining_label: Label
var info_label: Label
var results_label: Label
var results_panel: PanelContainer
var leaderboard_box: VBoxContainer
var solo_color_index := 0
var p1_color_index := 0
var p2_color_index := 1

func _ready():
	randomize()
	add_to_group("game")
	NetworkManager.room_updated.connect(_on_room_updated)
	NetworkManager.connection_status_changed.connect(_on_connection_status_changed)
	NetworkManager.online_match_started.connect(_on_online_match_started)
	NetworkManager.match_state_received.connect(_apply_online_match_state)
	world_root = Node2D.new()
	world_root.name = "World"
	add_child(world_root)
	
	ui_root = CanvasLayer.new()
	ui_root.name = "UI"
	add_child(ui_root)
	
	show_main_menu()

func _process(_delta):
	if game_mode == GameMode.ONLINE_MULTIPLAYER:
		if NetworkManager.is_host():
			if match_started and not round_active:
				_advance_pregame(_delta)
			if round_active and not match_ended:
				elapsed_time += _delta
				update_timer_label()
				check_for_game_over()
			if NetworkManager.match_started:
				online_snapshot_timer -= _delta
				if online_snapshot_timer <= 0.0:
					NetworkManager.broadcast_match_state(_make_online_match_state())
					online_snapshot_timer = 0.05
	else:
		if match_started and not round_active:
			_advance_pregame(_delta)
		if round_active and not match_ended:
			elapsed_time += _delta
			update_timer_label()
			check_for_game_over()

	if game_mode == GameMode.ONLINE_MULTIPLAYER and Input.is_key_pressed(KEY_M):
		show_main_menu()
	elif not round_active and match_started and game_mode != GameMode.ONLINE_MULTIPLAYER:
		if Input.is_key_pressed(KEY_M):
			show_main_menu()
		elif pregame_remaining <= 0.0 and Input.is_key_pressed(KEY_R):
			start_match()
	
	if Input.is_key_pressed(KEY_ESCAPE):
		get_tree().quit()

func _on_room_updated() -> void:
	if NetworkManager.room_active and not NetworkManager.match_started:
		show_network_lobby()
	elif game_mode == GameMode.ONLINE_MULTIPLAYER and NetworkManager.is_host():
		for player in players:
			if not NetworkManager.room_members.has(player.network_owner_id) and player.alive:
				player.die()

func _on_connection_status_changed(message: String) -> void:
	network_status = message
	if is_instance_valid(network_status_label):
		network_status_label.text = network_status
	if game_mode == GameMode.ONLINE_MULTIPLAYER and is_instance_valid(info_label):
		if message == "The host disconnected." or message.begins_with("Connection failed."):
			info_label.text = "%s | Press M to return to menu" % message

func _on_online_match_started() -> void:
	game_mode = GameMode.ONLINE_MULTIPLAYER
	start_match()

func clear_world():
	for child in world_root.get_children():
		child.queue_free()
	players.clear()
	bombs.clear()
	network_bombs.clear()
	spawn_region_order.clear()

func clear_ui():
	for child in ui_root.get_children():
		child.queue_free()
	network_status_label = null
	timer_label = null
	remaining_label = null
	info_label = null
	results_label = null
	results_panel = null
	leaderboard_box = null

func make_menu_button(text_value: String, size: Vector2 = Vector2(260, 56), text_size: int = 22) -> Button:
	var btn = Button.new()
	btn.text = text_value
	btn.custom_minimum_size = size
	btn.add_theme_font_size_override("font_size", text_size)
	btn.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", Color(0.58, 0.64, 0.74))
	
	var normal = StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.2, 0.34, 1.0)
	normal.border_width_left = 1
	normal.border_width_top = 1
	normal.border_width_right = 1
	normal.border_width_bottom = 1
	normal.border_color = Color(0.43, 0.62, 0.86, 1.0)
	normal.corner_radius_top_left = 10
	normal.corner_radius_top_right = 10
	normal.corner_radius_bottom_left = 10
	normal.corner_radius_bottom_right = 10
	normal.content_margin_left = 14
	normal.content_margin_right = 14
	btn.add_theme_stylebox_override("normal", normal)
	
	var hover = normal.duplicate()
	hover.bg_color = Color(0.2, 0.36, 0.58, 1.0)
	hover.border_color = Color(0.68, 0.82, 1.0, 1.0)
	btn.add_theme_stylebox_override("hover", hover)
	
	var pressed = normal.duplicate()
	pressed.bg_color = Color(0.08, 0.14, 0.26, 1.0)
	btn.add_theme_stylebox_override("pressed", pressed)

	var focus = normal.duplicate()
	focus.border_color = Color(0.82, 0.9, 1.0, 1.0)
	focus.border_width_left = 2
	focus.border_width_top = 2
	focus.border_width_right = 2
	focus.border_width_bottom = 2
	btn.add_theme_stylebox_override("focus", focus)

	var disabled = normal.duplicate()
	disabled.bg_color = Color(0.16, 0.2, 0.28, 1.0)
	disabled.border_color = Color(0.32, 0.39, 0.5, 1.0)
	btn.add_theme_stylebox_override("disabled", disabled)
	
	return btn

func make_color_button(color_index: int, size: Vector2, text_size: int) -> Button:
	var color_data: Dictionary = COLOR_OPTIONS[color_index]
	var swatch_color: Color = color_data["color"]
	var button := Button.new()
	button.text = color_data["name"]
	button.custom_minimum_size = size
	button.add_theme_font_size_override("font_size", text_size)
	button.add_theme_color_override("font_color", Color(0.06, 0.09, 0.15))
	button.add_theme_color_override("font_hover_color", Color(0.03, 0.06, 0.1))
	button.add_theme_color_override("font_pressed_color", Color(0.03, 0.06, 0.1))
	button.add_theme_color_override("font_disabled_color", Color(0.06, 0.09, 0.15))

	var normal := StyleBoxFlat.new()
	normal.bg_color = swatch_color
	normal.border_color = Color(0.94, 0.96, 1.0, 1.0)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(8)
	button.add_theme_stylebox_override("normal", normal)

	var hover := normal.duplicate()
	hover.bg_color = swatch_color.lightened(0.12)
	hover.set_border_width_all(3)
	button.add_theme_stylebox_override("hover", hover)

	var pressed := normal.duplicate()
	pressed.bg_color = swatch_color.darkened(0.12)
	button.add_theme_stylebox_override("pressed", pressed)

	var disabled := normal.duplicate()
	disabled.border_color = Color(0.05, 0.08, 0.14, 1.0)
	disabled.set_border_width_all(4)
	button.add_theme_stylebox_override("disabled", disabled)
	return button

func _style_menu_panel(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", _make_menu_panel_style())
	var theme := Theme.new()
	theme.set_color("font_color", "Label", Color(0.94, 0.96, 1.0))
	theme.set_color("font_color", "LineEdit", Color.WHITE)
	theme.set_color("font_placeholder_color", "LineEdit", Color(0.36, 0.42, 0.52))
	theme.set_constant("separation", "VBoxContainer", 12)
	theme.set_constant("separation", "HBoxContainer", 10)
	panel.theme = theme

func _center_panel(panel: Control, size: Vector2) -> void:
	var viewport_size := get_viewport_rect().size
	var panel_size := Vector2(
		minf(size.x, viewport_size.x - 32.0),
		minf(size.y, viewport_size.y - 32.0)
	)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -panel_size.x * 0.5
	panel.offset_top = -panel_size.y * 0.5
	panel.offset_right = panel_size.x * 0.5
	panel.offset_bottom = panel_size.y * 0.5

func show_main_menu():
	if NetworkManager.room_active:
		NetworkManager.leave_room()
	match_started = false
	round_active = false
	clear_ui()
	clear_world()
	game_mode = GameMode.SOLO
	
	var menu_panel = PanelContainer.new()
	_center_panel(menu_panel, Vector2(900, 500))
	_style_menu_panel(menu_panel)
	ui_root.add_child(menu_panel)
	
	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	menu_panel.add_child(vbox)
	
	var title = Label.new()
	title.text = "BOMB DODGE"
	title.add_theme_font_size_override("font_size", 54)
	title.modulate = Color(1, 1, 1, 1)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	
	var subtitle = Label.new()
	subtitle.text = "Choose a mode"
	subtitle.add_theme_font_size_override("font_size", 24)
	subtitle.modulate = Color(0.8, 0.85, 1.0, 1.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)
	
	var buttons = VBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.custom_minimum_size = Vector2(280, 0)
	vbox.add_child(buttons)
	
	var solo_button = make_menu_button("Solo", Vector2(260, 58), 24)
	solo_button.pressed.connect(func(): show_color_selection(GameMode.SOLO))
	buttons.add_child(solo_button)
	
	var mp_button = make_menu_button("Local Multiplayer", Vector2(260, 58), 24)
	mp_button.pressed.connect(func(): show_color_selection(GameMode.LOCAL_MULTIPLAYER))
	buttons.add_child(mp_button)

	var online_button = make_menu_button("Online Multiplayer", Vector2(260, 58), 24)
	online_button.pressed.connect(show_online_menu)
	buttons.add_child(online_button)
	
	var quit_button = make_menu_button("Quit", Vector2(260, 58), 24)
	quit_button.pressed.connect(func(): get_tree().quit())
	buttons.add_child(quit_button)

func show_online_menu() -> void:
	clear_ui()
	var panel = PanelContainer.new()
	_center_panel(panel, Vector2(900, 500))
	_style_menu_panel(panel)
	ui_root.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "Online Multiplayer"
	title.add_theme_font_size_override("font_size", 38)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var details = Label.new()
	details.text = "Direct connection | Host on UDP port %d" % NetworkManager.PORT
	details.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	details.add_theme_font_size_override("font_size", 18)
	vbox.add_child(details)

	network_status_label = Label.new()
	network_status_label.text = network_status
	network_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(network_status_label)

	var host_button = make_menu_button("Host Game", Vector2(280, 58), 22)
	host_button.pressed.connect(func():
		NetworkManager.host_game()
	)
	vbox.add_child(host_button)

	var join_button = make_menu_button("Join Game", Vector2(280, 58), 22)
	join_button.pressed.connect(show_online_join)
	vbox.add_child(join_button)

	var back_button = make_menu_button("Back to Menu", Vector2(280, 52), 20)
	back_button.pressed.connect(show_main_menu)
	vbox.add_child(back_button)

func show_online_join() -> void:
	clear_ui()
	var panel = PanelContainer.new()
	_center_panel(panel, Vector2(900, 500))
	_style_menu_panel(panel)
	ui_root.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "Join a Private Room"
	title.add_theme_font_size_override("font_size", 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var address_input = LineEdit.new()
	address_input.placeholder_text = "Host IP address"
	address_input.custom_minimum_size = Vector2(440, 48)
	vbox.add_child(address_input)

	var code_input = LineEdit.new()
	code_input.placeholder_text = "6-character room code"
	code_input.max_length = 6
	code_input.custom_minimum_size = Vector2(440, 48)
	vbox.add_child(code_input)

	var hint = Label.new()
	hint.text = "You need both the host's reachable address and private room code."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)

	network_status_label = Label.new()
	network_status_label.text = network_status
	network_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(network_status_label)

	var join_button = make_menu_button("Connect", Vector2(260, 52), 22)
	join_button.pressed.connect(func():
		if NetworkManager.join_game(address_input.text, code_input.text):
			show_network_lobby()
	)
	vbox.add_child(join_button)

	var back_button = make_menu_button("Back", Vector2(260, 48), 20)
	back_button.pressed.connect(show_online_menu)
	vbox.add_child(back_button)

func show_network_lobby() -> void:
	clear_ui()
	var panel = PanelContainer.new()
	_center_panel(panel, Vector2(960, 550))
	_style_menu_panel(panel)
	ui_root.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "Private Room Lobby"
	title.add_theme_font_size_override("font_size", 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var code_label = Label.new()
	code_label.text = "Room code: %s" % NetworkManager.room_code
	code_label.add_theme_font_size_override("font_size", 26)
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(code_label)

	var network_hint = Label.new()
	if NetworkManager.is_host():
		network_hint.text = "LAN address: %s:%d | For Internet play, share your public IP and forward UDP %d." % [
			_get_lan_address(),
			NetworkManager.PORT,
			NetworkManager.PORT,
		]
	else:
		network_hint.text = "Use the host's reachable address. Internet play needs UDP %d forwarded." % NetworkManager.PORT
	network_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	network_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(network_hint)

	var color_title = Label.new()
	color_title.text = "Choose your color"
	color_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(color_title)

	var color_row = HBoxContainer.new()
	color_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(color_row)
	var local_id := multiplayer.get_unique_id()
	var local_color := 0
	if NetworkManager.room_members.has(local_id):
		local_color = NetworkManager.room_members[local_id]["color_index"]
	var local_preview := _make_character_preview(COLOR_OPTIONS[local_color]["color"])
	color_row.add_child(local_preview)
	var color_box := PanelContainer.new()
	_style_menu_panel(color_box)
	color_row.add_child(color_box)
	var color_buttons := HBoxContainer.new()
	color_buttons.add_theme_constant_override("separation", 5)
	color_box.add_child(color_buttons)
	for i in range(COLOR_OPTIONS.size()):
		var color_button = make_color_button(i, Vector2(105, 40), 15)
		color_button.disabled = i == local_color
		var color_index := i
		color_button.pressed.connect(func():
			_update_character_preview(local_preview, COLOR_OPTIONS[color_index]["color"])
			NetworkManager.set_local_color(color_index)
		)
		color_buttons.add_child(color_button)

	var slots_label = Label.new()
	slots_label.text = "Players: %d / %d" % [NetworkManager.room_members.size(), NetworkManager.MAX_PLAYERS]
	slots_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slots_label.add_theme_font_size_override("font_size", 20)
	vbox.add_child(slots_label)
	var member_index := 1
	for member_id in NetworkManager.room_members:
		var member = NetworkManager.room_members[member_id]
		var color_data = COLOR_OPTIONS[member["color_index"]]
		var member_row := HBoxContainer.new()
		member_row.alignment = BoxContainer.ALIGNMENT_CENTER
		member_row.add_theme_constant_override("separation", 10)
		vbox.add_child(member_row)
		var member_preview := _make_character_preview(color_data["color"], Vector2(36, 46))
		member_row.add_child(member_preview)
		var member_label = Label.new()
		var member_name: String = member["name"]
		if not member_name.begins_with("Player "):
			member_name = "Player %d (%s)" % [member_index, member_name]
		member_label.text = "%s - %s" % [member_name, color_data["name"]]
		member_label.add_theme_color_override("font_color", color_data["color"].lightened(0.25))
		member_row.add_child(member_label)
		member_index += 1

	network_status_label = Label.new()
	network_status_label.text = network_status
	network_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(network_status_label)

	var buttons = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(buttons)
	if NetworkManager.is_host():
		var start_button = make_menu_button("Start Match", Vector2(230, 52), 20)
		start_button.disabled = NetworkManager.room_members.size() < 2
		start_button.pressed.connect(func(): NetworkManager.start_online_match())
		buttons.add_child(start_button)
	var leave_button = make_menu_button("Leave Room", Vector2(230, 52), 20)
	leave_button.pressed.connect(func():
		NetworkManager.leave_room()
		show_online_menu()
	)
	buttons.add_child(leave_button)

func _make_menu_panel_style() -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.065, 0.12, 0.97)
	style.set_border_width_all(2)
	style.border_color = Color(0.22, 0.48, 0.68, 1.0)
	style.content_margin_left = 32
	style.content_margin_right = 32
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	return style

func _get_lan_address() -> String:
	for address in IP.get_local_addresses():
		if ":" not in address and address != "127.0.0.1":
			return address
	return "unavailable"

func show_color_selection(mode: int):
	game_mode = mode
	clear_ui()
	
	var panel := PanelContainer.new()
	_center_panel(panel, Vector2(940, 560))
	_style_menu_panel(panel)
	ui_root.add_child(panel)
	
	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(vbox)
	
	var title = Label.new()
	title.text = "Choose your colors"
	title.add_theme_font_size_override("font_size", 36)
	title.modulate = Color(1, 1, 1, 1)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	if game_mode == GameMode.SOLO:
		var row = HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		vbox.add_child(row)
		var preview := _make_character_preview(COLOR_OPTIONS[solo_color_index]["color"])
		row.add_child(preview)
		var selection_box := PanelContainer.new()
		_style_menu_panel(selection_box)
		row.add_child(selection_box)
		var selection_vbox := VBoxContainer.new()
		selection_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		selection_box.add_child(selection_vbox)
		var selection_title := Label.new()
		selection_title.text = "Player 1"
		selection_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		selection_title.add_theme_font_size_override("font_size", 22)
		selection_vbox.add_child(selection_title)
		var color_row := HBoxContainer.new()
		color_row.alignment = BoxContainer.ALIGNMENT_CENTER
		selection_vbox.add_child(color_row)
		for i in range(COLOR_OPTIONS.size()):
			var btn = make_color_button(i, Vector2(100, 40), 16)
			var pick_index = i
			btn.pressed.connect(func():
				solo_color_index = pick_index
				_update_character_preview(preview, COLOR_OPTIONS[pick_index]["color"])
			)
			color_row.add_child(btn)
		
		var start_button = make_menu_button("Start Match", Vector2(220, 56), 22)
		start_button.pressed.connect(func(): start_match())
		vbox.add_child(start_button)
	else:
		var p1_row := _make_local_color_selection(vbox, 1, p1_color_index)
		for i in range(COLOR_OPTIONS.size()):
			var btn = make_color_button(i, Vector2(50, 36), 12)
			var pick_index = i
			btn.pressed.connect(func():
				p1_color_index = pick_index
				_update_character_preview(p1_row.get_meta("preview"), COLOR_OPTIONS[p1_color_index]["color"])
				if p1_color_index == p2_color_index:
					var alt = get_next_available_color_index([p1_color_index])
					if alt != -1:
						p2_color_index = alt
						var p2_preview: Control = p1_row.get_meta("other_preview")
						_update_character_preview(p2_preview, COLOR_OPTIONS[p2_color_index]["color"])
			)
			p1_row.get_meta("colors").add_child(btn)
		
		var p2_row := _make_local_color_selection(vbox, 2, p2_color_index)
		p1_row.set_meta("other_preview", p2_row.get_meta("preview"))
		for i in range(COLOR_OPTIONS.size()):
			var btn = make_color_button(i, Vector2(50, 36), 12)
			var pick_index = i
			btn.pressed.connect(func():
				if pick_index == p1_color_index:
					var alt = get_next_available_color_index([p1_color_index])
					if alt == -1:
						return
					p2_color_index = alt
				else:
					p2_color_index = pick_index
				_update_character_preview(p2_row.get_meta("preview"), COLOR_OPTIONS[p2_color_index]["color"])
			)
			p2_row.get_meta("colors").add_child(btn)
		
		var start_button = make_menu_button("Start Match", Vector2(220, 56), 22)
		start_button.pressed.connect(func(): start_match())
		vbox.add_child(start_button)
	
	var back_button = make_menu_button("Back to Menu", Vector2(220, 56), 22)
	back_button.pressed.connect(func(): show_main_menu())
	vbox.add_child(back_button)

func _make_local_color_selection(parent: VBoxContainer, player_number: int, color_index: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	var preview := _make_character_preview(COLOR_OPTIONS[color_index]["color"])
	row.add_child(preview)
	var box := PanelContainer.new()
	_style_menu_panel(box)
	row.add_child(box)
	var selection := VBoxContainer.new()
	selection.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(selection)
	var title := Label.new()
	title.text = "Player %d" % player_number
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	selection.add_child(title)
	var colors := HBoxContainer.new()
	colors.alignment = BoxContainer.ALIGNMENT_CENTER
	colors.add_theme_constant_override("separation", 5)
	selection.add_child(colors)
	row.set_meta("preview", preview)
	row.set_meta("colors", colors)
	return row

func _make_character_preview(color: Color, preview_size := Vector2(72, 92)) -> Control:
	var preview := Control.new()
	preview.custom_minimum_size = preview_size
	var scale := preview_size / Vector2(72, 92)
	var outline := ColorRect.new()
	outline.position = Vector2(12, 38) * scale
	outline.size = Vector2(48, 48) * scale
	outline.color = Color(0.025, 0.045, 0.08, 1.0)
	preview.add_child(outline)
	var body := ColorRect.new()
	body.name = "Body"
	body.position = Vector2(16, 42) * scale
	body.size = Vector2(40, 40) * scale
	body.color = color
	preview.add_child(body)
	var head := ColorRect.new()
	head.name = "Head"
	head.position = Vector2(24, 10) * scale
	head.size = Vector2(24, 24) * scale
	head.color = color.lightened(0.22)
	preview.add_child(head)
	return preview

func _update_character_preview(preview: Control, color: Color) -> void:
	preview.get_node("Body").color = color
	preview.get_node("Head").color = color.lightened(0.22)

func get_next_available_color_index(excluded_indices: Array) -> int:
	for i in range(COLOR_OPTIONS.size()):
		if not excluded_indices.has(i):
			return i
	return -1

func create_arena():
	var bg = ColorRect.new()
	bg.position = Vector2.ZERO
	bg.size = Vector2(ARENA_WIDTH, ARENA_HEIGHT)
	bg.color = Color(0.025, 0.045, 0.085, 1.0)
	world_root.add_child(bg)

	var floor = ColorRect.new()
	floor.position = Vector2(15, 15)
	floor.size = Vector2(ARENA_WIDTH - 30, ARENA_HEIGHT - 30)
	floor.color = Color(0.22, 0.28, 0.37, 1.0)
	world_root.add_child(floor)
	
	var border_color = Color(0.16, 0.38, 0.58, 1.0)
	var border_thickness = 4
	var border_nodes = [
		[Vector2(0, 0), Vector2(ARENA_WIDTH, border_thickness)],
		[Vector2(0, ARENA_HEIGHT - border_thickness), Vector2(ARENA_WIDTH, border_thickness)],
		[Vector2(0, 0), Vector2(border_thickness, ARENA_HEIGHT)],
		[Vector2(ARENA_WIDTH - border_thickness, 0), Vector2(border_thickness, ARENA_HEIGHT)],
	]
	for data in border_nodes:
		var border = ColorRect.new()
		border.position = data[0]
		border.size = data[1]
		border.color = border_color
		world_root.add_child(border)

	var floor_border_color = Color(0.4, 0.52, 0.66, 0.58)
	var floor_border_nodes = [
		[Vector2(20, 20), Vector2(ARENA_WIDTH - 40, 2)],
		[Vector2(20, ARENA_HEIGHT - 22), Vector2(ARENA_WIDTH - 40, 2)],
		[Vector2(20, 20), Vector2(2, ARENA_HEIGHT - 40)],
		[Vector2(ARENA_WIDTH - 22, 20), Vector2(2, ARENA_HEIGHT - 40)],
	]
	for data in floor_border_nodes:
		var floor_border = ColorRect.new()
		floor_border.position = data[0]
		floor_border.size = data[1]
		floor_border.color = floor_border_color
		world_root.add_child(floor_border)

	var decoration_color = Color(0.48, 0.63, 0.78, 0.18)
	for x in range(120, ARENA_WIDTH - 60, 120):
		for y in [48, ARENA_HEIGHT - 54]:
			var decoration = ColorRect.new()
			decoration.position = Vector2(x, y)
			decoration.size = Vector2(6, 6)
			decoration.color = decoration_color
			world_root.add_child(decoration)

	var wall_thickness = 30
	var walls = [
		[Vector2(0, ARENA_HEIGHT / 2), Vector2(wall_thickness, ARENA_HEIGHT)],
		[Vector2(ARENA_WIDTH - wall_thickness, ARENA_HEIGHT / 2), Vector2(wall_thickness, ARENA_HEIGHT)],
		[Vector2(ARENA_WIDTH / 2, 0), Vector2(ARENA_WIDTH, wall_thickness)],
		[Vector2(ARENA_WIDTH / 2, ARENA_HEIGHT - wall_thickness), Vector2(ARENA_WIDTH, wall_thickness)],
	]
	for wall_data in walls:
		var wall = StaticBody2D.new()
		var shape = CollisionShape2D.new()
		var rect = RectangleShape2D.new()
		rect.extents = wall_data[1] / 2
		shape.shape = rect
		wall.add_child(shape)
		wall.position = wall_data[0]
		world_root.add_child(wall)

	var camera := Camera2D.new()
	camera.position = Vector2(ARENA_WIDTH / 2.0, ARENA_HEIGHT / 2.0)
	camera.zoom = Vector2(ARENA_CAMERA_ZOOM, ARENA_CAMERA_ZOOM)
	world_root.add_child(camera)
	camera.make_current()

func create_match_ui():
	var viewport_size := get_viewport_rect().size

	var remaining_panel := PanelContainer.new()
	remaining_panel.position = Vector2(16, 16)
	remaining_panel.custom_minimum_size = Vector2(220, 48)
	remaining_panel.add_theme_stylebox_override("panel", _make_hud_panel_style())
	ui_root.add_child(remaining_panel)

	remaining_label = Label.new()
	remaining_label.text = "PLAYERS  0 / 0"
	remaining_label.add_theme_font_size_override("font_size", 19)
	remaining_label.add_theme_color_override("font_color", Color(0.94, 0.97, 1.0))
	remaining_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	remaining_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	remaining_panel.add_child(remaining_label)

	var timer_panel := PanelContainer.new()
	timer_panel.position = Vector2((viewport_size.x - 300) / 2, 16)
	timer_panel.custom_minimum_size = Vector2(300, 48)
	timer_panel.add_theme_stylebox_override("panel", _make_hud_panel_style())
	ui_root.add_child(timer_panel)

	timer_label = Label.new()
	timer_label.text = "Time: 0.0s"
	timer_label.add_theme_font_size_override("font_size", 28)
	timer_label.add_theme_color_override("font_color", Color(0.97, 0.98, 1.0))
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	timer_panel.add_child(timer_label)
	
	var info_panel := PanelContainer.new()
	info_panel.position = Vector2((viewport_size.x - 700) / 2, viewport_size.y - 66)
	info_panel.custom_minimum_size = Vector2(700, 46)
	info_panel.add_theme_stylebox_override("panel", _make_hud_panel_style())
	ui_root.add_child(info_panel)

	info_label = Label.new()
	info_label.text = ""
	info_label.add_theme_font_size_override("font_size", 16)
	info_label.add_theme_color_override("font_color", Color(0.88, 0.92, 1.0))
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_panel.add_child(info_label)
	
	results_panel = PanelContainer.new()
	_center_panel(results_panel, Vector2(760, 560))
	results_panel.add_theme_stylebox_override("panel", _make_hud_panel_style())
	ui_root.add_child(results_panel)

	var results_content := VBoxContainer.new()
	results_content.alignment = BoxContainer.ALIGNMENT_CENTER
	results_content.add_theme_constant_override("separation", 10)
	results_panel.add_child(results_content)
	results_label = Label.new()
	results_label.text = "MATCH RESULTS"
	results_label.add_theme_font_size_override("font_size", 30)
	results_label.add_theme_color_override("font_color", Color(0.97, 0.98, 1.0))
	results_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	results_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	results_label.visible = false
	results_content.add_child(results_label)
	leaderboard_box = VBoxContainer.new()
	leaderboard_box.add_theme_constant_override("separation", 6)
	results_content.add_child(leaderboard_box)
	var results_buttons := HBoxContainer.new()
	results_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	results_buttons.add_theme_constant_override("separation", 12)
	results_content.add_child(results_buttons)
	var menu_button := make_menu_button("Main Menu", Vector2(210, 48), 19)
	menu_button.pressed.connect(func(): show_main_menu())
	results_buttons.add_child(menu_button)
	if game_mode != GameMode.ONLINE_MULTIPLAYER:
		var retry_button := make_menu_button("Play Again", Vector2(210, 48), 19)
		retry_button.pressed.connect(func(): start_match())
		results_buttons.add_child(retry_button)
	results_panel.visible = false
	update_timer_label()

func _make_hud_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.085, 0.16, 0.96)
	style.border_color = Color(0.38, 0.56, 0.78, 0.95)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style

func update_timer_label():
	if timer_label != null:
		timer_label.text = "Time: %.1fs" % elapsed_time
	if remaining_label != null:
		var alive_count := 0
		for player in players:
			if is_instance_valid(player) and player.alive:
				alive_count += 1
		var player_label := "PLAYER" if game_mode == GameMode.SOLO else "PLAYERS"
		remaining_label.text = "%s  %d / %d" % [player_label, alive_count, players.size()]

func start_match():
	clear_ui()
	clear_world()
	match_started = true
	round_active = false
	match_ended = false
	pregame_remaining = PRE_GAME_COUNTDOWN
	elapsed_time = 0.0
	elimination_records.clear()
	final_leaderboard.clear()
	update_timer_label()
	create_arena()
	create_match_ui()
	spawn_players()
	update_timer_label()
	next_bomb_id = 1
	if game_mode != GameMode.ONLINE_MULTIPLAYER:
		start_bomb_spawner()
	elif NetworkManager.is_host():
		start_bomb_spawner()
	online_snapshot_timer = 0.0
	info_label.text = "GET READY  %.0f" % PRE_GAME_COUNTDOWN

func _advance_pregame(delta: float) -> void:
	pregame_remaining = maxf(0.0, pregame_remaining - delta)
	if is_instance_valid(info_label):
		info_label.text = "GET READY  %.0f" % ceilf(pregame_remaining)
	if pregame_remaining > 0.0:
		return
	round_active = true
	if is_instance_valid(bomb_timer):
		bomb_timer.start()
	for bomb in bombs:
		if is_instance_valid(bomb):
			bomb.start_fuse()
	if is_instance_valid(info_label):
		if game_mode == GameMode.SOLO:
			info_label.text = "WASD to move | Left Shift to dash (5s cooldown)"
		elif game_mode == GameMode.ONLINE_MULTIPLAYER:
			info_label.text = "WASD to move | Left Shift to dash (5s cooldown) | M to leave"
		else:
			info_label.text = "Player 1: WASD + Left Shift | Player 2: Arrows + Space to dash"

func spawn_players():
	players.clear()
	if game_mode == GameMode.ONLINE_MULTIPLAYER:
		var spawn_positions = [
			Vector2(ARENA_WIDTH * 0.15, ARENA_HEIGHT * 0.2),
			Vector2(ARENA_WIDTH * 0.85, ARENA_HEIGHT * 0.2),
			Vector2(ARENA_WIDTH * 0.15, ARENA_HEIGHT * 0.8),
			Vector2(ARENA_WIDTH * 0.85, ARENA_HEIGHT * 0.8),
		]
		var spawn_index := 0
		for member_id in NetworkManager.room_members:
			var member = NetworkManager.room_members[member_id]
			var player = PLAYER_SCENE.instantiate()
			player.name = "Player%d" % member_id
			player.position = spawn_positions[spawn_index]
			var display_name: String = member["name"]
			if not display_name.begins_with("Player "):
				display_name = "Player %d (%s)" % [spawn_index + 1, display_name]
			else:
				display_name = "Player %d" % (spawn_index + 1)
			player.set_player_name(display_name)
			player.set_player_id(member_id)
			player.set_player_color(COLOR_OPTIONS[member["color_index"]]["color"])
			player.configure_networked(member_id)
			_register_player(player)
			spawn_index += 1
		return

	if game_mode == GameMode.SOLO:
		var player = PLAYER_SCENE.instantiate()
		player.name = "Player1"
		player.position = Vector2(ARENA_WIDTH * 0.25, ARENA_HEIGHT / 2.0)
		player.set_player_name("Player 1")
		player.set_player_id(1)
		player.set_player_color(COLOR_OPTIONS[solo_color_index]["color"])
		_register_player(player)
		return
	
	var player1 = PLAYER_SCENE.instantiate()
	player1.name = "Player1"
	player1.position = Vector2(ARENA_WIDTH * 0.25, ARENA_HEIGHT / 2.0)
	player1.set_player_name("Player 1")
	player1.set_player_id(1)
	player1.set_player_color(COLOR_OPTIONS[p1_color_index]["color"])
	_register_player(player1)
	
	var player2 = PLAYER_SCENE.instantiate()
	player2.name = "Player2"
	player2.position = Vector2(ARENA_WIDTH * 0.75, ARENA_HEIGHT / 2.0)
	player2.set_player_name("Player 2")
	player2.set_player_id(2)
	player2.set_player_color(COLOR_OPTIONS[p2_color_index]["color"])
	_register_player(player2)

func _register_player(player: Node) -> void:
	world_root.add_child(player)
	players.append(player)
	player.player_eliminated.connect(_on_player_eliminated)

func _on_player_eliminated(player: Node) -> void:
	if not round_active or match_ended:
		return
	elimination_records.append({
		"player_id": player.player_id,
		"name": player.get_player_name(),
		"color": player.player_color,
		"time": elapsed_time,
		"frame": Engine.get_process_frames(),
	})

func start_bomb_spawner():
	if is_instance_valid(bomb_timer):
		bomb_timer.stop()
		bomb_timer.queue_free()
	
	bomb_timer = Timer.new()
	bomb_timer.wait_time = BOMB_SPAWN_INTERVAL
	bomb_timer.one_shot = false
	bomb_timer.timeout.connect(_spawn_bomb)
	world_root.add_child(bomb_timer)
	for _i in range(INITIAL_BOMB_COUNT):
		_spawn_single_bomb()

func _spawn_single_bomb():
	var safe_pos: Variant = find_valid_bomb_position()
	if safe_pos == null:
		return
	
	var bomb = BOMB_SCENE.instantiate()
	bomb.name = "Bomb"
	bomb.position = safe_pos
	if game_mode == GameMode.ONLINE_MULTIPLAYER:
		bomb.networked = true
		bomb.network_id = next_bomb_id
		network_bombs[next_bomb_id] = bomb
		next_bomb_id += 1
	world_root.add_child(bomb)
	bombs.append(bomb)
	if round_active:
		bomb.start_fuse()
	bomb.tree_exiting.connect(func():
		if bombs.has(bomb):
			bombs.erase(bomb)
		if network_bombs.get(bomb.network_id) == bomb:
			network_bombs.erase(bomb.network_id)
	)

func set_remote_player_input(peer_id: int, direction: Vector2) -> void:
	if not NetworkManager.is_host() or not round_active:
		return
	for player in players:
		if player.network_owner_id == peer_id and player.alive:
			player.set_remote_move_direction(direction)
			return

func request_remote_player_dash(peer_id: int) -> void:
	if not NetworkManager.is_host() or not round_active:
		return
	for player in players:
		if player.network_owner_id == peer_id and player.alive:
			player.request_authoritative_dash()
			return

func _make_online_match_state() -> Dictionary:
	var player_states: Array[Dictionary] = []
	for player in players:
		player_states.append({
			"peer_id": player.network_owner_id,
			"position": player.global_position,
			"alive": player.alive,
			"dash_cooldown": player.dash_cooldown,
			"dash_timer": player.dash_timer,
		})
	var bomb_states: Array[Dictionary] = []
	for bomb in bombs:
		if is_instance_valid(bomb) and bomb.is_inside_tree():
			bomb_states.append({
				"id": bomb.network_id,
				"position": bomb.global_position,
				"countdown": bomb.countdown,
				"exploded": bomb.exploded,
			})
	return {
		"elapsed_time": elapsed_time,
		"round_active": round_active,
		"pregame_remaining": pregame_remaining,
		"result_text": results_label.text if is_instance_valid(results_label) else "",
		"leaderboard": final_leaderboard,
		"players": player_states,
		"bombs": bomb_states,
	}

func _apply_online_match_state(state: Dictionary) -> void:
	if game_mode != GameMode.ONLINE_MULTIPLAYER:
		return
	elapsed_time = state.get("elapsed_time", elapsed_time)
	var was_round_active := round_active
	round_active = state.get("round_active", round_active)
	pregame_remaining = state.get("pregame_remaining", pregame_remaining)
	update_timer_label()
	if not round_active and is_instance_valid(info_label):
		info_label.text = "GET READY  %.0f" % ceilf(pregame_remaining)
	elif round_active and is_instance_valid(info_label):
		if game_mode == GameMode.ONLINE_MULTIPLAYER:
			info_label.text = "WASD to move | Left Shift to dash (5s cooldown) | M to leave"

	var players_by_peer: Dictionary = {}
	for player in players:
		players_by_peer[player.network_owner_id] = player
	for player_state in state.get("players", []):
		var peer_id: int = player_state["peer_id"]
		if not players_by_peer.has(peer_id):
			continue
		var player = players_by_peer[peer_id]
		player.global_position = player_state["position"]
		player.dash_cooldown = player_state["dash_cooldown"]
		player.dash_timer = player_state.get("dash_timer", 0.0)
		if not player_state["alive"] and player.alive:
			player.die()

	var seen_bomb_ids: Dictionary = {}
	for bomb_state in state.get("bombs", []):
		var bomb_id: int = bomb_state["id"]
		seen_bomb_ids[bomb_id] = true
		var bomb = network_bombs.get(bomb_id)
		if not is_instance_valid(bomb):
			bomb = BOMB_SCENE.instantiate()
			bomb.name = "Bomb%d" % bomb_id
			bomb.networked = true
			bomb.network_id = bomb_id
			world_root.add_child(bomb)
			bombs.append(bomb)
			network_bombs[bomb_id] = bomb
			bomb.tree_exiting.connect(func():
				if bombs.has(bomb):
					bombs.erase(bomb)
			)
		bomb.global_position = bomb_state["position"]
		bomb.apply_network_state(bomb_state["countdown"], bomb_state["exploded"])
	for bomb_id in network_bombs.keys():
		if not seen_bomb_ids.has(bomb_id):
			var bomb = network_bombs[bomb_id]
			if is_instance_valid(bomb):
				bomb.queue_free()
			network_bombs.erase(bomb_id)
			if bombs.has(bomb):
				bombs.erase(bomb)

	if was_round_active and not round_active:
		match_ended = true
		update_timer_label()
		final_leaderboard = state.get("leaderboard", [])
		_display_results(state.get("result_text", "MATCH RESULTS"), final_leaderboard)

func _spawn_bomb():
	if not round_active:
		return
	for _i in range(BOMBS_PER_WAVE):
		_spawn_single_bomb()

func find_valid_bomb_position() -> Variant:
	var region_width := (ARENA_WIDTH - BOMB_EDGE_MARGIN * 2.0) / SPAWN_COLUMNS
	var region_height := (ARENA_HEIGHT - BOMB_EDGE_MARGIN * 2.0) / SPAWN_ROWS
	var region_count := SPAWN_COLUMNS * SPAWN_ROWS
	for _region_attempt in range(region_count):
		if spawn_region_order.is_empty():
			_refill_spawn_regions()
		var region: Vector2i = spawn_region_order.pop_back()
		var region_left := BOMB_EDGE_MARGIN + region.x * region_width
		var region_top := BOMB_EDGE_MARGIN + region.y * region_height
		for _position_attempt in range(12):
			var candidate := Vector2(
				randf_range(region_left, region_left + region_width),
				randf_range(region_top, region_top + region_height)
			)
			if _is_valid_bomb_position(candidate):
				return candidate

	for _attempt in range(120):
		var candidate := Vector2(
			randf_range(BOMB_EDGE_MARGIN, ARENA_WIDTH - BOMB_EDGE_MARGIN),
			randf_range(BOMB_EDGE_MARGIN, ARENA_HEIGHT - BOMB_EDGE_MARGIN)
		)
		if _is_valid_bomb_position(candidate):
			return candidate

	for y in range(27):
		for x in range(48):
			var candidate := Vector2(
				lerpf(BOMB_EDGE_MARGIN, ARENA_WIDTH - BOMB_EDGE_MARGIN, float(x) / 47.0),
				lerpf(BOMB_EDGE_MARGIN, ARENA_HEIGHT - BOMB_EDGE_MARGIN, float(y) / 26.0)
			)
			if _is_valid_bomb_position(candidate):
				return candidate
	return null

func _refill_spawn_regions() -> void:
	spawn_region_order.clear()
	for y in range(SPAWN_ROWS):
		for x in range(SPAWN_COLUMNS):
			spawn_region_order.append(Vector2i(x, y))
	spawn_region_order.shuffle()

func _is_valid_bomb_position(candidate: Vector2) -> bool:
	for player in players:
		if player != null and player.is_inside_tree() and player.alive:
			if player.global_position.distance_to(candidate) < BOMB_PLAYER_SAFE_DISTANCE:
				return false
	return true

func check_for_game_over():
	if not round_active or match_ended:
		return

	var alive_players = []
	for player in get_tree().get_nodes_in_group("players"):
		if player.alive:
			alive_players.append(player)

	var game_over := alive_players.is_empty()
	if game_mode != GameMode.SOLO:
		game_over = alive_players.size() <= 1
	if not game_over:
		return
	match_ended = true
	round_active = false
	if is_instance_valid(bomb_timer):
		bomb_timer.stop()
	for bomb in bombs:
		if is_instance_valid(bomb):
			bomb.set_process(false)
			bomb.monitoring = false
	for player in players:
		if is_instance_valid(player):
			player.set_physics_process(false)
	update_timer_label()
	show_results(alive_players)

func show_results(alive_players: Array):
	final_leaderboard = _build_final_leaderboard(alive_players)
	var headline := "MATCH RESULTS"
	if game_mode == GameMode.SOLO:
		if alive_players.size() == 1:
			headline = "YOU SURVIVED"
		else:
			headline = "YOU WERE HIT!"
	elif game_mode == GameMode.ONLINE_MULTIPLAYER:
		if alive_players.size() == 1:
			headline = "%s WINS!" % alive_players[0].get_player_name()
		else:
			headline = "DRAW!"
	else:
		if alive_players.size() == 1:
			headline = "%s WINS!" % alive_players[0].get_player_name()
		else:
			headline = "DRAW!"
	_display_results("%s\nFinal time: %.1fs" % [headline, elapsed_time], final_leaderboard)

func _build_final_leaderboard(alive_players: Array) -> Array[Dictionary]:
	var leaderboard: Array[Dictionary] = []
	var survivors := alive_players.duplicate()
	survivors.sort_custom(func(a, b): return a.player_id < b.player_id)
	for player in survivors:
		leaderboard.append(_make_leaderboard_entry(player, 1, survivors.size() > 1))

	var records := elimination_records.duplicate()
	records.sort_custom(func(a, b):
		if a["frame"] == b["frame"]:
			return a["player_id"] < b["player_id"]
		return a["frame"] > b["frame"]
	)
	var index := 0
	while index < records.size():
		var end_index := index + 1
		while end_index < records.size() and records[end_index]["frame"] == records[index]["frame"]:
			end_index += 1
		var tied := end_index - index > 1
		var place := leaderboard.size() + 1
		for record_index in range(index, end_index):
			var record: Dictionary = records[record_index]
			leaderboard.append({
				"place": place,
				"name": record["name"],
				"color": record["color"],
				"player_id": record["player_id"],
				"time": record["time"],
				"tied": tied,
			})
		index = end_index
	return leaderboard

func _make_leaderboard_entry(player: Node, place: int, tied: bool) -> Dictionary:
	return {
		"place": place,
		"name": player.get_player_name(),
		"color": player.player_color,
		"player_id": player.player_id,
		"time": elapsed_time,
		"tied": tied,
	}

func _display_results(title: String, leaderboard: Array) -> void:
	results_label.text = title
	results_label.visible = true
	for child in leaderboard_box.get_children():
		child.queue_free()
	for entry in leaderboard:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(22, 22)
		swatch.color = entry["color"]
		row.add_child(swatch)
		var place_label := Label.new()
		place_label.text = _placement_text(entry["place"], entry.get("tied", false))
		place_label.custom_minimum_size = Vector2(160, 30)
		place_label.add_theme_font_size_override("font_size", 19)
		row.add_child(place_label)
		var name_label := Label.new()
		name_label.text = entry["name"]
		name_label.add_theme_color_override("font_color", entry["color"].lightened(0.25))
		name_label.add_theme_font_size_override("font_size", 20)
		row.add_child(name_label)
		var time_label := Label.new()
		time_label.text = "%.1fs" % entry["time"]
		time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		time_label.add_theme_color_override("font_color", Color(0.72, 0.79, 0.9))
		row.add_child(time_label)
		leaderboard_box.add_child(row)
	results_panel.visible = true
	results_label.modulate = Color.WHITE

func _placement_text(place: int, tied: bool) -> String:
	var suffix := "th"
	if place % 100 < 11 or place % 100 > 13:
		match place % 10:
			1: suffix = "st"
			2: suffix = "nd"
			3: suffix = "rd"
	return "%d%s Place%s" % [place, suffix, " (Tie)" if tied else ""]
