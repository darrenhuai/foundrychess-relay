extends SceneTree

## Standalone WebSocket relay for ChessTan's online mode -- supports rooms of
## up to MAX_PEERS raw connections (peer id 0 is always the room's creator,
## the "host"; ids 1-3 are whoever joins after, in join order).
##
## Deliberately game-unaware: it only knows how to (1) hand out a short room
## code to whoever asks to host, (2) assign a peer id to whoever asks to join
## with that code, and (3) forward whatever bytes one peer sends to every
## OTHER peer currently in the room, unread. The actual game protocol
## (NetActions on the client side) can change freely without ever touching
## this file -- it doesn't even know a "game" exists, only peers and rooms.
##
## Run with: godot4 --headless --path server -s relay_server.gd
## Needs one open TCP port (PORT below, or override with --port=NNNN).

const DEFAULT_PORT := 8910
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O/1/I/L -- easy to misread aloud
const CODE_LENGTH := 5
const TICK_MS := 16
const MAX_PEERS := 4
const HOST_PEER_ID := 0

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
var _peer_id_of: Dictionary = {}                  # WebSocketPeer -> assigned int peer id (0-3)
## code -> {
##   peers: {peer_id: WebSocketPeer},              -- only currently-CONNECTED ids
##   tokens: {peer_id: String},                    -- every id ever assigned, kept until its slot fully frees
##   disconnected_at: {peer_id: int},               -- -1 while connected; a msec timestamp while dropped
## }
var _rooms: Dictionary = {}

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
			_handle_rejoin(ws, str(msg.get("code", "")), int(msg.get("peer_id", -1)), str(msg.get("token", "")))
		"relay":
			_handle_relay(ws, msg.get("payload"))

func _handle_host(ws: WebSocketPeer) -> void:
	if _room_of.has(ws):
		return  # already in a room, ignore a duplicate host request
	var code := _make_unique_code()
	var token := _make_token()
	_rooms[code] = {
		"peers": {HOST_PEER_ID: ws},
		"tokens": {HOST_PEER_ID: token},
		"disconnected_at": {HOST_PEER_ID: -1},
	}
	_room_of[ws] = code
	_peer_id_of[ws] = HOST_PEER_ID
	_send(ws, {"type": "hosted", "code": code, "token": token, "peer_id": HOST_PEER_ID})

## Assigns the smallest unclaimed non-host id (1-3) -- "unclaimed" meaning
## never assigned at all, NOT merely disconnected. A slot mid-grace-period is
## reserved for its own peer's rejoin (see _handle_rejoin), not available to a
## brand-new joiner. Returns -1 once ids 0-3 are all spoken for.
func _next_free_peer_id(room: Dictionary) -> int:
	for pid in range(1, MAX_PEERS):
		if not room.tokens.has(pid):
			return pid
	return -1

func _handle_join(ws: WebSocketPeer, code: String) -> void:
	if _room_of.has(ws):
		return
	code = code.to_upper()
	if not _rooms.has(code):
		_send(ws, {"type": "join_failed", "reason": "not_found"})
		return
	var room: Dictionary = _rooms[code]
	# The room can outlive its host during the host's disconnect grace window
	# (see _on_disconnect): the host slot is empty but the room isn't erased
	# yet because other peers may still be around. Pairing a fresh joiner to a
	# host-less room would leave it waiting on an authority that isn't there;
	# the host may still rejoin, and the joiner can retry.
	if room.peers.get(HOST_PEER_ID) == null:
		_send(ws, {"type": "join_failed", "reason": "not_found"})
		return
	var new_id := _next_free_peer_id(room)
	if new_id == -1:
		_send(ws, {"type": "join_failed", "reason": "already_full"})
		return
	var token := _make_token()
	room.peers[new_id] = ws
	room.tokens[new_id] = token
	room.disconnected_at[new_id] = -1
	_room_of[ws] = code
	_peer_id_of[ws] = new_id
	_send(ws, {"type": "paired", "token": token, "peer_id": new_id})
	# The very first guest (id 1) keeps the exact original wire shape the
	# 2-peer flow has always used (bare "paired", no fields) -- a 2-player
	# game never sees anything new. A 3rd/4th peer joining an already-paired
	# room is a capability nothing before this could reach, so it gets its
	# own message naming who just showed up.
	for pid in room.peers:
		if pid == new_id:
			continue
		var other: WebSocketPeer = room.peers[pid]
		if other == null:
			continue
		if new_id == 1:
			_send(other, {"type": "paired"})
		else:
			_send(other, {"type": "peer_joined", "peer_id": new_id})

## Reclaims a room slot after a dropped connection reconnects -- the slot
## survives a disconnect for GRACE_MS (see _on_disconnect/_check_grace_periods)
## specifically so this can succeed instead of the returning player finding
## their game already torn down. Tells every OTHER currently-connected peer
## "rejoined" too (not just the one reconnecting) since they need to know --
## NetActions.gd uses that on the host's side to push a fresh state_sync,
## covering the case where the returning peer's own GameState was wiped (app
## fully closed and reopened) rather than just its socket dropping.
func _handle_rejoin(ws: WebSocketPeer, code: String, peer_id: int, token: String) -> void:
	# A genuinely-reconnecting peer arrives on a NEW socket (its old one was
	# dropped and cleared from _room_of by _on_disconnect), so it is never
	# already mapped. A socket that IS still mapped asking to rejoin is abuse
	# -- e.g. a connected peer claiming someone else's id while that peer is
	# briefly disconnected, which would point two ids at the same socket.
	if _room_of.has(ws):
		return
	code = code.to_upper()
	if peer_id < 0 or peer_id >= MAX_PEERS:
		_send(ws, {"type": "rejoin_failed", "reason": "bad_peer_id"})
		return
	if not _rooms.has(code):
		_send(ws, {"type": "rejoin_failed", "reason": "not_found"})
		return
	var room: Dictionary = _rooms[code]
	if not room.tokens.has(peer_id) or room.peers.get(peer_id) != null or room.disconnected_at.get(peer_id, -1) == -1:
		_send(ws, {"type": "rejoin_failed", "reason": "nothing_to_rejoin"})
		return
	# Slot-reclaim auth: knowing the shared room code isn't enough -- the peer
	# must present the secret token it was handed when it first took this slot
	# (see _handle_host/_handle_join). Blocks a stranger who overheard the code
	# from seizing a briefly-dropped player's seat.
	var expected: String = str(room.tokens.get(peer_id, ""))
	if expected == "" or token != expected:
		_send(ws, {"type": "rejoin_failed", "reason": "bad_token"})
		return
	room.peers[peer_id] = ws
	room.disconnected_at[peer_id] = -1
	_room_of[ws] = code
	_peer_id_of[ws] = peer_id
	_send(ws, {"type": "rejoined", "peer_id": peer_id})
	for pid in room.peers:
		if pid != peer_id and room.peers[pid] != null:
			_send(room.peers[pid], {"type": "rejoined", "peer_id": peer_id})

## The relay never inspects `payload` -- it's the game's own message, opaque
## to this server. Fans it out to every OTHER peer currently connected in the
## sender's room, tagged with the sender's own id so recipients (in a 3-4
## peer room) know who it came from.
func _handle_relay(ws: WebSocketPeer, payload) -> void:
	var code: String = _room_of.get(ws, "")
	if code == "" or not _rooms.has(code):
		return
	var room: Dictionary = _rooms[code]
	var sender_id: int = _peer_id_of.get(ws, -1)
	for pid in room.peers:
		if pid == sender_id:
			continue
		var other: WebSocketPeer = room.peers[pid]
		if other != null:
			_send(other, {"type": "relay", "payload": payload, "from": sender_id})

func _room_is_empty(room: Dictionary) -> bool:
	for pid in room.peers:
		if room.peers[pid] != null:
			return false
	return true

## Doesn't immediately tear the room down -- marks this peer's slot as
## disconnected-but-recoverable and tells every OTHER still-connected peer
## "peer_disconnected" (temporary; the client shows a "reconnecting" state,
## not a final one). The room only actually erases once every peer in it is
## gone (nothing left to wait for), or later via _check_grace_periods() for
## whichever specific ids never come back.
func _on_disconnect(ws: WebSocketPeer) -> void:
	var code: String = _room_of.get(ws, "")
	var pid: int = _peer_id_of.get(ws, -1)
	if code != "" and _rooms.has(code) and pid != -1:
		var room: Dictionary = _rooms[code]
		room.peers[pid] = null
		room.disconnected_at[pid] = Time.get_ticks_msec()
		for other_pid in room.peers:
			if other_pid != pid and room.peers[other_pid] != null:
				_send(room.peers[other_pid], {"type": "peer_disconnected", "peer_id": pid})
		if _room_is_empty(room):
			_rooms.erase(code)
	_room_of.erase(ws)
	_peer_id_of.erase(ws)

## Finalizes any peer slot whose disconnected side never came back within
## GRACE_MS -- tells every remaining connected peer that id is really gone
## (peer_left), then frees the slot entirely (so a later joiner could claim
## it). Only erases the whole room once that leaves nobody connected at all;
## a 3-4 peer room keeps going for whoever's left, since deciding whether the
## match itself can continue is a game-logic call, not this transport's.
## Runs every tick rather than via a per-room timer/signal since the server's
## own loop already ticks at TICK_MS and there are at most a handful of rooms
## at once; a msec timestamp comparison here is simpler than wiring up
## SceneTree timers against WebSocketPeer objects.
func _check_grace_periods() -> void:
	var now := Time.get_ticks_msec()
	var codes_to_erase: Array = []
	for code in _rooms:
		var room: Dictionary = _rooms[code]
		var expired_ids: Array = []
		for pid in room.disconnected_at:
			var disconnected_at: int = room.disconnected_at[pid]
			if disconnected_at != -1 and now - disconnected_at > _grace_ms:
				expired_ids.append(pid)
		if expired_ids.is_empty():
			continue
		for pid in expired_ids:
			for other_pid in room.peers:
				if other_pid != pid and room.peers[other_pid] != null:
					_send(room.peers[other_pid], {"type": "peer_left", "peer_id": pid})
			room.peers.erase(pid)
			room.tokens.erase(pid)
			room.disconnected_at.erase(pid)
		if _room_is_empty(room):
			codes_to_erase.append(code)
	for code in codes_to_erase:
		_rooms.erase(code)

func _send(ws: WebSocketPeer, data: Dictionary) -> void:
	ws.send_text(JSON.stringify(data))

const TOKEN_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
const TOKEN_LENGTH := 22

## A per-room, per-peer secret handed to each peer when it hosts/joins and
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
