FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget unzip \
        libfontconfig1 libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 \
        libgl1 libdbus-1-3 libasound2 libpulse0 libudev1 libxkbcommon0 \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q https://github.com/godotengine/godot/releases/download/4.6.3-stable/Godot_v4.6.3-stable_linux.x86_64.zip \
        -O /tmp/godot.zip \
    && unzip -q /tmp/godot.zip -d /opt \
    && mv /opt/Godot_v4.6.3-stable_linux.x86_64 /opt/godot \
    && chmod +x /opt/godot \
    && rm /tmp/godot.zip

COPY eleven.pck /app/eleven.pck

EXPOSE 9080
CMD ["/opt/godot", "--headless", "--main-pack", "/app/eleven.pck", "--", "--server"]
