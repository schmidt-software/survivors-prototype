extends Node2D
# Survivors-like prototype: auto-attack, waves, XP, level-up choices.
# Controls: WASD/arrows/gamepad, or touch/mouse drag (floating virtual joystick).

const PLAYER_RADIUS := 14.0
const MAX_ENEMIES := 400

var player_pos := Vector2.ZERO
var hp := 100.0
var max_hp := 100.0
var speed := 220.0
var fire_rate := 1.0
var damage := 10.0
var proj_count := 1
var pickup_range := 80.0
var xp := 0.0
var level := 1
var xp_needed := 5.0
var time_alive := 0.0
var spawn_acc := 0.0
var fire_acc := 0.0
var kills := 0
var time_dead := 0.0
var state := "menu"  # menu | play | levelup | dead | name

# Survives scene reloads: which state the next run starts in, and the last score.
static var pending_state := "menu"
static var last_score := -1

const SCORE_FILE := "user://highscores.json"
const MAX_SCORES := 10
var scores: Array = []
var score := 0
var qualifies := false
var name_edit: LineEdit
var ui_layer: CanvasLayer

var enemies: Array = []
var bullets: Array = []
var gems: Array = []
var choices: Array = []

var touch_id := -1
var stick_origin := Vector2.ZERO
var stick_vec := Vector2.ZERO
var cam: Camera2D

const UPGRADES := [
	{"name": "Mehr Schaden", "desc": "+30% Schaden", "key": "dmg"},
	{"name": "Schnellfeuer", "desc": "+25% Feuerrate", "key": "rate"},
	{"name": "Zusatzprojektil", "desc": "+1 Projektil", "key": "count"},
	{"name": "Tempo", "desc": "+15% Bewegung", "key": "speed"},
	{"name": "Magnet", "desc": "+50% Aufsammelradius", "key": "magnet"},
	{"name": "Lebenskraft", "desc": "+25 Max-HP, voll heilen", "key": "hp"},
]


func _ready() -> void:
	cam = Camera2D.new()
	add_child(cam)
	randomize()
	scores = _load_scores()
	state = pending_state
	pending_state = "menu"


func _load_scores() -> Array:
	if not FileAccess.file_exists(SCORE_FILE):
		return []
	var data = JSON.parse_string(FileAccess.get_file_as_string(SCORE_FILE))
	var out: Array = []
	if data is Array:
		for d in data:
			if d is Dictionary and d.has("name") and d.has("score"):
				out.append({"name": str(d.name), "score": int(d.score)})
	return out


func _save_scores() -> void:
	var f := FileAccess.open(SCORE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(scores))


func _qualifies(sc: int) -> bool:
	return sc > 0 and (scores.size() < MAX_SCORES or sc > int(scores[-1].score))


func _add_score(player_name: String) -> void:
	scores.append({"name": player_name, "score": score})
	scores.sort_custom(func(a, b): return a.score > b.score)
	scores = scores.slice(0, MAX_SCORES)
	_save_scores()


func _go(next: String) -> void:
	pending_state = next
	get_tree().reload_current_scene()


func _is_press(event: InputEvent) -> bool:
	return (event is InputEventScreenTouch and event.pressed) \
		or (event is InputEventKey and event.pressed and not event.echo)


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
	name_edit.grab_focus.call_deferred()


func _submit_name() -> void:
	var n := name_edit.text.strip_edges()
	if n.is_empty():
		n = "Anonym"
	_add_score(n)
	last_score = score
	_go("menu")


func _unhandled_input(event: InputEvent) -> void:
	if state == "name":
		return
	if state == "menu":
		if _is_press(event) and not (event is InputEventKey and event.keycode == KEY_ESCAPE):
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
		if event.pressed and touch_id == -1:
			touch_id = event.index
			stick_origin = event.position
			stick_vec = Vector2.ZERO
		elif not event.pressed and event.index == touch_id:
			touch_id = -1
			stick_vec = Vector2.ZERO
	elif event is InputEventScreenDrag and event.index == touch_id:
		stick_vec = ((event.position - stick_origin) / 80.0).limit_length(1.0)


func _handle_choice_input(event: InputEvent) -> void:
	var idx := -1
	if event is InputEventKey and event.pressed and event.keycode >= KEY_1 and event.keycode <= KEY_3:
		idx = event.keycode - KEY_1
	elif event is InputEventScreenTouch and event.pressed:
		idx = _choice_at(event.position)
	if idx >= 0 and idx < choices.size():
		_apply_upgrade(choices[idx].key)
		state = "play"
		touch_id = -1
		stick_vec = Vector2.ZERO


func _choice_at(p: Vector2) -> int:
	var vp := get_viewport_rect().size
	for i in choices.size():
		if _choice_rect(i, vp).has_point(p):
			return i
	return -1


func _choice_rect(i: int, vp: Vector2) -> Rect2:
	var w := minf(280.0, vp.x / 3.4)
	var total := w * 3.0 + 40.0
	return Rect2(Vector2((vp.x - total) / 2.0 + i * (w + 20.0), vp.y / 2.0 - 90.0), Vector2(w, 180.0))


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


func _process(delta: float) -> void:
	if state == "play":
		_update(delta)
	elif state == "dead":
		time_dead += delta
	cam.position = player_pos
	queue_redraw()


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


func _update(delta: float) -> void:
	time_alive += delta
	player_pos += _move_input() * speed * delta

	# Spawn rate grows with time.
	spawn_acc += delta * (1.0 + time_alive / 25.0)
	while spawn_acc >= 0.5:
		spawn_acc -= 0.5
		if enemies.size() < MAX_ENEMIES:
			_spawn_enemy()

	fire_acc += delta * fire_rate
	if fire_acc >= 1.0:
		fire_acc = 0.0
		_fire()

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

	for e in enemies:
		e.pos += (player_pos - e.pos).normalized() * e.speed * delta
		if e.pos.distance_to(player_pos) < e.r + PLAYER_RADIUS:
			hp -= e.dmg * delta
		if e.hp <= 0.0:
			kills += 1
			gems.append({"pos": e.pos})
	enemies = enemies.filter(func(e): return e.hp > 0.0)
	_separate_enemies()

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


func _separate_enemies() -> void:
	# Bounded-cost soft separation.
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


func _open_levelup() -> void:
	var pool := UPGRADES.duplicate()
	pool.shuffle()
	choices = pool.slice(0, 3)
	state = "levelup"


func _draw() -> void:
	var vp := get_viewport_rect().size
	var tl := player_pos - vp / 2.0

	if state == "menu":
		_draw_menu(tl, vp)
		return

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


func _draw_menu(tl: Vector2, vp: Vector2) -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(tl, vp), Color(0.07, 0.08, 0.12))
	draw_string(font, tl + Vector2(0, 90), "SURVIVORS", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 64)
	draw_string(font, tl + Vector2(0, 135), "Bestenliste – Top %d" % MAX_SCORES, HORIZONTAL_ALIGNMENT_CENTER, vp.x, 24)
	var row_h := minf(34.0, (vp.y - 300.0) / MAX_SCORES)
	var left := vp.x / 2.0 - 170.0
	var highlighted := false
	for i in MAX_SCORES:
		var y := 180.0 + i * row_h
		var col := Color(1, 1, 1, 0.9)
		if i < scores.size():
			if not highlighted and last_score >= 0 and scores[i].score == last_score:
				col = Color(1.0, 0.9, 0.3)
				highlighted = true
			draw_string(font, tl + Vector2(left, y), "%2d." % (i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)
			draw_string(font, tl + Vector2(left + 50, y), scores[i].name, HORIZONTAL_ALIGNMENT_LEFT, 180, 22, col)
			draw_string(font, tl + Vector2(left, y), str(scores[i].score), HORIZONTAL_ALIGNMENT_RIGHT, 340, 22, col)
		else:
			draw_string(font, tl + Vector2(left, y), "%2d.  –" % (i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 1, 0.3))
	if last_score >= 0:
		draw_string(font, tl + Vector2(0, vp.y - 90), "Letzter Score: %d" % last_score, HORIZONTAL_ALIGNMENT_CENTER, vp.x, 22, Color(1, 1, 1, 0.7))
	var pulse := 0.6 + 0.4 * sin(Time.get_ticks_msec() / 300.0)
	draw_string(font, tl + Vector2(0, vp.y - 40), "Tippen / Enter zum Starten", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 28, Color(0.3, 1.0, 0.5, pulse))


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

	if touch_id != -1:
		var o := tl + stick_origin
		draw_arc(o, 60.0, 0.0, TAU, 32, Color(1, 1, 1, 0.3), 3.0)
		draw_circle(o + stick_vec * 60.0, 24.0, Color(1, 1, 1, 0.35))

	if state == "levelup":
		draw_rect(Rect2(tl, vp), Color(0, 0, 0, 0.6))
		draw_string(font, tl + Vector2(0, vp.y / 2.0 - 130), "LEVEL UP!", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 40)
		for i in choices.size():
			var r := _choice_rect(i, vp)
			r.position += tl
			draw_rect(r, Color(0.15, 0.17, 0.25))
			draw_rect(r, Color(0.5, 0.6, 1.0), false, 2.0)
			draw_string(font, r.position + Vector2(0, 70), "[%d] %s" % [i + 1, choices[i].name], HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 22)
			draw_string(font, r.position + Vector2(0, 110), choices[i].desc, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 18)
	elif state == "dead":
		draw_rect(Rect2(tl, vp), Color(0.2, 0, 0, 0.65))
		draw_string(font, tl + Vector2(0, vp.y / 2.0 - 20), "GAME OVER", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 48)
		draw_string(font, tl + Vector2(0, vp.y / 2.0 + 30), "Score: %d" % score, HORIZONTAL_ALIGNMENT_CENTER, vp.x, 28)
		if time_dead > 0.8:
			draw_string(font, tl + Vector2(0, vp.y / 2.0 + 75), "Taste / Tippen zum Fortfahren", HORIZONTAL_ALIGNMENT_CENTER, vp.x, 22)
	elif state == "name":
		draw_rect(Rect2(tl, vp), Color(0.07, 0.08, 0.12, 0.92))
