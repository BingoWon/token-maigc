extends Control
class_name ChatUI

# Constants
const API_URL: String = "https://api.siliconflow.cn/v1/chat/completions"
const API_HOST: String = "api.siliconflow.cn"
const API_PORT: int = 443
const WELCOME_MESSAGE: String = "Hello! I'm DeepSeek AI with streaming support. How can I help you?"
const ERROR_PREFIX: String = "❌ "
const THINKING_EMOJI: String = "💭"

# UI References
@onready var messages_container: VBoxContainer = %MessagesContainer
@onready var scroll_container: ScrollContainer = %ScrollContainer
@onready var input_field: TextEdit = %InputField
@onready var send_button: Button = %SendButton
@onready var settings_button: Button = %SettingsButton
@onready var loading_label: Label = %LoadingLabel
@onready var usage_label: Label = %UsageLabel
@onready var settings_panel: PopupPanel = $SettingsPanel

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

func _ready() -> void:
	_connect_signals()
	_initialize_ui()
	_load_settings()
	_show_welcome_message()

func _connect_signals() -> void:
	send_button.pressed.connect(_on_send_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	input_field.gui_input.connect(_on_input_field_gui_input)
	settings_panel.settings_changed.connect(_on_settings_changed)

func _initialize_ui() -> void:
	loading_label.visible = false
	input_field.grab_focus()
	_update_usage_display()

func _load_settings() -> void:
	api_settings = settings_panel.get_settings()

func _show_welcome_message() -> void:
	_add_message(MessageBubble.Role.ASSISTANT, WELCOME_MESSAGE)

func _on_send_button_pressed() -> void:
	_send_message()

func _on_settings_button_pressed() -> void:
	settings_panel.popup_centered()

func _on_settings_changed(settings: Dictionary) -> void:
	api_settings = settings

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

	_set_input_enabled(false)
	_add_message(MessageBubble.Role.USER, text)
	conversation_history.append({"role": "user", "content": text})
	input_field.text = ""

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
	_set_input_enabled(true)

	if not accumulated_answer.is_empty():
		conversation_history.append({"role": "assistant", "content": accumulated_answer})

	# Update usage statistics only once at the end
	if not pending_usage.is_empty():
		_update_usage_stats(pending_usage)
		pending_usage = {}

	http_client = null

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

func clear_conversation() -> void:
	conversation_history.clear()
	for child: Node in messages_container.get_children():
		child.queue_free()
	_show_welcome_message()

	# Reset usage statistics
	total_prompt_tokens = 0
	total_completion_tokens = 0
	_update_usage_display()

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
