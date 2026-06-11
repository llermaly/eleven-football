class_name C
extends Object
## Shared tunables and enums. Single source of truth — see ARCHITECTURE.md.
## Coordinates: x along field length [-52.5, 52.5], z across width [-34, 34], y up.
## Team 0 (HOME) attacks +x in first half; team 1 (AWAY) attacks -x.

# ---------- Network ----------
const SERVER_PORT := 9080
const SNAPSHOT_EVERY_N_TICKS := 3        # 60 Hz physics -> 20 Hz snapshots
const INPUT_EVERY_N_TICKS := 2           # client sends input at 30 Hz
const INTERP_DELAY := 0.12               # client renders this far behind server time
const DEFAULT_WS_URL := "ws://127.0.0.1:9080"

# ---------- Field (FIFA standard, meters) ----------
const FIELD_LENGTH := 105.0
const FIELD_WIDTH := 68.0
const HALF_LEN := 52.5
const HALF_WID := 34.0
const GOAL_WIDTH := 7.32
const GOAL_HEIGHT := 2.44
const GOAL_DEPTH := 2.2
const POST_RADIUS := 0.06
const PENALTY_BOX_DEPTH := 16.5
const PENALTY_BOX_WIDTH := 40.32
const SIX_BOX_DEPTH := 5.5
const SIX_BOX_WIDTH := 18.32
const CENTER_CIRCLE_R := 9.15
const PENALTY_SPOT := 11.0
const CORNER_ARC_R := 1.0
const LINE_WIDTH := 0.12
const OUT_MARGIN := 0.0                  # ball out when |z| > HALF_WID or |x| > HALF_LEN

# ---------- Ball physics ----------
const BALL_RADIUS := 0.11
const BALL_MASS := 0.43
const AIR_DENSITY := 1.225
const BALL_DRAG_CD := 0.25
const BALL_AREA := 0.0380                # pi * r^2
const MAGNUS_COEF := 0.0026              # F = MAGNUS_COEF * (w x v), tuned vs lit.
const MAGNUS_MAX_ACCEL := 14.0           # clamp m/s^2
const BALL_BOUNCE := 0.62                # restitution on dry grass
const BALL_FRICTION := 0.85
const ROLL_RESIST_DECEL := 1.15          # m/s^2 rolling deceleration on grass
const GROUND_ANGULAR_DAMP := 1.4
const AIR_ANGULAR_DAMP := 0.12
const SPIN_MAX := 75.0                   # rad/s cap

# ---------- Player movement ----------
const SPRINT_SPEED := 8.2
const JOG_SPEED := 5.8
const CARRY_SPEED_FACTOR := 0.88         # dribbling slows you down
const ACCEL := 14.0
const DECEL := 18.0
const TURN_RATE := 9.0                   # rad/s facing slew
const PLAYER_RADIUS := 0.35
const PLAYER_HEIGHT := 1.80
const SLIDE_SPEED := 8.8
const SLIDE_DURATION := 0.55
const SLIDE_COOLDOWN := 1.6
const SLIDE_REACH := 1.35
const KICK_RANGE := 1.18                 # ball reachable for kicks
const CONTROL_RADIUS := 0.95             # "in possession" radius
const DRIBBLE_PUSH := 3.2                # m/s relative touch speed ahead
const DRIBBLE_AHEAD := 0.55              # meters ahead of feet for touches

# ---------- Kicks (speeds m/s) ----------
const PASS_SPEED_MIN := 9.0
const PASS_SPEED_MAX := 19.0
const LOB_SPEED_MIN := 12.0
const LOB_SPEED_MAX := 22.0
const SHOT_SPEED_MIN := 17.0
const SHOT_SPEED_MAX := 33.0
const SHOT_CHARGE_TIME := 0.9            # seconds hold for full power
const KEEPER_THROW_SPEED := 14.0
const GOAL_KICK_SPEED := 26.0

# ---------- Match ----------
const HALF_LENGTH_SECONDS := 300.0       # 5 min per half
const KICKOFF_COUNTDOWN := 3.0
const GOAL_CELEBRATION_TIME := 5.0
const RESTART_UNTOUCHABLE_TIME := 1.2    # opponents can't take freshly placed ball
const RESTART_AUTO_TIMEOUT := 6.0        # AI/human must take restart within this
const HALF_TIME_PAUSE := 6.0
const FULL_TIME_PAUSE := 12.0

# ---------- Enums ----------
enum Phase { LOBBY, COUNTDOWN, KICKOFF, PLAY, GOAL_CELEBRATION, RESTART, HALF_TIME, FULL_TIME }
enum Anim { IDLE, RUN, KICK, SLIDE, DIVE, CELEBRATE, FALL }
enum Restart { NONE, THROW_IN, CORNER, GOAL_KICK }
enum Role { GK, DEF, MID, FWD }

# Input button bitmask (client -> server, held state)
const BTN_SPRINT := 1
const BTN_CHARGE := 2                    # shoot button held (charging)

# Discrete action kinds (client -> server, reliable)
enum Action { PASS, LOB, SHOOT, TACKLE, SWITCH, RESET }

# Server -> client event kinds
enum Event { GOAL, PHASE, RESTART_INFO, KICK_SFX, WHISTLE, CONTROL, ROSTER, BOUNCE }

# ---------- Teams / kits ----------
const TEAM_NAMES := ["ROJO FC", "AZUL UTD"]
const KITS := [
	{ "shirt": Color(0.82, 0.10, 0.12), "shorts": Color(0.96, 0.96, 0.96),
	  "socks": Color(0.72, 0.09, 0.10), "gk_shirt": Color(0.10, 0.75, 0.30),
	  "gk_shorts": Color(0.07, 0.07, 0.07) },
	{ "shirt": Color(0.12, 0.25, 0.85), "shorts": Color(0.95, 0.95, 0.98),
	  "socks": Color(0.10, 0.20, 0.70), "gk_shirt": Color(0.95, 0.55, 0.10),
	  "gk_shorts": Color(0.07, 0.07, 0.07) },
]
const SKIN_TONES := [
	Color(0.95, 0.78, 0.64), Color(0.87, 0.65, 0.48), Color(0.72, 0.50, 0.35),
	Color(0.55, 0.36, 0.25), Color(0.42, 0.27, 0.18),
]

# 4-4-2: position name, jersey number, role, anchor (x toward own goal negative, z)
# Defined for a team attacking +x; mirror x*attack_dir at runtime.
const FORMATION := [
	{ "name": "GK",  "num": 1,  "role": Role.GK,  "x": -50.0, "z": 0.0 },
	{ "name": "RB",  "num": 2,  "role": Role.DEF, "x": -35.0, "z": -22.0 },
	{ "name": "RCB", "num": 4,  "role": Role.DEF, "x": -38.0, "z": -7.5 },
	{ "name": "LCB", "num": 5,  "role": Role.DEF, "x": -38.0, "z": 7.5 },
	{ "name": "LB",  "num": 3,  "role": Role.DEF, "x": -35.0, "z": 22.0 },
	{ "name": "RM",  "num": 7,  "role": Role.MID, "x": -14.0, "z": -25.0 },
	{ "name": "RCM", "num": 8,  "role": Role.MID, "x": -17.0, "z": -8.0 },
	{ "name": "LCM", "num": 6,  "role": Role.MID, "x": -17.0, "z": 8.0 },
	{ "name": "LM",  "num": 11, "role": Role.MID, "x": -14.0, "z": 25.0 },
	{ "name": "RS",  "num": 9,  "role": Role.FWD, "x": 4.0,  "z": -9.0 },
	{ "name": "LS",  "num": 10, "role": Role.FWD, "x": 4.0,  "z": 9.0 },
]

const SQUAD_NAMES := [
	["Bravo", "Medel", "Diaz", "Vidal", "Mena", "Aranguiz", "Pulgar", "Valdivia",
	 "Sanchez", "Vargas", "Fernandez"],
	["Muslera", "Varela", "Gimenez", "Godin", "Caceres", "Nandez", "Vecino",
	 "Bentancur", "De Arrascaeta", "Suarez", "Cavani"],
]

static func anim_name(a: int) -> String:
	return ["idle", "run", "kick", "slide", "dive", "celebrate", "fall"][clampi(a, 0, 6)]
