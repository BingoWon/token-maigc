extends PanelContainer
class_name MessageBubble

# UI References
@onready var label: RichTextLabel = $MarginContainer/Label

# Enums
enum Role { USER, ASSISTANT }
enum CornerStyle { USER, ASSISTANT }

# Style Constants
const CORNER_RADIUS: int = 15
const CORNER_RADIUS_SMALL: int = 5
const PADDING_HORIZONTAL: int = 12
const PADDING_VERTICAL: int = 8

const USER_COLOR: Color = Color(0.2, 0.4, 0.8, 0.9)
const ASSISTANT_COLOR: Color = Color(0.25, 0.25, 0.28, 0.95)
const THINKING_COLOR: Color = Color(0.22, 0.22, 0.25, 0.85)

const TEXT_COLOR_WHITE: Color = Color.WHITE
const TEXT_COLOR_LIGHT: Color = Color(0.95, 0.95, 0.95)
const TEXT_COLOR_DIM: Color = Color(0.7, 0.7, 0.75)

const THINKING_FONT_SIZE: int = 14
const THINKING_PREFIX: String = "[i]💭 Thinking...[/i]\n"

func setup(role: Role, text: String) -> void:
	if not is_node_ready():
		await ready
	label.text = text

	match role:
		Role.USER:
			_apply_style(USER_COLOR, TEXT_COLOR_WHITE, Control.SIZE_SHRINK_END, CornerStyle.USER)
		Role.ASSISTANT:
			_apply_style(ASSISTANT_COLOR, TEXT_COLOR_LIGHT, Control.SIZE_SHRINK_BEGIN, CornerStyle.ASSISTANT)

func setup_thinking(text: String) -> void:
	if not is_node_ready():
		await ready
	label.text = THINKING_PREFIX + text
	_apply_style(THINKING_COLOR, TEXT_COLOR_DIM, Control.SIZE_SHRINK_BEGIN, CornerStyle.ASSISTANT)
	label.add_theme_font_size_override("normal_font_size", THINKING_FONT_SIZE)

func update_text(text: String, is_thinking: bool = false) -> void:
	if is_node_ready():
		label.text = THINKING_PREFIX + text if is_thinking else text

func _apply_style(
	bg_color: Color,
	text_color: Color,
	alignment: int,
	corner_style: CornerStyle
) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color

	# Set corner radii based on style
	match corner_style:
		CornerStyle.USER:
			style.corner_radius_top_left = CORNER_RADIUS
			style.corner_radius_top_right = CORNER_RADIUS
			style.corner_radius_bottom_left = CORNER_RADIUS
			style.corner_radius_bottom_right = CORNER_RADIUS_SMALL
		CornerStyle.ASSISTANT:
			style.corner_radius_top_left = CORNER_RADIUS
			style.corner_radius_top_right = CORNER_RADIUS
			style.corner_radius_bottom_left = CORNER_RADIUS_SMALL
			style.corner_radius_bottom_right = CORNER_RADIUS

	style.content_margin_left = PADDING_HORIZONTAL
	style.content_margin_right = PADDING_HORIZONTAL
	style.content_margin_top = PADDING_VERTICAL
	style.content_margin_bottom = PADDING_VERTICAL

	add_theme_stylebox_override("panel", style)
	label.add_theme_color_override("default_color", text_color)
	size_flags_horizontal = alignment
