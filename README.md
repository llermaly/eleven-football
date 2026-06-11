# Eleven Football ⚽

Realistic 3D 11v11 soccer for the browser, built with Godot 4.6. Server-authoritative
multiplayer over WebSocket: a headless Godot dedicated server simulates everything
(real ball aerodynamics — quadratic drag, Magnus curve, grass restitution and rolling
resistance — player locomotion, goalkeeper and outfield AI, full match rules), while
browser clients send inputs and render interpolated 20 Hz snapshots.

## Play

Open the deployed URL, enter a name, JOIN MATCH. First player gets ROJO FC, second
gets AZUL UTD; everyone controls one player at a time (FIFA-style) and AI runs the
rest. Share `?join=YourName` links to skip the menu.

**Controls:** WASD/arrows move · SHIFT sprint · SPACE shoot (hold for power; sideways
movement at release curls it) · E ground pass · Q lofted pass/cross · F slide tackle ·
C switch player · R rematch.

## Repo layout

- `game/` — the Godot 4.6 project (everything procedural: pitch, stadium, players, SFX)
- `web/` — nginx image: serves the exported HTML5 build, proxies `/ws` to the server
- `server/` — Debian image: official Godot binary + exported `.pck`, runs `--headless -- --server`
- `docker-compose.yml` — the two services; point a domain at `web:80`

## Build locally

```bash
godot --headless --path game --export-release Web ../build/web/index.html
godot --headless --path game --export-pack LinuxServer ../build/server/eleven.pck
cp -r build/web/* web/public/ && cp build/server/eleven.pck server/
docker compose up --build
# open http://localhost:8080 (map web:80 as you like)
```

Dev loop without Docker:

```bash
godot --headless --path game -- --server             # dedicated server :9080
godot --path game                                     # native client, menu URL ws://127.0.0.1:9080
godot --headless --path game -- --server --smoke=120 --timescale=8   # AI-only sim test
```
