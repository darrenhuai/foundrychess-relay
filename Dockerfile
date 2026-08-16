# Runs the relay server headless -- downloads the official Godot Linux
# binary at build time rather than shipping one, since the relay is
# platform-agnostic and this keeps the repo itself binary-free.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

ARG GODOT_VERSION=4.7.1-stable
RUN curl -fL -o /tmp/godot.zip \
        "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" \
    && unzip -q /tmp/godot.zip -d /tmp/godot_extracted \
    && mv /tmp/godot_extracted/Godot_v${GODOT_VERSION}_linux.x86_64 /usr/local/bin/godot4 \
    && chmod +x /usr/local/bin/godot4 \
    && rm -rf /tmp/godot.zip /tmp/godot_extracted

WORKDIR /app
COPY project.godot relay_server.gd ./

EXPOSE 8910
# Render (and some other hosts) assign the listen port dynamically via $PORT
# rather than a fixed one -- fall back to 8910 when it's unset (local runs)
# so the same image works both in production and on a dev machine.
CMD ["/bin/sh", "-c", "godot4 --headless --path /app -s relay_server.gd --port=${PORT:-8910}"]
