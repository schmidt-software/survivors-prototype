## Survivors-like prototype: the whole game lives in this single script.
##
## Gameplay loop: the player moves around while a weapon fires automatically at the
## nearest enemy. Enemies spawn in ever-growing waves, drop XP gems, and collecting
## enough XP triggers a level-up where the player picks one of three random upgrades.
## When HP reaches zero the run ends; a qualifying score is stored in a local top-10
## list after the player enters a name.
##
## Controls: WASD / arrow keys / gamepad, or touch / mouse drag (floating virtual
## joystick that appears where the finger first touches the screen).
##
## Architecture notes:
## - No external assets: gameplay is rendered through [method _draw], while menu
##   and name-entry forms use Control nodes for layout, scrolling and text input.
## - Entities (enemies, bullets, gems) are plain Dictionaries kept in Arrays instead
##   of nodes. That keeps hundreds of entities cheap, at the cost of manual collision
##   handling (see [method _update]).
## - The game is a small state machine, see [member state].
## - Starting or leaving a run is done by reloading the scene, which resets all
##   per-run variables. Data that must survive a reload lives in [code]static[/code]
##   variables.
extends Node2D

## Collision radius of the player in pixels.
const PLAYER_RADIUS := 14.0
## Hard cap on simultaneous enemies; protects performance on weak mobile devices.
const MAX_ENEMIES := 400
## Where the highscore list is persisted. On the web export [code]user://[/code]
## maps to the browser's IndexedDB, so the list is per browser and device.
const SCORE_FILE := "user://highscores.json"
## Number of entries kept in the highscore list.
const MAX_SCORES := 10

## Pool of upgrades offered on level-up. [code]key[/code] is handled in
## [method _apply_upgrade]; [code]name[/code] and [code]desc[/code] are shown on the
## level-up cards.
const UPGRADES := [
	{"name": "Mehr Schaden", "desc": "+30% Schaden", "key": "dmg"},
	{"name": "Schnellfeuer", "desc": "+25% Feuerrate", "key": "rate"},
	{"name": "Zusatzprojektil", "desc": "+1 Projektil", "key": "count"},
	{"name": "Tempo", "desc": "+15% Bewegung", "key": "speed"},
	{"name": "Magnet", "desc": "+50% Aufsammelradius", "key": "magnet"},
	{"name": "Lebenskraft", "desc": "+25 Max-HP, voll heilen", "key": "hp"},
]

## State to start the next run in. Static so it survives
## [method SceneTree.reload_current_scene]; consumed (and reset to "menu") in
## [method _ready].
static var pending_state := "menu"
## Score of the most recently finished run, or -1 if none yet. Static so the menu
## can show and highlight it after the reload.
static var last_score := -1

## Current game state:
## [br]- [code]menu[/code]: start screen with the highscore list.
## [br]- [code]play[/code]: normal gameplay, [method _update] runs every frame.
## [br]- [code]levelup[/code]: gameplay is paused while the player picks an upgrade.
## [br]- [code]dead[/code]: game-over screen; input is ignored for a short delay.
## [br]- [code]name[/code]: name entry for a new highscore (uses Control nodes).
var state := "menu"

# --- Player stats (all of these are modified by upgrades) ---
## World position of the player. The camera follows it, so the world is endless.
var player_pos := Vector2.ZERO
var hp := 100.0
var max_hp := 100.0
## Movement speed in pixels per second.
var speed := 220.0
## Shots per second.
var fire_rate := 1.0
## Damage dealt by one projectile hit.
var damage := 10.0
## Number of projectiles per shot (fanned out around the aim direction).
var proj_count := 1
## Radius in which XP gems are pulled toward the player.
var pickup_range := 80.0

# --- Progression ---
var xp := 0.0
var level := 1
## XP required for the next level; grows by roughly 35% per level.
var xp_needed := 5.0

# --- Run bookkeeping ---
## Seconds survived in the current run (only advances in the [code]play[/code] state).
var time_alive := 0.0
## Seconds since death; delays the "continue" input so a stray tap doesn't skip it.
var time_dead := 0.0
var kills := 0
## Accumulates scaled time; every 0.5 units spawns one enemy.
var spawn_acc := 0.0
## Accumulates [code]delta * fire_rate[/code]; a shot is fired when it reaches 1.
var fire_acc := 0.0

# --- Highscores ---
## Sorted (descending) list of [code]{name: String, score: int}[/code].
var scores: Array = []
## Final score of the finished run: [code]kills * 10 + seconds survived[/code].
var score := 0
## Whether [member score] makes it into the top-10 list.
var qualifies := false
var name_edit: LineEdit
var ui_layer: CanvasLayer
## Menu controls stay in screen space; containers handle resizing and scrolling.
var menu_title: Label
var menu_margin: MarginContainer
var menu_subtitle: Label
var menu_scroll: ScrollContainer
var menu_last_score: Label
var menu_start_button: Button

# --- Entities (Dictionaries; see the spawn functions for the exact fields) ---
## Enemy: [code]{pos, hp, speed, r (radius), dmg (damage per second on contact), kind}[/code].
var enemies: Array = []
## Projectile: [code]{pos, vel, life (seconds left), hit (enemies already hit)}[/code].
var bullets: Array = []
## XP gem: [code]{pos}[/code]; gets a [code]taken[/code] key once collected.
var gems: Array = []
## The three upgrades currently offered on the level-up screen.
var choices: Array = []
## Focused level-up card for controller navigation.
var selected_choice := 0
## Requires the horizontal stick to return to neutral before moving focus again.
var choice_axis_held := false

# --- Touch joystick ---
## Index of the finger driving the virtual joystick, or -1 if none.
var touch_id := -1
## Screen position where the joystick finger first touched down.
var stick_origin := Vector2.ZERO
## Joystick deflection, length clamped to 0..1.
var stick_vec := Vector2.ZERO
var cam: Camera2D


func _ready() -> void:
	cam = Camera2D.new()
	add_child(cam)
	randomize()
	scores = _load_scores()
	state = pending_state
	pending_state = "menu"
	if state == "menu":
		_build_menu()


# ---------------------------------------------------------------------------
# Highscores
# ---------------------------------------------------------------------------

## Reads and normalizes the persisted leaderboard. A missing file is expected on
## first launch; unreadable or malformed existing data is reported explicitly.
func _load_scores() -> Array:
	if not FileAccess.file_exists(SCORE_FILE):
		return []
	var file := FileAccess.open(SCORE_FILE, FileAccess.READ)
	if file == null:
		push_error("Cannot read highscores: %s" % error_string(FileAccess.get_open_error()))
		return []
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	if error != OK:
		push_warning("Invalid highscore JSON: %s" % json.get_error_message())
		return []
	return _normalize_scores(json.data)


## Keep only named, positive integer scores, sorted descending and limited to ten.
## JSON represents numbers as floats, so integral floats are accepted too. Reject
## non-finite, fractional or out-of-range values before converting them to int.
func _normalize_scores(data: Variant) -> Array:
	var out: Array = []
	if not data is Array:
		push_warning("Highscores must be a JSON array.")
		return out
	var rejected := 0
	for entry in data:
		if not entry is Dictionary or not entry.get("name") is String:
			rejected += 1
			continue
		var value: Variant = entry.get("score")
		if not (value is int or value is float):
			rejected += 1
			continue
		if value <= 0 or (value is float and (
				not is_finite(value) or value != floorf(value) or value >= 9223372036854775808.0)):
			rejected += 1
			continue
		var player_name: String = entry.name.strip_edges().left(12)
		if player_name.is_empty():
			player_name = "Anonym"
		out.append({"name": player_name, "score": int(value)})
	if rejected > 0:
		push_warning("Skipped %d invalid highscore entries." % rejected)
	out.sort_custom(func(a, b): return a.score > b.score)
	return out.slice(0, MAX_SCORES)


## Writes the current [member scores] list to disk as JSON.
func _save_scores() -> void:
	var f := FileAccess.open(SCORE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(scores))


## A positive score qualifies if fewer than ten existing entries rank at least
## as high. This does not rely on the order or length of the in-memory array.
## Ties do not displace an existing entry when the leaderboard is full.
func _qualifies(sc: int) -> bool:
	if sc <= 0:
		return false
	var ahead := 0
	for entry in scores:
		if entry.score >= sc:
			ahead += 1
	return ahead < MAX_SCORES


## Inserts the current [member score] under [param player_name], keeps the list
## sorted and trimmed to [constant MAX_SCORES], and persists it.
func _add_score(player_name: String) -> void:
	scores.append({"name": player_name, "score": score})
	scores = _normalize_scores(scores)
	_save_scores()


# ---------------------------------------------------------------------------
# State transitions and name entry
# ---------------------------------------------------------------------------

## Reloads the scene so that all per-run variables are reset, and starts the new
## scene instance in state [param next] (via [member pending_state]).
func _go(next: String) -> void:
	pending_state = next
	get_tree().reload_current_scene()


## True for a touch, non-repeating key press, or controller confirm (A / Cross).
## Mouse clicks arrive as touches because of the project setting
## [code]emulate_touch_from_mouse[/code].
func _is_press(event: InputEvent) -> bool:
	return (event is InputEventScreenTouch and event.pressed) \
		or (event is InputEventKey and event.pressed and not event.echo) \
		or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_A)


## Handle controller submission before the focused LineEdit consumes UI actions.
## A blank name still uses the existing "Anonym" fallback.
func _input(event: InputEvent) -> void:
	if state == "name" and event is InputEventJoypadButton \
			and event.pressed and event.button_index == JOY_BUTTON_A:
		_submit_name()
		get_viewport().set_input_as_handled()


## Switches to the [code]name[/code] state and builds the name-entry UI from code:
## a centered column with a title label, a [LineEdit] (max. 12 characters) and a
## save button. A real [LineEdit] is used so that the virtual keyboard appears on
## mobile browsers.
func _open_name_entry() -> void:
	state = "name"
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_layer.add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(320, 0)
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	var title := Label.new()
	title.text = "NEUER HIGHSCORE: %d\nGib deinen Namen ein:" % score
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)
	name_edit = LineEdit.new()
	name_edit.max_length = 12
	name_edit.placeholder_text = "Name"
	name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_edit.add_theme_font_size_override("font_size", 28)
	name_edit.text_submitted.connect(func(_t): _submit_name())
	box.add_child(name_edit)
	var ok := Button.new()
	ok.text = "Speichern"
	ok.add_theme_font_size_override("font_size", 24)
	ok.pressed.connect(_submit_name)
	box.add_child(ok)
	# Deferred: the node must be inside the tree before it can take focus.
	name_edit.grab_focus.call_deferred()


## Stores the entered name (empty becomes "Anonym") with the current score and
## returns to the menu.
func _submit_name() -> void:
	var n := name_edit.text.strip_edges()
	if n.is_empty():
		n = "Anonym"
	_add_score(n)
	last_score = score
	_go("menu")


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

## Central input dispatcher; behaviour depends on [member state].
## [br]- [code]name[/code]: ignored, the Control nodes handle their own input.
## [br]- [code]menu[/code]: Enter / Space / controller A starts a run. Pointer
## input is handled by the start button, leaving the leaderboard free to scroll.
## [br]- [code]dead[/code]: after 0.8 s a press continues to name entry or the menu.
## [br]- [code]levelup[/code]: forwarded to [method _handle_choice_input].
## [br]- [code]play[/code]: touch events drive the floating virtual joystick.
## Keyboard and gamepad movement is polled in [method _move_input] instead.
func _unhandled_input(event: InputEvent) -> void:
	if state == "name":
		return
	if state == "menu":
		if _is_press(event) and (
				event is InputEventJoypadButton or (
				event is InputEventKey and event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE])):
			_go("play")
		return
	if state == "dead":
		if _is_press(event) and time_dead > 0.8:
			if qualifies:
				_open_name_entry()
			else:
				last_score = score
				_go("menu")
		return
	if state == "levelup":
		_handle_choice_input(event)
		return
	if event is InputEventScreenTouch:
		# Only the first finger controls the joystick; later fingers are ignored.
		if event.pressed and touch_id == -1:
			touch_id = event.index
			stick_origin = event.position
			stick_vec = Vector2.ZERO
		elif not event.pressed and event.index == touch_id:
			touch_id = -1
			stick_vec = Vector2.ZERO
	elif event is InputEventScreenDrag and event.index == touch_id:
		# 80 px of drag equals full deflection.
		stick_vec = ((event.position - stick_origin) / 80.0).limit_length(1.0)


## Keys 1-3 and taps select directly. A controller navigates with D-pad left/right
## or the left stick, then confirms with A / Cross. Stick hysteresis avoids rapid
## repeated navigation from multiple motion events near the deadzone.
func _handle_choice_input(event: InputEvent) -> void:
	var idx := -1
	if choices.is_empty():
		return
	if event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_DPAD_LEFT:
				selected_choice = wrapi(selected_choice - 1, 0, choices.size())
			JOY_BUTTON_DPAD_RIGHT:
				selected_choice = wrapi(selected_choice + 1, 0, choices.size())
			JOY_BUTTON_A:
				idx = selected_choice
	elif event is InputEventJoypadMotion and event.axis == JOY_AXIS_LEFT_X:
		if absf(event.axis_value) < 0.25:
			choice_axis_held = false
		elif absf(event.axis_value) >= 0.5 and not choice_axis_held:
			selected_choice = wrapi(selected_choice + int(signf(event.axis_value)), 0, choices.size())
			choice_axis_held = true
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode >= KEY_1 and event.keycode <= KEY_3:
		idx = event.keycode - KEY_1
	elif event is InputEventScreenTouch and event.pressed:
		idx = _choice_at(event.position)
	if idx >= 0 and idx < choices.size():
		_apply_upgrade(choices[idx].key)
		state = "play"
		touch_id = -1
		stick_vec = Vector2.ZERO


## Returns the index of the level-up card under screen position [param p], or -1.
func _choice_at(p: Vector2) -> int:
	var vp := get_viewport_rect().size
	for i in choices.size():
		if _choice_rect(i, vp).has_point(p):
			return i
	return -1


## Screen-space rectangle of level-up card [param i] for viewport size [param vp].
## Three cards are centered horizontally with a 20 px gap; their width shrinks on
## narrow (portrait) screens.
func _choice_rect(i: int, vp: Vector2) -> Rect2:
	var w := minf(280.0, vp.x / 3.4)
	var total := w * 3.0 + 40.0
	return Rect2(Vector2((vp.x - total) / 2.0 + i * (w + 20.0), vp.y / 2.0 - 90.0), Vector2(w, 180.0))


## Applies the upgrade identified by [param key] (see [constant UPGRADES]).
func _apply_upgrade(key: String) -> void:
	match key:
		"dmg": damage *= 1.3
		"rate": fire_rate *= 1.25
		"count": proj_count += 1
		"speed": speed *= 1.15
		"magnet": pickup_range *= 1.5
		"hp":
			max_hp += 25.0
			hp = max_hp


## Returns the movement direction (length 0..1). Priority: WASD/arrow keys, then
## gamepad / [code]ui_*[/code] actions, then the touch joystick.
func _move_input() -> Vector2:
	var v := Vector2(
		int(Input.is_physical_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - int(Input.is_physical_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		int(Input.is_physical_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - int(Input.is_physical_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP))
	)
	if v == Vector2.ZERO:
		v = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if v == Vector2.ZERO:
		return stick_vec
	return v.limit_length(1.0)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

## Per-frame entry point: advances the simulation only while playing, keeps the
## camera centered on the player and requests a redraw.
func _process(delta: float) -> void:
	if state == "play":
		_update(delta)
	elif state == "dead":
		time_dead += delta
	cam.position = player_pos
	queue_redraw()


## Advances the simulation by [param delta] seconds. Order of operations:
## [br]1. move the player, 2. spawn enemies, 3. auto-fire, 4. move projectiles and
## resolve projectile hits, 5. move enemies, apply contact damage and turn dead
## enemies into gems, 6. soft-separate enemies, 7. attract and collect gems,
## 8. level-up check, 9. death check.
func _update(delta: float) -> void:
	time_alive += delta
	player_pos += _move_input() * speed * delta

	# The spawn rate grows with time: the accumulator advances faster the longer
	# the run lasts (+4% of base speed per second).
	spawn_acc += delta * (1.0 + time_alive / 25.0)
	while spawn_acc >= 0.5:
		spawn_acc -= 0.5
		if enemies.size() < MAX_ENEMIES:
			_spawn_enemy()

	fire_acc += delta * fire_rate
	if fire_acc >= 1.0:
		fire_acc = 0.0
		_fire()

	# Projectiles: a bullet is consumed by the first enemy it touches. The "hit"
	# list prevents the same enemy being hit twice by one bullet.
	for b in bullets:
		b.pos += b.vel * delta
		b.life -= delta
		for e in enemies:
			if e.hp > 0.0 and not b.hit.has(e) and b.pos.distance_to(e.pos) < e.r + 5.0:
				e.hp -= damage
				b.hit.append(e)
				b.life = 0.0
				break
	bullets = bullets.filter(func(b): return b.life > 0.0)

	# Enemies chase the player directly. Contact damage is dealt per second, so
	# standing in a crowd drains HP faster.
	for e in enemies:
		e.pos += (player_pos - e.pos).normalized() * e.speed * delta
		if e.pos.distance_to(player_pos) < e.r + PLAYER_RADIUS:
			hp -= e.dmg * delta
		if e.hp <= 0.0:
			kills += 1
			gems.append({"pos": e.pos})
	enemies = enemies.filter(func(e): return e.hp > 0.0)
	_separate_enemies()

	# Gems inside the pickup range accelerate toward the player; the closer, the
	# faster. A gem touching the player is collected for 1 XP.
	for g in gems:
		var d: float = g.pos.distance_to(player_pos)
		if d < pickup_range:
			g.pos = g.pos.move_toward(player_pos, (300.0 + (pickup_range - d) * 4.0) * delta)
		if d < PLAYER_RADIUS + 6.0:
			g.taken = true
			xp += 1.0
	gems = gems.filter(func(g): return not g.has("taken"))

	if xp >= xp_needed:
		xp -= xp_needed
		level += 1
		xp_needed = ceilf(xp_needed * 1.35 + 2.0)
		_open_levelup()

	if hp <= 0.0:
		hp = 0.0
		score = kills * 10 + int(time_alive)
		qualifies = _qualifies(score)
		state = "dead"


## Pushes overlapping enemies apart so they don't stack into a single blob.
## This is O(n^2), so only the first 150 enemies take part; that bounds the cost
## per frame while still looking fine.
func _separate_enemies() -> void:
	var n := mini(enemies.size(), 150)
	for i in n:
		var a = enemies[i]
		for j in range(i + 1, n):
			var b = enemies[j]
			var d: Vector2 = a.pos - b.pos
			var min_d: float = a.r + b.r
			if d != Vector2.ZERO and d.length_squared() < min_d * min_d:
				var push := d.normalized() * 0.5
				a.pos += push
				b.pos -= push


## Spawns one enemy on a circle just outside the visible screen, at a random angle.
## Difficulty scales with [code]tier = time_alive / 30[/code]:
## [br]- HP grows 25% per tier, speed grows by 4 px/s per tier (capped at +60).
## [br]- The chance of a "big" enemy is 3% per tier, capped at 25%. Big enemies have
## more HP, are slower, larger and deal double contact damage.
func _spawn_enemy() -> void:
	var radius := get_viewport_rect().size.length() / 2.0 + 40.0
	var tier := time_alive / 30.0
	var big := randf() < clampf(tier * 0.03, 0.0, 0.25)
	enemies.append({
		"pos": player_pos + Vector2.from_angle(randf() * TAU) * radius,
		"hp": (40.0 if big else 12.0) * (1.0 + tier * 0.25),
		"speed": (70.0 if big else 95.0) + minf(tier * 4.0, 60.0),
		"r": 20.0 if big else 11.0,
		"dmg": 20.0 if big else 10.0,
		"kind": 1 if big else 0,
	})


## Fires one volley at the nearest enemy (does nothing if there is none).
## With several projectiles they are fanned out symmetrically around the aim
## direction, 0.18 rad apart. Projectiles fly at 520 px/s for 1.2 s.
func _fire() -> void:
	if enemies.is_empty():
		return
	var nearest = enemies[0]
	var best := INF
	for e in enemies:
		var d: float = e.pos.distance_squared_to(player_pos)
		if d < best:
			best = d
			nearest = e
	var base: Vector2 = (nearest.pos - player_pos).normalized()
	for i in proj_count:
		var off := (i - (proj_count - 1) / 2.0) * 0.18
		bullets.append({"pos": player_pos, "vel": base.rotated(off) * 520.0, "life": 1.2, "hit": []})


## Pauses the game and offers three distinct random upgrades.
func _open_levelup() -> void:
	var pool := UPGRADES.duplicate()
	pool.shuffle()
	choices = pool.slice(0, 3)
	selected_choice = 0
	choice_axis_held = false
	state = "levelup"


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

## Draws the whole frame in world coordinates. The camera is centered on the
## player, so the visible area's top-left corner is [code]tl[/code]; screen-space
## UI is positioned relative to it. Menu and name entry get their own backdrops.
func _draw() -> void:
	var vp := get_viewport_rect().size
	var tl := player_pos - vp / 2.0

	if state == "menu":
		draw_rect(Rect2(tl, vp), Color(0.07, 0.08, 0.12))
		return

	# Endless scrolling grid: lines are snapped to multiples of the cell size so
	# they stay fixed in the world while the camera moves.
	var step := 64.0
	var gx := floorf(tl.x / step) * step
	var gy := floorf(tl.y / step) * step
	var col := Color(1, 1, 1, 0.06)
	for x in range(int(vp.x / step) + 2):
		draw_line(Vector2(gx + x * step, tl.y), Vector2(gx + x * step, tl.y + vp.y), col)
	for y in range(int(vp.y / step) + 2):
		draw_line(Vector2(tl.x, gy + y * step), Vector2(tl.x + vp.x, gy + y * step), col)

	for g in gems:
		draw_circle(g.pos, 4.0, Color(0.3, 0.8, 1.0))
	for e in enemies:
		draw_circle(e.pos, e.r, Color(0.9, 0.25, 0.3) if e.kind == 0 else Color(0.7, 0.2, 0.8))
	for b in bullets:
		draw_circle(b.pos, 5.0, Color(1.0, 0.95, 0.4))
	draw_circle(player_pos, PLAYER_RADIUS, Color(0.3, 1.0, 0.5))

	_draw_hud(tl, vp)


## Build a screen-space menu with fixed-height rows in a ScrollContainer. Unlike
## shrinking draw offsets, this preserves readable text on short viewports. The
## header and start button remain outside the scrolling region.
func _build_menu() -> void:
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	menu_margin = MarginContainer.new()
	ui_layer.add_child(menu_margin)
	menu_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		menu_margin.add_theme_constant_override("margin_" + side, 12)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	menu_margin.add_child(column)
	menu_title = Label.new()
	menu_title.text = "SURVIVORS"
	menu_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(menu_title)
	menu_subtitle = Label.new()
	menu_subtitle.text = "Bestenliste – Top %d" % MAX_SCORES
	menu_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(menu_subtitle)
	menu_scroll = ScrollContainer.new()
	menu_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	menu_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	menu_scroll.follow_focus = true
	column.add_child(menu_scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 2)
	menu_scroll.add_child(rows)
	var highlighted := false
	for i in MAX_SCORES:
		var row := HBoxContainer.new()
		row.custom_minimum_size.y = 32
		rows.add_child(row)
		var rank := Label.new()
		rank.text = "%2d." % (i + 1)
		rank.custom_minimum_size.x = 36
		row.add_child(rank)
		var player_name := Label.new()
		player_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		player_name.clip_text = true
		row.add_child(player_name)
		var points := Label.new()
		points.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(points)
		var color := Color(1, 1, 1, 0.9)
		if i < scores.size():
			if not highlighted and last_score >= 0 and scores[i].score == last_score:
				color = Color(1.0, 0.9, 0.3)
				highlighted = true
			player_name.text = scores[i].name
			points.text = str(scores[i].score)
		else:
			player_name.text = "–"
			color = Color(1, 1, 1, 0.3)
		for label in [rank, player_name, points]:
			label.add_theme_font_size_override("font_size", 22)
			label.add_theme_color_override("font_color", color)
	menu_last_score = Label.new()
	menu_last_score.text = "Letzter Score: %d" % last_score
	menu_last_score.visible = last_score >= 0
	menu_last_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_last_score.add_theme_font_size_override("font_size", 18)
	column.add_child(menu_last_score)
	menu_start_button = Button.new()
	menu_start_button.text = "Spielen (Enter / A)"
	# Keyboard/controller confirmation is handled centrally, not by UI focus.
	menu_start_button.focus_mode = Control.FOCUS_NONE
	menu_start_button.pressed.connect(_go.bind("play"))
	column.add_child(menu_start_button)
	get_viewport().size_changed.connect(_resize_menu)
	_resize_menu()


## Use a compact header on short or narrow viewports without shrinking table text.
func _resize_menu() -> void:
	var vp := get_viewport_rect().size
	var compact := vp.y < 480.0 or vp.x < 600.0
	menu_margin.add_theme_constant_override("margin_top", 8 if compact else 12)
	menu_margin.add_theme_constant_override("margin_bottom", 8 if compact else 12)
	var column: VBoxContainer = menu_margin.get_child(0)
	column.add_theme_constant_override("separation", 4 if compact else 6)
	menu_title.add_theme_font_size_override("font_size", 32 if compact else 64)
	menu_subtitle.add_theme_font_size_override("font_size", 18 if compact else 24)
	menu_start_button.add_theme_font_size_override("font_size", 20 if compact else 28)
	menu_start_button.custom_minimum_size.y = 36 if compact else 48


## Draws the HUD and the state-dependent overlays on top of the world: XP bar
## (top), HP bar (under the player), level / kills / time, the virtual joystick
## while touching, and the level-up, game-over or name-entry overlay.
## [param tl] is the top-left corner of the visible area in world coordinates.
func _draw_hud(tl: Vector2, vp: Vector2) -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(tl, Vector2(vp.x, 10)), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(tl, Vector2(vp.x * xp / xp_needed, 10)), Color(0.3, 0.8, 1.0))
	var bar := Rect2(player_pos + Vector2(-30, 24), Vector2(60, 5))
	draw_rect(bar, Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * hp / max_hp, bar.size.y)), Color(0.9, 0.2, 0.2))
	var t := int(time_alive)
	draw_string(font, tl + Vector2(12, 36), "Level %d   Kills %d   Zeit %02d:%02d" % [level, kills, t / 60, t % 60],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 22)

	# Virtual joystick: ring at the touch origin, knob at the current deflection.
	if touch_id != -1:
		var o := tl + stick_origin
		draw_arc(o, 60.0, 0.0, TAU, 32, Color(1, 1, 1, 0.3), 3.0)
		draw_circle(o + stick_vec * 60.0, 24.0, Color(1, 1, 1, 0.35))

	if state == "levelup":
		draw_rect(Rect2(tl, vp), Color(0, 0, 0, 0.6))
		draw_string(font, tl + Vector2(0, vp.y / 2.0 - 130), "LEVEL UP!", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 40)
		draw_string(font, tl + Vector2(0, vp.y / 2.0 + 140), "Controller: Links/Rechts, A zum Bestätigen", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 22)
		for i in choices.size():
			# _choice_rect() is in screen space, so shift it into world space.
			var r := _choice_rect(i, vp)
			r.position += tl
			draw_rect(r, Color(0.15, 0.17, 0.25))
			draw_rect(r, Color(1.0, 0.9, 0.3) if i == selected_choice else Color(0.5, 0.6, 1.0), false, 3.0 if i == selected_choice else 2.0)
			draw_string(font, r.position + Vector2(0, 70), "[%d] %s" % [i + 1, choices[i].name], HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 22)
			draw_string(font, r.position + Vector2(0, 110), choices[i].desc, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 18)
	elif state == "dead":
		draw_rect(Rect2(tl, vp), Color(0.2, 0, 0, 0.65))
		draw_string(font, tl + Vector2(0, vp.y / 2.0 - 20), "GAME OVER", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 48)
		draw_string(font, tl + Vector2(0, vp.y / 2.0 + 30), "Score: %d" % score, HORIZONTAL_ALIGNMENT_CENTER, vp.x, 28)
		if time_dead > 0.8:
			draw_string(font, tl + Vector2(0, vp.y / 2.0 + 75), "Taste / Tippen / A zum Fortfahren", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 22)
	elif state == "name":
		# Backdrop only; the entry form is made of Control nodes on a CanvasLayer.
		draw_rect(Rect2(tl, vp), Color(0.07, 0.08, 0.12, 0.92))
