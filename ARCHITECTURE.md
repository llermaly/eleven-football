# Godot 11v11 Soccer — Architecture Contract

This document is the binding contract for all modules. Node paths, autoload names,
RPC signatures, and constants defined here must not drift.

## Topology

- **Dedicated server** (Godot headless, `--server` arg or `dedicated_server` feature):
  runs ALL simulation — player movement, ball physics, AI, match rules.
- **Clients** (browser HTML5 export, or native for testing): send inputs, render
  interpolated snapshots ~100 ms behind server time.
- Transport: `WebSocketMultiplayerPeer`. Server listens on port **9080**.
  Web client connects to `wss://<host>/ws` (or `ws://` when page is http);
  native client defaults to `ws://127.0.0.1:9080`, overridable with `--connect=URL`.

## Project layout (`game/` is the Godot project root)

```
game/
  project.godot
  main.tscn                  # root Node with main.gd only — everything else is code-built
  scripts/
    constants.gd             # class_name C — all tunables (field dims, physics, speeds)
    main.gd                  # boot: parse args/URL, server|client init, owns UI flow
    net.gd                   # autoload "Net" — connection, lobby, RPCs, snapshots
    match_state.gd           # autoload "MatchState" — score, clock, phase (replicated)
    world_builder.gd         # builds field, goals, stadium, lighting (pure geometry)
    ball.gd                  # RigidBody3D custom integrator: drag, Magnus, rolling
    player.gd                # CharacterBody3D: movement, kick/pass/tackle (server sim)
    player_visual.gd         # client-side body mesh build + procedural animation
    ai.gd                    # outfield AI brain (per-player, server only)
    keeper_ai.gd             # goalkeeper AI (server only)
    match_manager.gd         # rules: kickoff, goals, out-of-play restarts, halves
    team_setup.gd            # formations (4-4-2), kit colors, spawn positions
    camera_rig.gd            # broadcast telecam following ball
    hud.gd                   # scoreboard, clock, power bar, messages, indicator
    menu.gd                  # main menu: name, join/solo, status
    snapshot_buffer.gd       # client interpolation buffer
```

## Autoloads

- `Net` → `res://scripts/net.gd` (Node). High-level multiplayer root for RPCs.
- `MatchState` → `res://scripts/match_state.gd` (Node).

## Simulation/replication

- Physics: 60 Hz on server. Snapshots broadcast at 20 Hz (every 3rd tick), unreliable.
- Snapshot payload (PackedFloat32Array + small dict): ball pos/vel/quat/angvel,
  22 × (pos, yaw, anim_id, flags), possession index, server tick.
- Client input → server at 30 Hz unreliable: `move:Vector2`, `buttons:int` bitmask.
  Discrete actions (kick release with charge, switch) → reliable RPC.
- Events (goal, restart, phase change, chat) → reliable RPC from server.

## Player identity

- Server is peer 1, never plays. Humans: first joiner → team HOME(0), second → AWAY(1),
  later joiners alternate. Each human "possesses" exactly one of his team's 11 players
  at a time (auto-switch to best candidate or manual switch key). All non-possessed
  players are AI-driven on the server.

## Units & realism constants (see constants.gd)

- Field 105 × 68 m, goal 7.32 × 2.44 m. Ball r=0.11 m, m=0.43 kg.
- Drag Cd 0.25, air ρ 1.225, Magnus via spin parameter, restitution 0.62 on grass.
- Sprint 8.2 m/s, jog 5.8 m/s, accel 14 m/s². Pass 14–20 m/s, shot 22–34 m/s.

## Match rules implemented

Kickoff, goals, halves (2 × 5 min default, switch ends), throw-ins, corner kicks,
goal kicks (all simplified: ball + nearest taker repositioned, brief untouchable
window for opponents). No offside, no fouls (documented choice for playability).

## Controls (web)

WASD/arrows move · Shift sprint · Space shoot (hold = power, Magnus curve from
lateral movement at release) · E ground pass · Q lofted pass/cross · F slide tackle
· C switch player. Mouse not required.

## Deploy

- `web/` nginx: serves exported HTML5 + `location /ws` proxy_pass to game server :9080.
- `server/` Dockerfile: Godot linux headless + game .pck, runs `--headless -- --server`.
- One Coolify docker-compose app, single domain ⇒ same-origin `wss://host/ws`.
