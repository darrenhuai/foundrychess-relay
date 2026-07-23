# Foundry Chess Relay

Tiny standalone matchmaking/relay server for [Foundry Chess](https://github.com/darrenhuai/foundrychess-web)'s
2-player online mode. Foundry Chess runs as a Discord Activity, and this is
the server the two clients connect to so they can find each other and pass
moves back and forth.

It's deliberately game-unaware: it only knows how to hand out a room code,
pair up whoever joins with that code, and forward whatever bytes one side
sends to the other. The actual game protocol can change freely without ever
touching this repo.

## How it works

1. One player's client connects and sends `{"type": "host"}`.
2. The server generates a 5-character room code (no `0`/`O`/`1`/`I`/`L`, so
   it's easy to read out loud on a call) and sends it back.
3. The second player sends `{"type": "join", "code": "..."}`. Once both
   sides are connected, each gets `{"type": "paired"}`.
4. From then on, either side sends `{"type": "relay", "payload": ...}` and
   the server forwards `payload` straight to the other peer, untouched.
5. If either side disconnects, the other gets `{"type": "peer_left"}` and
   the room is torn down.

That's the whole protocol — one file, `relay_server.gd`, running headless
under Godot.

## Running locally

```bash
godot4 --headless --path . -s relay_server.gd --port=8910
```

Requires Godot 4.7+. `--port` is optional and defaults to `8910`.

## Deploying

```bash
docker build -t foundrychess-relay .
docker run -p 8910:8910 foundrychess-relay
```

The Docker image downloads the official Godot Linux binary at build time
rather than shipping one, so the repo itself stays binary-free.

It reads `$PORT` at startup (falling back to `8910`), so the same image
works unmodified on hosts that assign the port dynamically (Render) or ones
that use a fixed internal port (Fly.io).

## Related

- [foundrychess-web](https://github.com/darrenhuai/foundrychess-web) — the
  game itself, built for Discord Activity hosting.
