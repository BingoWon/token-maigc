extends PopupPanel

signal settings_changed(settings: Dictionary)

# UI References
@onready var api_key_input: LineEdit = %ApiKeyInput
@onready var model_option: OptionButton = %ModelOption
@onready var max_tokens_spin: SpinBox = %MaxTokensSpin
@onready var enable_thinking_check: CheckBox = %EnableThinkingCheck
@onready var thinking_budget_spin: SpinBox = %ThinkingBudgetSpin
@onready var temperature_spin: SpinBox = %TemperatureSpin
@onready var top_p_spin: SpinBox = %TopPSpin
@onready var top_k_spin: SpinBox = %TopKSpin
@onready var min_p_spin: SpinBox = %MinPSpin
@onready var frequency_penalty_spin: SpinBox = %FrequencyPenaltySpin
@onready var stop_input: LineEdit = %StopInput

# Constants
const MODELS: Array[String] = [
	"deepseek-ai/DeepSeek-V3.1",
	"Pro/deepseek-ai/DeepSeek-V3.1",
	"deepseek-ai/DeepSeek-V3.2-Exp",
	"Qwen/Qwen3-8B",
	"Qwen/Qwen3-14B",
	"Qwen/Qwen3-32B",
	"Qwen/Qwen3-235B-A22B",
]

const DEFAULT_API_KEY: String = "sk-oycsjraeitohhwtzgxbptvmpkppttchswtejizcjzxnyzpbe"
const DEFAULT_MODEL: String = "deepseek-ai/DeepSeek-V3.1"
const DEFAULT_MAX_TOKENS: int = 4096
const DEFAULT_THINKING_BUDGET: int = 4096
const DEFAULT_TEMPERATURE: float = 0.7
const DEFAULT_TOP_P: float = 0.7
const DEFAULT_TOP_K: int = 50
const DEFAULT_MIN_P: float = 0.05
const DEFAULT_FREQUENCY_PENALTY: float = 0.0

const CONFIG_FILE_PATH: String = "user://settings.cfg"
const CONFIG_SECTION: String = "settings"

# Current settings
var current_settings: Dictionary = {
	"api_key": DEFAULT_API_KEY,
	"model": DEFAULT_MODEL,
	"max_tokens": DEFAULT_MAX_TOKENS,
	"enable_thinking": true,
	"thinking_budget": DEFAULT_THINKING_BUDGET,
	"temperature": DEFAULT_TEMPERATURE,
	"top_p": DEFAULT_TOP_P,
	"top_k": DEFAULT_TOP_K,
	"min_p": DEFAULT_MIN_P,
	"frequency_penalty": DEFAULT_FREQUENCY_PENALTY,
	"stop": null
}

func _ready() -> void:
	_initialize_ui()
	_connect_signals()
	_load_settings()
	_apply_settings_to_ui()

func _initialize_ui() -> void:
	for model: String in MODELS:
		model_option.add_item(model)

func _connect_signals() -> void:
	%SaveButton.pressed.connect(_on_save_button_pressed)
	%CancelButton.pressed.connect(_on_cancel_button_pressed)

func _on_save_button_pressed() -> void:
	_save_settings_from_ui()
	_save_settings()
	settings_changed.emit(current_settings)
	hide()

func _on_cancel_button_pressed() -> void:
	_apply_settings_to_ui()
	hide()

func _save_settings_from_ui() -> void:
	current_settings["api_key"] = api_key_input.text.strip_edges()
	current_settings["model"] = MODELS[model_option.selected]
	current_settings["max_tokens"] = int(max_tokens_spin.value)
	current_settings["enable_thinking"] = enable_thinking_check.button_pressed
	current_settings["thinking_budget"] = int(thinking_budget_spin.value)
	current_settings["temperature"] = temperature_spin.value
	current_settings["top_p"] = top_p_spin.value
	current_settings["top_k"] = int(top_k_spin.value)
	current_settings["min_p"] = min_p_spin.value
	current_settings["frequency_penalty"] = frequency_penalty_spin.value

	var stop_text: String = stop_input.text.strip_edges()
	if not stop_text.is_empty():
		current_settings["stop"] = stop_text
	else:
		current_settings["stop"] = null

func _apply_settings_to_ui() -> void:
	api_key_input.text = current_settings.get("api_key", DEFAULT_API_KEY)

	var model_index: int = MODELS.find(current_settings["model"])
	model_option.selected = model_index if model_index >= 0 else 0

	max_tokens_spin.value = current_settings["max_tokens"]
	enable_thinking_check.button_pressed = current_settings["enable_thinking"]
	thinking_budget_spin.value = current_settings["thinking_budget"]
	temperature_spin.value = current_settings["temperature"]
	top_p_spin.value = current_settings["top_p"]
	top_k_spin.value = current_settings["top_k"]
	min_p_spin.value = current_settings["min_p"]
	frequency_penalty_spin.value = current_settings["frequency_penalty"]

	stop_input.text = str(current_settings["stop"]) if current_settings["stop"] != null else ""

func _save_settings() -> void:
	var config := ConfigFile.new()
	for key: String in current_settings:
		config.set_value(CONFIG_SECTION, key, current_settings[key])
	var err: Error = config.save(CONFIG_FILE_PATH)
	if err != OK:
		push_error("Failed to save settings: " + error_string(err))

func _load_settings() -> void:
	var config := ConfigFile.new()
	var err: Error = config.load(CONFIG_FILE_PATH)
	if err == OK:
		for key: String in current_settings:
			if config.has_section_key(CONFIG_SECTION, key):
				current_settings[key] = config.get_value(CONFIG_SECTION, key)

func get_settings() -> Dictionary:
	return current_settings.duplicate()
