# Module Interfaces (binding — integration depends on exact signatures)

Godot **4.6** GDScript. No `.tscn` files — every module builds its nodes in code.
All modules may read `C` (constants.gd, class_name C) — never redefine its values.
Modules must be self-contained: no references to autoloads or other modules except
where stated. Must run clean on first parse (no editor). Use only built-in resources
(procedural meshes/textures/materials) — no external asset files except sfx wavs.

## world_builder.gd — `class_name WorldBuilder`
Static functions only:
- `static func build_visual_world(parent: Node3D) -> void` — client. Pitch plane with
  procedurally painted grass texture (mowing stripes + ALL standard markings: touch
  lines, halfway line, center circle + spot, penalty boxes, six-yard boxes, penalty
  spots, penalty arcs, corner arcs — exact dims from C, white 0.12 m lines), both
  goals (white posts/crossbar cylinders + translucent net mesh), simple but handsome
  stadium: 4 stands with procedural crowd texture, floodlight towers (emissive),
  ad boards ringing pitch, WorldEnvironment (procedural sky, ambient, tonemap,
  subtle glow ok), DirectionalLight3D with shadows.
- `static func build_collision_world(parent: Node3D) -> void` — server. No meshes.
  StaticBody3D ground (friction 0.85, bounce 0), goal posts/crossbars colliders,
  net catch boxes (back/sides/top behind goal line so ball rests in net), invisible
  perimeter walls 8 m outside the pitch and a ceiling at 30 m (out-of-play backstop).
  Ground top surface at exactly y=0.
- `static func build_ball_visual(parent: Node3D) -> Node3D` — returns a Node3D holding
  a 0.11 m radius sphere mesh with procedural black/white panel texture; caller moves
  and rotates the returned node.

## player_visual.gd — `class_name PlayerVisual extends Node3D`
- `func setup(team: int, number: int, pname: String, is_keeper: bool) -> void`
  Builds a low-poly-but-nice humanoid from primitive meshes: head (skin tone from
  C.SKIN_TONES picked deterministically by number), torso jersey, shorts, socks/boots,
  arms, legs as separate nodes so they can animate. Kit colors from C.KITS
  (gk_* colors when is_keeper). A Label3D above head: jersey number + name (billboard,
  fixed-ish size, only visible < 45 m). Feet on y=0 when node.position.y = 0.
- `func apply_state(yaw: float, speed: float, anim: int, anim_t: float) -> void`
  Called every frame AFTER the parent sets position. Procedural animation:
  run cycle (leg/arm swing scaled by speed, slight forward lean), idle sway,
  kick (right leg swing, anim_t 0..1), slide (body low + leg extended), dive
  (keeper horizontal stretch), celebrate (arms up jump). Smooth pose blending.
- `func set_highlight(on: bool, color: Color) -> void` — ring/triangle marker under/
  above the controlled player.

## hud.gd — `class_name Hud extends CanvasLayer`
Builds all controls in `_ready`. Reads/connects NOTHING external; main.gd calls:
- `func set_teams(home: String, away: String, home_col: Color, away_col: Color)`
- `func set_score(home: int, away: int)`
- `func set_clock(seconds: float, half: int)` — render "MM:SS · 1ST/2ND"
- `func set_charge(v: float)` — shot power bar 0..1; v < 0 hides it
- `func show_message(text: String, seconds: float)` — big center text (GOAL!, etc.)
- `func set_status(text: String)` — small corner connection status
- `func set_hint(text: String)` — bottom controls hint line
Style: broadcast-TV scoreboard top-left (team color chips, semi-transparent dark
panel, clean white type), no mouse interaction (mouse_filter IGNORE everywhere).

## menu.gd — `class_name GameMenu extends CanvasLayer`
Builds in `_ready`. Emits `signal join_pressed(player_name: String, url: String)`.
- Centered card: game title, name LineEdit (random default like "Player742"),
  server URL LineEdit (visible only when NOT web export — check
  `OS.has_feature("web")`; default C.DEFAULT_WS_URL), big JOIN MATCH button,
  status Label, controls cheat-sheet. Background: full-screen dark green gradient.
- `func set_status(text: String) -> void`
- `func set_busy(b: bool) -> void` — disables button while connecting.

## camera_rig.gd — `class_name CameraRig extends Node3D`
Owns a Camera3D child (current). Broadcast telecam on the -z sideline, ~17 m high,
~26 m back, fov ~33, looks at a point blended between ball and field center, follows
ball x with smoothing + velocity lead, gentle zoom (closer near goals). API:
- `func setup(parent_viewport_world: Node3D) -> void` (adds itself, makes current)
- `func track(ball_pos: Vector3, ball_vel: Vector3, delta: float) -> void`
- `func goal_mode(focus: Vector3) -> void` / `func normal_mode() -> void`

## sfx.gd — `class_name Sfx extends Node` (+ generator script)
A standalone generator (GDScript tool or Python) creates small WAVs under
game/assets/sfx/: kick (low thump), whistle (referee, single + double + long),
crowd loop (stadium ambience), cheer (goal roar swell), bounce (soft thud).
sfx.gd loads them; API: `play_kick(strength: float)`, `play_whistle(kind: int)`
(0 single, 1 double, 2 long), `play_cheer()`, `play_bounce(strength: float)`,
`start_crowd()`. 3D positioning unnecessary — stereo is fine. Keep volumes sane.

## Integration notes
- main.gd (NOT yours) instantiates these and drives them; signatures above must match.
- Use StandardMaterial3D; vertex colors fine. Target: looks good at 1280×720 web.
- Performance: web export, GL Compatibility renderer, 22 players visible — keep
  per-player mesh count modest (≤ 12 MeshInstances) and reuse shared materials/meshes
  via static caches where easy.
