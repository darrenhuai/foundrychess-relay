extends SceneTree

## Standalone WebSocket relay for Foundry Chess's 2-player online mode.
##
## Deliberately game-unaware: it only knows how to (1) hand out a short room
## code to whoever asks to host, (2) pair a second connection that asks to
## join with that code, and (3) forward whatever bytes one side of a pair
## sends to the other side, unread. The actual game protocol (NetActions on
## the client side) can change freely without ever touching this file.
##
## Run with: godot4 --headless --path server -s relay_server.gd
## Needs one open TCP port (PORT below, or override with --port=NNNN).

const DEFAULT_PORT := 8910
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O/1/I/L -- easy to misread aloud
const CODE_LENGTH := 5
const TICK_MS := 16

## How long a room stays alive after one side drops before the OTHER side is
## told it's truly over. Long enough to survive a real wifi blip or an app
## getting backgrounded for a minute, short enough that a genuinely abandoned
## room doesn't sit around forever. Overridable via --grace-ms= so
## relay_server_test.gd can exercise real expiry without a 60s-real-time test.
const DEFAULT_GRACE_MS := 60000

var _port := DEFAULT_PORT
var _grace_ms := DEFAULT_GRACE_MS
var _tcp := TCPServer.new()
var _pending: Array[WebSocketPeer] = []          # mid-handshake
var _active: Array[WebSocketPeer] = []            # handshake complete
var _room_of: Dictionary = {}                     # WebSocketPeer -> room code
var _role_of: Dictionary = {}                      # WebSocketPeer -> "host" | "guest"
var _rooms: Dictionary = {}                        # code -> {host: WebSocketPeer, guest: WebSocketPeer}

func _initialize() -> void:
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--port="):
			_port = arg.trim_prefix("--port=").to_int()
		elif arg.begins_with("--grace-ms="):
			_grace_ms = arg.trim_prefix("--grace-ms=").to_int()

	var err := _tcp.listen(_port)
	if err != OK:
		print("Relay server: failed to listen on port %d (error %d)" % [_port, err])
		quit(1)
		return
	print("Relay server listening on port %d" % _port)

	while true:
		_tick()
		OS.delay_msec(TICK_MS)

func _tick() -> void:
	_accept_new_connections()
	_poll_pending()
	_poll_active()
	_check_grace_periods()

func _accept_new_connections() -> void:
	while _tcp.is_connection_available():
		var tcp_peer := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		ws.accept_stream(tcp_peer)
		_pending.append(ws)

func _poll_pending() -> void:
	var still_pending: Array[WebSocketPeer] = []
	for ws in _pending:
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			_active.append(ws)
		elif state == WebSocketPeer.STATE_CONNECTING:
			still_pending.append(ws)
		# STATE_CLOSING / STATE_CLOSED: handshake failed, just drop it.
	_pending = still_pending

func _poll_active() -> void:
	var still_active: Array[WebSocketPeer] = []
	for ws in _active:
		ws.poll()
		if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			_on_disconnect(ws)
			continue
		while ws.get_available_packet_count() > 0:
			_handle_packet(ws, ws.get_packet())
		still_active.append(ws)
	_active = still_active

func _handle_packet(ws: WebSocketPeer, bytes: PackedByteArray) -> void:
	var text := bytes.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	match msg.get("type", ""):
		"host":
			_handle_host(ws)
		"join":
			_handle_join(ws, str(msg.get("code", "")))
		"rejoin":
			_handle_rejoin(ws, str(msg.get("code", "")), str(msg.get("role", "")), str(msg.get("token", "")))
		"relay":
			_handle_relay(ws, msg.get("payload"))

func _handle_host(ws: WebSocketPeer) -> void:
	if _room_of.has(ws):
		return  # already in a room, ignore a duplicate host request
	var code := _make_unique_code()
	var token := _make_token()
	_rooms[code] = {"host": ws, "guest": null, "host_disconnected_at": -1, "guest_disconnected_at": -1, "host_token": token, "guest_token": ""}
	_room_of[ws] = code
	_role_of[ws] = "host"
	_send(ws, {"type": "hosted", "code": code, "token": token})

func _handle_join(ws: WebSocketPeer, code: String) -> void:
	if _room_of.has(ws):
		return
	code = code.to_upper()
	if not _rooms.has(code):
		_send(ws, {"type": "join_failed", "reason": "not_found"})
		return
	var room: Dictionary = _rooms[code]
	# The room can outlive its host during the host's disconnect grace window
	# (see _on_disconnect): the host slot is null but the room isn't erased yet
	# because no guest had joined to wait for. Pairing a fresh guest to it would
	# _send(null, ...) below and crash -- and leave the guest "paired" to a host
	# that isn't there. Treat a host-less room as unavailable; the host may still
	# rejoin, and the guest can retry.
	if room.host == null:
		_send(ws, {"type": "join_failed", "reason": "not_found"})
		return
	if room.guest != null:
		_send(ws, {"type": "join_failed", "reason": "already_full"})
		return
	room.guest = ws
	_room_of[ws] = code
	_role_of[ws] = "guest"
	var token := _make_token()
	room["guest_token"] = token
	_send(ws, {"type": "paired", "token": token})
	_send(room.host, {"type": "paired"})

## Reclaims a room slot after a dropped connection reconnects -- the room
## survives a disconnect for GRACE_MS (see _on_disconnect/_check_grace_periods)
## specifically so this can succeed instead of the returning player finding
## their game already torn down. Tells BOTH sides "rejoined" (not just the
## one reconnecting) since the side that stayed connected needs to know too --
## NetActions.gd uses that on the host's side to push a fresh state_sync,
## covering the case where the returning peer's own GameState was wiped
## (app fully closed and reopened) rather than just its socket dropping.
func _handle_rejoin(ws: WebSocketPeer, code: String, role: String, token: String) -> void:
	# A genuinely-reconnecting peer arrives on a NEW socket (its old one was
	# dropped and cleared from _room_of by _on_disconnect), so it is never
	# already mapped. A socket that IS still mapped asking to rejoin is abuse --
	# e.g. a connected guest claiming role "host" for its own room while the
	# host is briefly disconnected, which would point room.host and room.guest
	# at the same peer (self-relay) and lock the real host out. Reject it, the
	# same "already in a room" guard _handle_host/_handle_join already use.
	if _room_of.has(ws):
		return
	code = code.to_upper()
	if role != "host" and role != "guest":
		_send(ws, {"type": "rejoin_failed", "reason": "bad_role"})
		return
	if not _rooms.has(code):
		_send(ws, {"type": "rejoin_failed", "reason": "not_found"})
		return
	var room: Dictionary = _rooms[code]
	if room.get(role) != null or room.get(role + "_disconnected_at", -1) == -1:
		_send(ws, {"type": "rejoin_failed", "reason": "nothing_to_rejoin"})
		return
	# Slot-reclaim auth: knowing the shared room code isn't enough -- the peer
	# must present the secret token it was handed when it first took this slot
	# (see _handle_host/_handle_join). Blocks a stranger who overheard the code
	# from seizing a briefly-dropped player's seat.
	var expected: String = str(room.get(role + "_token", ""))
	if expected == "" or token != expected:
		_send(ws, {"type": "rejoin_failed", "reason": "bad_token"})
		return
	room[role] = ws
	room[role + "_disconnected_at"] = -1
	_room_of[ws] = code
	_role_of[ws] = role
	var other: WebSocketPeer = room.guest if role == "host" else room.host
	_send(ws, {"type": "rejoined"})
	if other != null:
		_send(other, {"type": "rejoined"})

## The relay never inspects `payload` -- it's the game's own message, opaque
## to this server. Just hand it to whichever peer isn't the sender.
func _handle_relay(ws: WebSocketPeer, payload) -> void:
	var code: String = _room_of.get(ws, "")
	if code == "" or not _rooms.has(code):
		return
	var room: Dictionary = _rooms[code]
	var other: WebSocketPeer = room.guest if ws == room.host else room.host
	if other != null:
		_send(other, {"type": "relay", "payload": payload})

## Doesn't immediately tear the room down -- marks this ws's slot as
## disconnected-but-recoverable and tells the other side "peer_disconnected"
## (temporary; the client shows a "reconnecting" state, not a final one).
## The room only actually gets erased once _check_grace_periods() finds no
## rejoin happened within GRACE_MS, or immediately here if the OTHER slot was
## already empty too (nobody left to rejoin for).
func _on_disconnect(ws: WebSocketPeer) -> void:
	var code: String = _room_of.get(ws, "")
	var role: String = _role_of.get(ws, "")
	if code != "" and _rooms.has(code):
		var room: Dictionary = _rooms[code]
		room[role] = null
		room[role + "_disconnected_at"] = Time.get_ticks_msec()
		var other_role := "guest" if role == "host" else "host"
		var other: WebSocketPeer = room.get(other_role)
		if other != null:
			_send(other, {"type": "peer_disconnected"})
		elif room.get(other_role + "_disconnected_at", -1) != -1:
			_rooms.erase(code)  # both sides already gone -- nothing left to wait for
	_room_of.erase(ws)
	_role_of.erase(ws)

## Finalizes any room whose disconnected side never came back within
## GRACE_MS -- tells the remaining peer (if any) it's really over, THEN erases
## the room. Runs every tick rather than via a per-room timer/signal since
## the server's own loop already ticks at TICK_MS and there are at most a
## handful of rooms at once; a msec timestamp comparison here is simpler than
## wiring up SceneTree timers against WebSocketPeer objects.
func _check_grace_periods() -> void:
	var now := Time.get_ticks_msec()
	var expired_codes: Array = []
	for code in _rooms:
		var room: Dictionary = _rooms[code]
		for role in ["host", "guest"]:
			var disconnected_at: int = room.get(role + "_disconnected_at", -1)
			if disconnected_at != -1 and now - disconnected_at > _grace_ms:
				var other_role := "guest" if role == "host" else "host"
				var other: WebSocketPeer = room.get(other_role)
				if other != null:
					_send(other, {"type": "peer_left"})
					# The surviving peer stays connected but its room is about to
					# be erased -- clear its stale mapping too, or _handle_host/
					# _handle_join would keep ignoring it (it'd still look "in a
					# room") and it couldn't start a new game without reconnecting.
					_room_of.erase(other)
					_role_of.erase(other)
				expired_codes.append(code)
				break
	for code in expired_codes:
		_rooms.erase(code)

func _send(ws: WebSocketPeer, data: Dictionary) -> void:
	ws.send_text(JSON.stringify(data))

const TOKEN_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
const TOKEN_LENGTH := 22

## A per-room, per-role secret handed to each peer when it hosts/joins and
## required to reclaim that slot on rejoin. Unlike the room code (short, shared
## aloud), this never leaves the owning client, so overhearing the code alone
## can't seize a dropped seat.
func _make_token() -> String:
	var s := ""
	for i in range(TOKEN_LENGTH):
		s += TOKEN_ALPHABET[randi() % TOKEN_ALPHABET.length()]
	return s

func _make_unique_code() -> String:
	var code := _random_code()
	while _rooms.has(code):
		code = _random_code()
	return code

func _random_code() -> String:
	var s := ""
	for i in range(CODE_LENGTH):
		s += CODE_ALPHABET[randi() % CODE_ALPHABET.length()]
	return s
