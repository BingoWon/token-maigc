class_name ChatUI
extends Control

# Constants
const API_HOST: String = "api.siliconflow.cn"
const API_PORT: int = 443
const ERROR_PREFIX: String = "❌ "

# Scene References
var message_bubble_scene: PackedScene = preload("res://message_bubble.tscn")

# State Variables
var conversation_history: Array[Dictionary] = []
var current_thinking_bubble: MessageBubble = null
var current_answer_bubble: MessageBubble = null
var stream_buffer: String = ""
var http_client: HTTPClient = null
var is_streaming: bool = false
var accumulated_thinking: String = ""
var accumulated_answer: String = ""
var api_settings: Dictionary = {}

# Usage Statistics
var total_prompt_tokens: int = 0
var total_completion_tokens: int = 0
var pending_usage: Dictionary = {}  # Temporary storage for current stream's usage

# UI References
@onready var messages_container: VBoxContainer = %MessagesContainer
@onready var scroll_container: ScrollContainer = %ScrollContainer
@onready var input_field: TextEdit = %InputField
@onready var send_button: Button = %SendButton
@onready var settings_button: Button = %SettingsButton
@onready var restart_button: Button = %RestartButton
@onready var loading_label: Label = %LoadingLabel
@onready var usage_label: Label = %UsageLabel
@onready var status_label: Label = %StatusLabel
@onready var objectives_label: RichTextLabel = %ObjectivesLabel
@onready var settings_panel: PopupPanel = $SettingsPanel

func _ready() -> void:
	_connect_signals()
	_initialize_ui()
	_load_settings()
	_initialize_game()

func _connect_signals() -> void:
	send_button.pressed.connect(_on_send_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	restart_button.pressed.connect(_on_restart_button_pressed)
	input_field.gui_input.connect(_on_input_field_gui_input)
	settings_panel.settings_changed.connect(_on_settings_changed)
	GameState.stats_changed.connect(_on_stats_changed)
	GameState.objectives_updated.connect(_on_objectives_updated)
	GameState.game_over.connect(_on_game_over)

func _initialize_ui() -> void:
	loading_label.visible = false
	input_field.grab_focus()
	_update_usage_display()

func _load_settings() -> void:
	api_settings = settings_panel.get_settings()

func _initialize_game() -> void:
	if http_client:
		http_client.close()

	is_streaming = false
	http_client = null
	stream_buffer = ""
	pending_usage = {}
	_reset_streaming_state()

	GameState.reset_game()

	conversation_history.clear()
	_refresh_system_prompt()

	for child: Node in messages_container.get_children():
		child.queue_free()

	current_thinking_bubble = null
	current_answer_bubble = null

	var intro_text: String = GameState.get_intro_message()
	_add_message(MessageBubble.Role.ASSISTANT, intro_text)
	conversation_history.append({"role": "assistant", "content": intro_text})

	_set_input_enabled(true)
	loading_label.visible = false

func _refresh_system_prompt() -> void:
	var prompt: String = GameState.get_system_prompt()
	if conversation_history.is_empty():
		conversation_history.append({"role": "system", "content": prompt})
	elif conversation_history[0].get("role", "") == "system":
		conversation_history[0] = {"role": "system", "content": prompt}
	else:
		conversation_history.insert(0, {"role": "system", "content": prompt})

func _on_send_button_pressed() -> void:
	_send_message()

func _on_settings_button_pressed() -> void:
	settings_panel.popup_centered()

func _on_settings_changed(settings: Dictionary) -> void:
	api_settings = settings

func _on_restart_button_pressed() -> void:
	clear_conversation()

func _on_input_field_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var is_modifier_pressed: bool = event.ctrl_pressed or event.meta_pressed
		if event.keycode == KEY_ENTER and is_modifier_pressed:
			_send_message()
			get_viewport().set_input_as_handled()

func _send_message() -> void:
	var text: String = input_field.text.strip_edges()
	if text.is_empty():
		return

	if GameState.is_game_over():
		var end_notice := "The operation is over. Press Restart to begin a new run."
		_add_message(MessageBubble.Role.ASSISTANT, end_notice)
		input_field.text = ""
		return

	_set_input_enabled(false)
	_add_message(MessageBubble.Role.USER, text)
	conversation_history.append({"role": "user", "content": text})
	input_field.text = ""

	GameState.register_player_message(text)
	GameState.advance_turn()
	_refresh_system_prompt()

	if GameState.is_game_over():
		loading_label.visible = false
		return

	_reset_streaming_state()
	_prepare_thinking_bubble()
	_call_api_stream()

func _reset_streaming_state() -> void:
	accumulated_thinking = ""
	accumulated_answer = ""
	current_thinking_bubble = null
	current_answer_bubble = null

func _prepare_thinking_bubble() -> void:
	current_thinking_bubble = message_bubble_scene.instantiate()
	messages_container.add_child(current_thinking_bubble)
	current_thinking_bubble.setup_thinking("")
	current_thinking_bubble.visible = false

func _add_message(role: MessageBubble.Role, text: String) -> MessageBubble:
	var bubble = message_bubble_scene.instantiate()
	messages_container.add_child(bubble)
	bubble.setup(role, text)
	await get_tree().process_frame
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)
	return bubble

func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	scroll_container.scroll_vertical = int(scroll_container.get_v_scroll_bar().max_value)

func _call_api_stream() -> void:
	loading_label.visible = true
	stream_buffer = ""
	is_streaming = true
	pending_usage = {}  # Reset usage for new stream

	var api_key: String = api_settings.get("api_key", "")
	if api_key.is_empty():
		_handle_error("API key is not configured. Please set it in Settings.")
		return

	http_client = HTTPClient.new()
	var error: Error = http_client.connect_to_host(API_HOST, API_PORT, TLSOptions.client())
	if error != OK:
		_handle_error("Connection failed: " + error_string(error))
		return

	var request_body: Dictionary = _build_request_body()
	var json_body: String = JSON.stringify(request_body)

	await _wait_for_connection()

	if http_client.get_status() != HTTPClient.STATUS_CONNECTED:
		_handle_error("Failed to connect to server")
		return

	var headers: PackedStringArray = _build_request_headers(api_key)

	error = http_client.request(HTTPClient.METHOD_POST, "/v1/chat/completions", headers, json_body)
	if error != OK:
		_handle_error("Request failed: " + error_string(error))
		return

	_read_stream()

func _build_request_body() -> Dictionary:
	var body: Dictionary = {
		"model": api_settings.get("model", "deepseek-ai/DeepSeek-V3.1"),
		"messages": conversation_history,
		"stream": true,
		"max_tokens": api_settings.get("max_tokens", 4096),
		"temperature": api_settings.get("temperature", 0.7),
		"top_p": api_settings.get("top_p", 0.7),
		"top_k": api_settings.get("top_k", 50),
		"frequency_penalty": api_settings.get("frequency_penalty", 0.0)
	}

	if api_settings.get("enable_thinking", true):
		body["enable_thinking"] = true
		body["thinking_budget"] = api_settings.get("thinking_budget", 4096)

	if api_settings.has("min_p"):
		body["min_p"] = api_settings["min_p"]

	if api_settings.get("stop") != null:
		body["stop"] = api_settings["stop"]

	return body

func _build_request_headers(api_key: String) -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + api_key,
		"Accept: text/event-stream"
	])

func _wait_for_connection() -> void:
	while http_client.get_status() == HTTPClient.STATUS_CONNECTING or \
			http_client.get_status() == HTTPClient.STATUS_RESOLVING:
		http_client.poll()
		await get_tree().process_frame

func _read_stream() -> void:
	while is_streaming:
		http_client.poll()
		var status: HTTPClient.Status = http_client.get_status()

		if status == HTTPClient.STATUS_BODY:
			_process_stream_body()
		elif status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_CONNECTION_ERROR:
			is_streaming = false
			break

		await get_tree().process_frame

	_finalize_stream()

func _process_stream_body() -> void:
	if not http_client.has_response():
		return

	var chunk: PackedByteArray = http_client.read_response_body_chunk()
	if chunk.size() == 0:
		return

	var text: String = chunk.get_string_from_utf8()
	stream_buffer += text

	var lines: PackedStringArray = stream_buffer.split("\n")
	for i: int in range(lines.size() - 1):
		_process_stream_line(lines[i])

	stream_buffer = lines[lines.size() - 1]

func _process_stream_line(line: String) -> void:
	line = line.strip_edges()
	if not line.begins_with("data: "):
		return

	var json_str: String = line.substr(6).strip_edges()
	if json_str == "[DONE]":
		is_streaming = false
		return

	var json := JSON.new()
	if json.parse(json_str) != OK:
		return

	var data: Variant = json.data
	if not (data is Dictionary and data.has("choices") and data.choices.size() > 0):
		return

	var delta: Dictionary = data.choices[0].delta
	_process_delta(delta)

	# Store usage statistics if present (don't accumulate yet)
	if data.has("usage") and data.usage is Dictionary:
		pending_usage = data.usage

	# Check if stream is finished
	var choice: Dictionary = data.choices[0]
	if choice.has("finish_reason") and choice.finish_reason != null:
		is_streaming = false

func _process_delta(delta: Dictionary) -> void:
	if delta.has("reasoning_content") and delta.reasoning_content != null:
		_process_thinking_content(str(delta.reasoning_content))

	if delta.has("content") and delta.content != null:
		_process_answer_content(str(delta.content))

func _process_thinking_content(content: String) -> void:
	accumulated_thinking += content
	if current_thinking_bubble:
		current_thinking_bubble.visible = true
		current_thinking_bubble.update_text(accumulated_thinking, true)
		_scroll_to_bottom()

func _process_answer_content(content: String) -> void:
	accumulated_answer += content
	if not current_answer_bubble:
		_create_answer_bubble()
	current_answer_bubble.update_text(accumulated_answer)
	_scroll_to_bottom()

func _create_answer_bubble() -> void:
	current_answer_bubble = message_bubble_scene.instantiate()
	messages_container.add_child(current_answer_bubble)
	current_answer_bubble.setup(MessageBubble.Role.ASSISTANT, "")
	if current_thinking_bubble:
		current_thinking_bubble.visible = false

func _finalize_stream() -> void:
	loading_label.visible = false

	if not accumulated_answer.is_empty():
		conversation_history.append({"role": "assistant", "content": accumulated_answer})
		_handle_gameplay_update(accumulated_answer)
	else:
		_refresh_system_prompt()

	# Update usage statistics only once at the end
	if not pending_usage.is_empty():
		_update_usage_stats(pending_usage)
		pending_usage = {}

	http_client = null

	if GameState.is_game_over():
		_set_input_enabled(false)
	else:
		_set_input_enabled(true)

func _handle_error(error_message: String) -> void:
	push_error("API Error: " + error_message)
	_add_message(MessageBubble.Role.ASSISTANT, ERROR_PREFIX + error_message)
	loading_label.visible = false
	_set_input_enabled(true)

	# Clean up state
	http_client = null
	pending_usage = {}
	is_streaming = false

func _set_input_enabled(enabled: bool) -> void:
	input_field.editable = enabled
	send_button.disabled = not enabled
	if enabled:
		input_field.grab_focus()

func _on_stats_changed(stats: Dictionary) -> void:
	var morale: int = stats.get("morale", 0)
	var intel: int = stats.get("intel", 0)
	var turns: int = stats.get("turns_left", 0)
	var outcome: String = str(stats.get("outcome", ""))

	var status_text: String = "Status: Morale %d | Intel %d | Turns %d" % [
		morale,
		intel,
		turns
	]

	if not outcome.is_empty():
		status_text += " | %s" % outcome.to_upper()

	status_label.text = status_text

func _on_objectives_updated(_objectives: Array) -> void:
	objectives_label.text = GameState.get_objectives_bbcode()

func _on_game_over(result: String, summary: String) -> void:
	var heading: String = "Mission Failed"
	if result == "victory":
		heading = "Mission Accomplished"
	var message: String = "[b]%s[/b]\n%s\n\nPress Restart to begin a new run." % [heading, summary]
	_add_message(MessageBubble.Role.ASSISTANT, message)
	conversation_history.append({"role": "assistant", "content": message})
	loading_label.visible = false
	_set_input_enabled(false)

func _handle_gameplay_update(raw_response: String) -> void:
	var payload: Dictionary = _extract_game_payload(raw_response)
	if payload.is_empty():
		push_warning("Failed to parse AI game payload. Ensure responses follow the JSON contract.")
		_refresh_system_prompt()
		return

	var display_text: String = str(payload.get("narrative", raw_response)).strip_edges()

	var flags_data: Variant = payload.get("flags", {})
	if flags_data is Dictionary:
		var flags: Dictionary = flags_data
		if flags.has("hint"):
			display_text += "\n[i]Hint: %s[/i]" % str(flags["hint"])

	if current_answer_bubble:
		current_answer_bubble.update_text(display_text)

	GameState.apply_ai_payload(payload)
	_refresh_system_prompt()

func _extract_game_payload(text: String) -> Dictionary:
	var start_marker: String = "```json"
	var start_index: int = text.find(start_marker)
	var json_source: String = ""

	if start_index != -1:
		start_index += start_marker.length()
		var end_index: int = text.find("```", start_index)
		if end_index == -1:
			end_index = text.length()
		json_source = text.substr(start_index, end_index - start_index).strip_edges()
	else:
		json_source = text.strip_edges()

	var parser := JSON.new()
	if parser.parse(json_source) != OK:
		return {}

	var data: Variant = parser.data
	if data is Dictionary:
		return data

	return {}

func clear_conversation() -> void:
	total_prompt_tokens = 0
	total_completion_tokens = 0
	_update_usage_display()
	_initialize_game()

func _update_usage_stats(usage: Dictionary) -> void:
	total_prompt_tokens += usage.get("prompt_tokens", 0)
	total_completion_tokens += usage.get("completion_tokens", 0)
	_update_usage_display()

func _update_usage_display() -> void:
	var total: int = total_prompt_tokens + total_completion_tokens
	usage_label.text = "Tokens - Prompt: %d | Completion: %d | Total: %d" % [
		total_prompt_tokens,
		total_completion_tokens,
		total
	]
