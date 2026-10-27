extends Node

const PORT := 4242
const MAX_PLAYERS := 4
const ROOM_CODE_LENGTH := 6
const COLOR_COUNT := 7
const ROOM_CODE_CHARACTERS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

signal room_updated
signal connection_status_changed(message: String)
signal online_match_started
signal match_state_received(state: Dictionary)

var peer: ENetMultiplayerPeer
var room_code := ""
var room_members: Dictionary = {}
var pending_room_code := ""
var room_active := false
var match_started := false

func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func host_game() -> bool:
	_leave_room(false)
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS - 1)
	if err != OK:
		peer = null
		connection_status_changed.emit("Could not host on UDP port %d (error %d)." % [PORT, err])
		return false

	multiplayer.multiplayer_peer = peer
	room_active = true
	match_started = false
	room_code = _generate_room_code()
	room_members = {
		1: {"name": "Host", "color_index": 0}
	}
	room_updated.emit()
	connection_status_changed.emit("Room is ready. Share its code and your host address.")
	return true

func join_game(host_address: String, code: String) -> bool:
	_leave_room(false)
	var address := host_address.strip_edges()
	var normalized_code := code.strip_edges().to_upper()
	if address.is_empty() or normalized_code.length() != ROOM_CODE_LENGTH:
		connection_status_changed.emit("Enter a host address and a 6-character room code.")
		return false

	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		peer = null
		connection_status_changed.emit("Could not connect to %s:%d (error %d)." % [address, PORT, err])
		return false

	multiplayer.multiplayer_peer = peer
	room_active = true
	match_started = false
	room_code = normalized_code
	pending_room_code = normalized_code
	connection_status_changed.emit("Connecting to %s:%d..." % [address, PORT])
	return true

func leave_room() -> void:
	_leave_room(true)

func _leave_room(emit_status: bool) -> void:
	if peer != null:
		peer.close()
		peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	room_active = false
	match_started = false
	room_code = ""
	pending_room_code = ""
	room_members.clear()
	room_updated.emit()
	if emit_status:
		connection_status_changed.emit("Left the room.")

func is_host() -> bool:
	return room_active and peer != null and multiplayer.is_server()

func is_online_match() -> bool:
	return room_active and match_started

func set_local_color(color_index: int) -> void:
	if color_index < 0 or color_index >= COLOR_COUNT or not room_active:
		return
	if is_host():
		_apply_color_change(1, color_index)
	else:
		_request_color_change.rpc_id(1, color_index)

func _apply_color_change(member_id: int, color_index: int) -> void:
	if match_started or not room_members.has(member_id):
		return
	for other_id in room_members:
		if other_id != member_id and room_members[other_id]["color_index"] == color_index:
			connection_status_changed.emit("That color is already taken.")
			return
	room_members[member_id]["color_index"] = color_index
	_broadcast_room()

func start_online_match() -> bool:
	if not is_host() or match_started:
		return false
	if room_members.size() < 2:
		connection_status_changed.emit("At least two players are needed to start.")
		return false
	match_started = true
	online_match_started.emit()
	_receive_match_started.rpc()
	return true

func submit_player_input(direction: Vector2) -> void:
	if not is_online_match() or is_host():
		return
	var safe_direction := Vector2(
		clampf(direction.x, -1.0, 1.0),
		clampf(direction.y, -1.0, 1.0)
	)
	if safe_direction.length_squared() > 1.0:
		safe_direction = safe_direction.normalized()
	_receive_player_input.rpc_id(1, safe_direction)

func request_player_dash() -> void:
	if is_online_match() and not is_host():
		_request_player_dash.rpc_id(1)

func broadcast_match_state(state: Dictionary) -> void:
	if is_host() and match_started:
		_receive_match_state.rpc(state)

func _generate_room_code() -> String:
	var code := ""
	for i in range(ROOM_CODE_LENGTH):
		code += ROOM_CODE_CHARACTERS[randi_range(0, ROOM_CODE_CHARACTERS.length() - 1)]
	return code

func _is_valid_direction(direction: Vector2) -> bool:
	return (
		not is_nan(direction.x)
		and not is_inf(direction.x)
		and not is_nan(direction.y)
		and not is_inf(direction.y)
	)

func _on_connected_to_server() -> void:
	connection_status_changed.emit("Connected. Checking room code...")
	_request_join.rpc_id(1, pending_room_code)

func _on_connection_failed() -> void:
	_leave_room(false)
	connection_status_changed.emit("Connection failed. Check the host address, port, and firewall.")

func _on_server_disconnected() -> void:
	_leave_room(false)
	connection_status_changed.emit("The host disconnected.")

func _on_peer_disconnected(id: int) -> void:
	if not is_host() or not room_members.has(id):
		return
	room_members.erase(id)
	_broadcast_room()
	connection_status_changed.emit("A player left the room.")

func _broadcast_room() -> void:
	room_updated.emit()
	_receive_room_state.rpc(room_members)

func _reject_peer(id: int, reason: String) -> void:
	_join_rejected.rpc_id(id, reason)
	var rejected_peer := peer
	get_tree().create_timer(0.25).timeout.connect(func():
		if rejected_peer != null:
			rejected_peer.disconnect_peer(id)
	)

@rpc("any_peer", "call_remote", "reliable")
func _request_join(code: String) -> void:
	if not is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if match_started:
		_reject_peer(sender_id, "The match has already started.")
		return
	if code != room_code:
		_reject_peer(sender_id, "That room code is incorrect.")
		return
	if room_members.size() >= MAX_PLAYERS:
		_reject_peer(sender_id, "This room is full.")
		return
	var color_index := -1
	for candidate in range(COLOR_COUNT):
		var color_taken := false
		for member_id in room_members:
			if room_members[member_id]["color_index"] == candidate:
				color_taken = true
				break
		if not color_taken:
			color_index = candidate
			break
	if color_index == -1:
		_reject_peer(sender_id, "No colors are available.")
		return

	room_members[sender_id] = {
		"name": "Player %d" % sender_id,
		"color_index": color_index
	}
	_join_accepted.rpc_id(sender_id, room_members)
	_broadcast_room()
	connection_status_changed.emit("A player joined the room.")

@rpc("any_peer", "call_remote", "reliable")
func _request_color_change(color_index: int) -> void:
	if not is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not room_members.has(sender_id) or color_index < 0 or color_index >= COLOR_COUNT:
		return
	_apply_color_change(sender_id, color_index)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_player_input(direction: Vector2) -> void:
	if not is_host() or not match_started:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not room_members.has(sender_id) or not _is_valid_direction(direction):
		return
	var game := get_tree().current_scene
	if game.has_method("set_remote_player_input"):
		var safe_direction := Vector2(
			clampf(direction.x, -1.0, 1.0),
			clampf(direction.y, -1.0, 1.0)
		)
		if safe_direction.length_squared() > 1.0:
			safe_direction = safe_direction.normalized()
		game.set_remote_player_input(sender_id, safe_direction)

@rpc("any_peer", "call_remote", "reliable")
func _request_player_dash() -> void:
	if not is_host() or not match_started:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not room_members.has(sender_id):
		return
	var game := get_tree().current_scene
	if game.has_method("request_remote_player_dash"):
		game.request_remote_player_dash(sender_id)

@rpc("authority", "call_remote", "reliable")
func _join_accepted(members: Dictionary) -> void:
	room_members = members
	pending_room_code = ""
	room_updated.emit()
	connection_status_changed.emit("Joined the room.")

@rpc("authority", "call_remote", "reliable")
func _join_rejected(reason: String) -> void:
	_leave_room(false)
	connection_status_changed.emit(reason)

@rpc("authority", "call_remote", "reliable")
func _receive_room_state(members: Dictionary) -> void:
	room_members = members
	room_updated.emit()

@rpc("authority", "call_remote", "reliable")
func _receive_match_started() -> void:
	match_started = true
	online_match_started.emit()

@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_match_state(state: Dictionary) -> void:
	match_state_received.emit(state)
