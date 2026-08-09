# ChessTan Relay

Tiny standalone matchmaking/relay server for [ChessTan](https://github.com/darrenhuai/foundrychess-web)'s
2-4 player online mode. ChessTan runs as a Discord Activity, and this is the
server its clients connect to so they can find each other (up to 4 peers per
room) and pass moves back and forth.

It's deliberately game-unaware: it only knows how to hand out a room code,
let up to 4 peers join with that code, and fan out whatever bytes one side
sends to every other peer in the room. The actual game protocol can change
freely without ever touching this repo.

## How it works

Rooms hold up to 4 peers, each identified by a small integer `peer_id` (the
host is always `0`; joiners get the next free id, `1`-`3`).

1. The host's client connects and sends `{"type": "host"}`; the server
   generates a 5-character room code (no `0`/`O`/`1`/`I`/`L`, so it's easy to
   read out loud on a call) plus a per-peer token, and sends both back.
2. Each other player sends `{"type": "join", "code": "..."}` (rejected once
   4 peers are already in the room). They get `{"type": "paired", ...}`
   back; everyone already in the room gets `{"type": "peer_joined", ...}`.
3. From then on, any side sends `{"type": "relay", "payload": ...}` and the
   server fans it out to every *other* peer in the room, tagged with the
   sender's `peer_id`, untouched otherwise.
4. A peer that disconnects gets a grace period to `{"type": "rejoin", ...}`
   using its token before its slot is permanently freed
   (`{"type": "peer_left", ...}` to the rest of the room). The room itself
   only tears down once every peer in it is gone for good — one peer
   dropping doesn't end the game for the others.

That's the whole protocol — one file, `relay_server.gd`, running headless
under Godot.

## Running locally

```bash
godot4 --headless --path . -s relay_server.gd --port=8910
```

Requires Godot 4.7+. `--port` is optional and defaults to `8910`.

## Deploying

```bash
docker build -t chesstan-relay .
docker run -p 8910:8910 chesstan-relay
```

The Docker image downloads the official Godot Linux binary at build time
rather than shipping one, so the repo itself stays binary-free.

It reads `$PORT` at startup (falling back to `8910`), so the same image
works unmodified on hosts that assign the port dynamically (Render) or ones
that use a fixed internal port (Fly.io).

## Related

- [foundrychess-web](https://github.com/darrenhuai/foundrychess-web) — the
  ChessTan game itself, built for Discord Activity hosting. (This repo kept
  its original name on purpose -- it's the recruiter/portfolio-facing link
  and stays stable even as the rest of the project moved to "ChessTan".)
