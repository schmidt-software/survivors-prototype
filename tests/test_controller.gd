extends SceneTree
## Regression coverage for issue #1. Run with --headless --script tests/test_controller.gd.

class TestGame extends "res://main.gd":
	var destination := ""
	var saved_name := ""

	func _load_scores() -> Array:
		return []

	func _go(next: String) -> void:
		destination = next

	func _add_score(player_name: String) -> void:
		saved_name = player_name

var failures := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func button(index: int, pressed := true) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = index
	event.pressed = pressed
	return event


func stick(value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.axis = JOY_AXIS_LEFT_X
	event.axis_value = value
	return event


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var game := TestGame.new()
	root.add_child(game)
	game.set_process(false)
	game._unhandled_input(button(JOY_BUTTON_A, false))
	check(game.destination.is_empty(), "Button release must not start a run")
	game._unhandled_input(button(JOY_BUTTON_B))
	check(game.destination.is_empty(), "Only confirm should start a run")
	game._unhandled_input(button(JOY_BUTTON_A))
	check(game.destination == "play", "Controller confirm must start a run")

	game.destination = ""
	game.state = "dead"
	game.qualifies = false
	game.time_dead = 0.5
	game._unhandled_input(button(JOY_BUTTON_A))
	check(game.destination.is_empty(), "Death delay must apply to controllers")
	game.time_dead = 1.0
	game._unhandled_input(button(JOY_BUTTON_A))
	check(game.destination == "menu", "Controller must return to menu after death")

	game._open_levelup()
	check(game.selected_choice == 0, "Each level-up starts with the first card selected")
	game._unhandled_input(button(JOY_BUTTON_DPAD_LEFT))
	check(game.selected_choice == 2, "D-pad must wrap from first to last card")
	game._unhandled_input(button(JOY_BUTTON_DPAD_RIGHT))
	check(game.selected_choice == 0, "D-pad must wrap from last to first card")
	game._unhandled_input(stick(0.7))
	check(game.selected_choice == 1, "Stick must move the selection")
	game._unhandled_input(stick(0.9))
	check(game.selected_choice == 1, "A held stick must not repeat")
	game._unhandled_input(stick(0.0))
	game._unhandled_input(stick(-0.8))
	check(game.selected_choice == 0, "Neutral must rearm stick navigation")
	game.choices = [{"key": "dmg"}, {"key": "rate"}, {"key": "count"}]
	game._unhandled_input(button(JOY_BUTTON_A))
	check(game.state == "play" and is_equal_approx(game.damage, 13.0), "Confirm must apply selected upgrade")
	check(game.touch_id == -1 and game.stick_vec == Vector2.ZERO, "Choosing must reset the touch joystick")

	game._open_levelup()
	var key := InputEventKey.new()
	key.keycode = KEY_2
	key.pressed = true
	game._unhandled_input(key)
	check(game.state == "play", "Number keys must still select directly")
	game._open_levelup()
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	touch.position = game._choice_rect(2, game.get_viewport_rect().size).get_center()
	game._unhandled_input(touch)
	check(game.state == "play", "Touch cards must still work")

	game.state = "dead"
	game.qualifies = true
	game._unhandled_input(button(JOY_BUTTON_A))
	check(game.state == "name", "Qualifying controller run must open name entry")
	game.name_edit.text = "Player"
	game._input(button(JOY_BUTTON_A))
	check(game.saved_name == "Player" and game.destination == "menu", "Controller must save the entered name")
	game.name_edit.text = " "
	game.state = "name"
	game._input(button(JOY_BUTTON_A))
	check(game.saved_name == "Anonym", "Controller must allow an anonymous score")
	game.free()
	print("Controller checks: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
