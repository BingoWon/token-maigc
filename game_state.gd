extends Node

signal stats_changed(stats: Dictionary)
signal objectives_updated(objectives: Array)
signal game_over(result: String, summary: String)

const INITIAL_MORALE: int = 60
const INITIAL_INTEL: int = 0
const INITIAL_TURNS: int = 10

const SCENARIO_TITLE: String = "Operation Token Magic"
const SCENARIO_BLURB: String = (
	"You are the field operative tasked with planning an infiltration run on the Neon Lab. " +
	"Your handler, DeepSeek Control, responds through the encrypted chat. " +
	"Win by securing the full plan before the operation window closes."
)

var morale: int = INITIAL_MORALE
var intel: int = INITIAL_INTEL
var turns_left: int = INITIAL_TURNS
var objectives: Array[Dictionary] = []
var outcome: String = ""
var outcome_summary: String = ""

func _ready() -> void:
	reset_game()

func reset_game() -> void:
	morale = INITIAL_MORALE
	intel = INITIAL_INTEL
	turns_left = INITIAL_TURNS
	outcome = ""
	outcome_summary = ""
	objectives = [
		{
			"id": "briefing",
			"title": "Secure Mission Briefing",
			"description": "Convince Control to outline the mission stakes and constraints.",
			"completed": false
		},
		{
			"id": "access_plan",
			"title": "Identify Access Strategy",
			"description": "Obtain a viable plan for breaching the Neon Lab's security.",
			"completed": false
		},
		{
			"id": "extraction",
			"title": "Lock Extraction Protocol",
			"description": "Agree on extraction timing and contingencies.",
			"completed": false
		}
	]
	_emit_stats()
	emit_signal("objectives_updated", objectives.duplicate(true))

func is_game_over() -> bool:
	return not outcome.is_empty()

func advance_turn() -> void:
	if is_game_over():
		return
	turns_left = max(0, turns_left - 1)
	if turns_left == 0 and not _all_objectives_completed():
		_set_game_over("defeat", "Control aborts the op. You ran out of time before the plan was ready.")
	else:
		_emit_stats()

func register_player_message(_message: String) -> void:
	if is_game_over():
		return
	# Placeholder for future player-side rules (e.g., morale decay on aggressive tone).

func apply_ai_payload(payload: Dictionary) -> void:
	if is_game_over():
		return

	if payload.has("effects") and payload["effects"] is Dictionary:
		_apply_effects(payload["effects"])

	if payload.has("objective_progress"):
		_progress_objectives(payload["objective_progress"])

	var flags_data: Variant = payload.get("flags", {})
	if flags_data is Dictionary:
		var flags: Dictionary = flags_data
		if flags.has("end_state"):
			var state: String = str(flags["end_state"]).to_lower()
			if state == "victory":
				_set_game_over("victory", flags.get("summary", "Control green-lights the op."))
				return
			if state == "defeat":
				_set_game_over("defeat", flags.get("summary", "The op collapses under conflicting plans."))
				return

	if _all_objectives_completed():
		_set_game_over("victory", "All operational beats are locked. You're cleared for launch.")
	else:
		_emit_stats()
		emit_signal("objectives_updated", objectives.duplicate(true))

func _apply_effects(effects: Dictionary) -> void:
	if effects.has("morale"):
		morale = clamp(morale + int(effects["morale"]), 0, 100)
	if effects.has("intel"):
		intel = clamp(intel + int(effects["intel"]), 0, 10)
	if effects.has("turns"):
		turns_left = clamp(turns_left + int(effects["turns"]), 0, 20)

	if morale <= 0:
		_set_game_over("defeat", "Control loses faith in the plan. Morale collapsed.")

func _progress_objectives(progress_payload: Variant) -> void:
	var target_ids: Array[String] = []
	if progress_payload is Array:
		for item in progress_payload:
			target_ids.append(str(item))
	elif progress_payload is String:
		target_ids.append(progress_payload)

	if target_ids.is_empty():
		return

	for objective in objectives:
		if target_ids.has(objective["id"]):
			objective["completed"] = true

	emit_signal("objectives_updated", objectives.duplicate(true))

func _all_objectives_completed() -> bool:
	for objective in objectives:
		if not objective["completed"]:
			return false
	return true

func _set_game_over(result: String, summary: String) -> void:
	outcome = result
	outcome_summary = summary
	_emit_stats()
	emit_signal("objectives_updated", objectives.duplicate(true))
	emit_signal("game_over", result, summary)

func _emit_stats() -> void:
	emit_signal("stats_changed", get_stats_snapshot())

func get_stats_snapshot() -> Dictionary:
	return {
		"morale": morale,
		"intel": intel,
		"turns_left": turns_left,
		"outcome": outcome
	}

func get_system_prompt() -> String:
	var objective_lines: Array[String] = []
	var objective_ids: Array[String] = []
	for objective in objectives:
		var status: String = ""
		if objective["completed"]:
			status = "COMPLETED"
		else:
			status = "IN_PROGRESS"
		objective_ids.append(str(objective["id"]))
		objective_lines.append("- %s [%s] (%s): %s" % [
			objective["title"],
			objective["id"],
			status,
			objective["description"]
		])

	var prompt_lines: Array[String] = []
	prompt_lines.append(
		"You are DeepSeek Control, an AI game master running a strategic "
		+ "planning game."
	)
	prompt_lines.append("Always stay in character as a pragmatic handler.")
	prompt_lines.append("Current scenario: %s: %s" % [SCENARIO_TITLE, SCENARIO_BLURB])
	prompt_lines.append("Player stats:")
	prompt_lines.append("- Morale: %d/100" % morale)
	prompt_lines.append("- Intel Confidence: %d/10" % intel)
	prompt_lines.append("- Planning Window Remaining: %d turns" % turns_left)
	prompt_lines.append("Objectives:")
	prompt_lines.append_array(objective_lines)
	prompt_lines.append("Valid objective ids: %s" % ", ".join(objective_ids))
	prompt_lines.append("Gameplay rules:")
	prompt_lines.append(
		"1. Every response MUST be a JSON object wrapped in triple backticks "
		+ "with the json language hint."
	)
	prompt_lines.append(
		"2. The JSON must contain: narrative (string), effects (object with "
		+ "optional morale/intel/turns integers), objective_progress (array of "
		+ "objective IDs that advanced), and flags.end_state when the game "
		+ "should end."
	)
	prompt_lines.append(
		"3. narrative should be 2-4 sentences of immersive fiction plus any "
		+ "questions or prompts for the player."
	)
	prompt_lines.append(
		"4. Encourage the player to respond with concrete tactics or questions. "
		+ "Offer meaningful consequences."
	)
	prompt_lines.append("Example:")
	prompt_lines.append("```json")
	prompt_lines.append(
		"{\"narrative\": \"Control braces you for tighter patrols...\","
	)
	prompt_lines.append("  \"effects\": {\"morale\": -5, \"intel\": 1},")
	prompt_lines.append("  \"objective_progress\": [\"briefing\"],")
	prompt_lines.append("  \"flags\": {\"hint\": \"Ask about their drone net.\"}")
	prompt_lines.append("}")
	prompt_lines.append("```")
	prompt_lines.append(
		"Stick to the JSON format strictly and update the story based on the "
		+ "objectives and stats."
	)

	return "\n".join(prompt_lines)

func get_intro_message() -> String:
	return "[b]%s[/b]\n%s\n\nTurns remaining: %d | Morale: %d | Intel Confidence: %d" % [
		SCENARIO_TITLE,
		SCENARIO_BLURB,
		turns_left,
		morale,
		intel
	]

func get_objectives_bbcode() -> String:
	var lines: Array[String] = ["[b]Objectives[/b]"]
	for objective in objectives:
		var marker: String = "[color=gray]○[/color]"
		if objective["completed"]:
			marker = "[color=lime]✔[/color]"
		lines.append("%s %s" % [marker, objective["title"]])
	return "\n".join(lines)
