extends SceneTree
## Regression coverage for issue #2. Persistence is stubbed to protect real scores.

class TestGame extends "res://main.gd":
	var saved: Array = []

	func _save_scores() -> void:
		saved = scores.duplicate(true)

var failures := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _initialize() -> void:
	var game := TestGame.new()
	var raw: Array = []
	for value in [10, 40, 30, 90, 80, 70, 60, 50, 20, 100]:
		raw.append({"name": "Player", "score": value})
	game.scores = raw.duplicate(true)
	check(game._qualifies(85), "An unsorted full list must accept 85")
	check(not game._qualifies(10), "A tie with last place must not qualify")
	check(not game._qualifies(0) and not game._qualifies(-1), "Non-positive scores must not qualify")
	game.scores = game._normalize_scores(JSON.parse_string(JSON.stringify(raw)))
	check(game.scores.size() == 10, "All ten valid entries must survive JSON round-trip")
	for i in 10:
		check(game.scores[i].score == (10 - i) * 10, "Loaded scores must be descending")
		check(game.scores[i].score is int, "JSON numbers must become integer scores")

	raw.append({"name": "  VeryLongPlayerName  ", "score": 200})
	raw.append({"name": " ", "score": 150.0})
	game.scores = game._normalize_scores(raw)
	check(game.scores.size() == 10 and game.scores[-1].score == 30, "Oversized list must keep only top ten")
	check(game.scores[0].name == "VeryLongPlay", "Names must be trimmed and limited to twelve characters")
	check(game.scores[1].name == "Anonym", "Blank stored names must normalize consistently")
	check(not game._qualifies(30) and game._qualifies(31), "Qualification must use the actual cutoff")

	var invalid: Array = [
		null, 123, {}, {"name": "P"}, {"score": 1},
		{"name": [], "score": 100}, {"name": "P", "score": "100"},
		{"name": "P", "score": true}, {"name": "P", "score": -1},
		{"name": "P", "score": 0}, {"name": "P", "score": 2.5},
		{"name": "P", "score": INF}, {"name": "P", "score": NAN},
		{"name": "P", "score": 9223372036854775808.0},
		{"name": "Valid", "score": 42.0},
	]
	var normalized: Array = game._normalize_scores(invalid)
	check(normalized == [{"name": "Valid", "score": 42}], "Invalid types and numeric values must be rejected safely")
	check(game._normalize_scores({}).is_empty(), "A non-array root must be rejected")
	check(game._normalize_scores([]).is_empty(), "Empty leaderboard must load")
	game.scores = []
	check(game._qualifies(1), "First positive score must qualify")
	game.score = 5
	game._add_score("First")
	check(game.saved == [{"name": "First", "score": 5}], "Adding a score must persist normalized data")
	game.scores = game._normalize_scores(raw)
	game.score = 85
	game._add_score("New")
	check(game.saved.size() == 10, "Save must remain limited to ten")
	check(game.saved.any(func(entry): return entry.name == "New" and entry.score == 85), "New qualifying score must be saved")
	game.free()
	print("Highscore checks: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
