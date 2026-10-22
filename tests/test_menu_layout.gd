extends SceneTree
## Regression coverage for issue #3: measure actual Control layout in SubViewports.

class TestGame extends "res://main.gd":
	var destination := ""

	func _load_scores() -> Array:
		var entries: Array = []
		for i in 10:
			entries.append({"name": "Player %d" % i, "score": (10 - i) * 100})
		return entries

	func _go(next: String) -> void:
		destination = next

var failures := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _initialize() -> void:
	call_deferred("run")


func settle_layout() -> void:
	for i in 6:
		await process_frame


func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	root.add_child(viewport)
	var game := TestGame.new()
	game.last_score = 100
	viewport.add_child(game)
	game.set_process(false)
	for dimensions in [Vector2i(1280, 720), Vector2i(640, 240), Vector2i(320, 200), Vector2i(320, 568), Vector2i(1920, 1080)]:
		viewport.size = dimensions
		await settle_layout()
		var bounds := Rect2(Vector2.ZERO, Vector2(dimensions))
		var start: Rect2 = game.menu_start_button.get_global_rect()
		var scroll: Rect2 = game.menu_scroll.get_global_rect()
		check(bounds.encloses(start), "Start button must fit in %s" % dimensions)
		check(bounds.encloses(scroll) and scroll.size.y >= 32, "At least one readable row must fit in %s: bounds=%s scroll=%s" % [dimensions, bounds, scroll])
		check(scroll.end.y <= game.menu_last_score.get_global_rect().position.y, "Table must not overlap footer in %s" % dimensions)
		check(game.menu_title.get_global_rect().end.y <= game.menu_subtitle.get_global_rect().position.y, "Header labels must not overlap")
		var rows: VBoxContainer = game.menu_scroll.get_child(0)
		check(rows.get_child_count() == 10, "All ten ranks must be present")
		for i in 10:
			var row: HBoxContainer = rows.get_child(i)
			check(row.size.y >= 32, "Rows must retain readable positive height")
			if i > 0:
				check(rows.get_child(i - 1).get_rect().end.y <= row.position.y, "Ranks must not overlap")
		if dimensions.y < 480:
			var bar: VScrollBar = game.menu_scroll.get_v_scroll_bar()
			check(bar.max_value > bar.page, "Short viewports must enable scrolling")
			game.menu_scroll.scroll_vertical = int(bar.max_value)
			await settle_layout()
			var last: Rect2 = rows.get_child(9).get_global_rect()
			check(last.intersects(scroll) and last.end.y <= scroll.end.y + 1, "Last rank must be reachable by scrolling")
		game.menu_scroll.scroll_vertical = 0

	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	touch.position = game.menu_scroll.get_global_rect().get_center()
	game._unhandled_input(touch)
	check(game.destination.is_empty(), "Touching or scrolling the table must not start a run")
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_DOWN
	game._unhandled_input(key)
	check(game.destination.is_empty(), "Navigation keys must not start a run")
	key.keycode = KEY_ENTER
	game._unhandled_input(key)
	check(game.destination == "play", "Enter must still start a run")
	game.destination = ""
	game.menu_start_button.pressed.emit()
	check(game.destination == "play", "The start button must start a run")
	game.destination = ""
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = game.menu_start_button.get_global_rect().get_center()
	click.pressed = true
	viewport.push_input(click)
	click = click.duplicate()
	click.pressed = false
	viewport.push_input(click)
	check(game.destination == "play", "A routed mouse click must activate the start button")
	check(ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch"), "Touch must generate mouse events for native UI controls")
	viewport.free()
	print("Menu layout checks: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
