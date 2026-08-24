#ifndef TUI_H_INCLUDED
#define TUI_H_INCLUDED

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TUI_ABI_MAJOR_V1 1u
#define TUI_ABI_MINOR_V1 0u
#define TUI_EVENT_PAYLOAD_CAPACITY_V1 256u
#define TUI_PROVIDER_BATCH_CAPACITY_V1 64u

typedef int32_t tui_result_v1;
typedef int32_t tui_update_v1;

enum {
    TUI_OK_V1 = 0,
    TUI_ERROR_INVALID_ARGUMENT_V1 = -1,
    TUI_ERROR_OUT_OF_MEMORY_V1 = -2,
    TUI_ERROR_CAPACITY_V1 = -3,
    TUI_ERROR_INVALID_TEXT_V1 = -4,
    TUI_ERROR_BUFFER_TOO_SMALL_V1 = -5,
    TUI_ERROR_QUEUE_FULL_V1 = -6,
    TUI_ERROR_QUEUE_EMPTY_V1 = -7,
    TUI_ERROR_OUTPUT_V1 = -8,
    TUI_ERROR_PROVIDER_V1 = -9,
    TUI_ERROR_INVALID_STATE_V1 = -10,
    TUI_ERROR_UNSUPPORTED_V1 = -11
};

enum {
    TUI_UPDATE_IGNORED_V1 = 0,
    TUI_UPDATE_HANDLED_V1 = 1,
    TUI_UPDATE_REDRAW_V1 = 2,
    TUI_UPDATE_RELAYOUT_V1 = 3
};

typedef struct { uint32_t major, minor, patch; } tui_version_v1;
typedef struct { const uint8_t *ptr; uint64_t len; } tui_bytes_v1;
typedef tui_bytes_v1 tui_utf8_v1;
typedef struct { uint16_t width, height; } tui_size_v1;
typedef struct { uint16_t x, y; } tui_point_v1;
typedef struct { uint16_t x, y, width, height; } tui_rect_v1;

enum { TUI_COLOR_DEFAULT_V1 = 0, TUI_COLOR_INDEXED_V1 = 1, TUI_COLOR_RGB_V1 = 2 };
typedef struct {
    int32_t kind;
    uint8_t index, red, green, blue;
    uint8_t reserved[3];
} tui_color_v1;
typedef struct {
    tui_color_v1 foreground;
    tui_color_v1 background;
    uint8_t attributes;
    uint8_t reserved[3];
} tui_style_v1;
typedef struct {
    tui_style_v1 normal, focused, disabled;
    uint8_t has_focused, has_disabled;
    uint8_t reserved[2];
} tui_role_v1;

enum { TUI_WIDTH_NARROW_V1 = 0, TUI_WIDTH_WIDE_AMBIGUOUS_V1 = 1 };
enum { TUI_ALIGN_LEFT_V1 = 0, TUI_ALIGN_CENTER_V1 = 1, TUI_ALIGN_RIGHT_V1 = 2 };

enum {
    TUI_EVENT_KEY_V1 = 1,
    TUI_EVENT_TEXT_V1 = 2,
    TUI_EVENT_MOUSE_V1 = 3,
    TUI_EVENT_PASTE_START_V1 = 4,
    TUI_EVENT_PASTE_CHUNK_V1 = 5,
    TUI_EVENT_PASTE_END_V1 = 6,
    TUI_EVENT_FOCUS_IN_V1 = 7,
    TUI_EVENT_FOCUS_OUT_V1 = 8,
    TUI_EVENT_CURSOR_POSITION_V1 = 9,
    TUI_EVENT_TERMINAL_REPLY_V1 = 10,
    TUI_EVENT_MALFORMED_V1 = 11
};
enum {
    TUI_KEY_CODEPOINT_V1 = 0, TUI_KEY_FUNCTIONAL_V1 = 1, TUI_KEY_ESCAPE_V1 = 2,
    TUI_KEY_ENTER_V1 = 3, TUI_KEY_TAB_V1 = 4, TUI_KEY_BACKSPACE_V1 = 5,
    TUI_KEY_UP_V1 = 6, TUI_KEY_DOWN_V1 = 7, TUI_KEY_LEFT_V1 = 8,
    TUI_KEY_RIGHT_V1 = 9, TUI_KEY_HOME_V1 = 10, TUI_KEY_END_V1 = 11,
    TUI_KEY_INSERT_V1 = 12, TUI_KEY_DELETE_V1 = 13, TUI_KEY_PAGE_UP_V1 = 14,
    TUI_KEY_PAGE_DOWN_V1 = 15, TUI_KEY_FUNCTION_V1 = 16
};
enum { TUI_KEY_PRESS_V1 = 0, TUI_KEY_REPEAT_V1 = 1, TUI_KEY_RELEASE_V1 = 2 };
enum {
    TUI_MODIFIER_SHIFT_V1 = 1u << 0,
    TUI_MODIFIER_ALT_V1 = 1u << 1,
    TUI_MODIFIER_CONTROL_V1 = 1u << 2,
    TUI_MODIFIER_SUPER_V1 = 1u << 3,
    TUI_MODIFIER_HYPER_V1 = 1u << 4,
    TUI_MODIFIER_META_V1 = 1u << 5,
    TUI_MODIFIER_CAPS_LOCK_V1 = 1u << 6,
    TUI_MODIFIER_NUM_LOCK_V1 = 1u << 7
};
enum { TUI_MOUSE_NONE_V1 = 0, TUI_MOUSE_LEFT_V1 = 1, TUI_MOUSE_MIDDLE_V1 = 2, TUI_MOUSE_RIGHT_V1 = 3 };
enum {
    TUI_MOUSE_PRESS_V1 = 0, TUI_MOUSE_RELEASE_V1 = 1, TUI_MOUSE_MOVE_V1 = 2,
    TUI_MOUSE_SCROLL_UP_V1 = 3, TUI_MOUSE_SCROLL_DOWN_V1 = 4,
    TUI_MOUSE_SCROLL_LEFT_V1 = 5, TUI_MOUSE_SCROLL_RIGHT_V1 = 6
};
enum { TUI_REPLY_CSI_V1 = 0, TUI_REPLY_OSC_V1 = 1, TUI_REPLY_APC_V1 = 2 };

typedef struct {
    int32_t kind;
    int32_t key_kind;
    uint32_t key_value;
    uint8_t modifiers, key_action, mouse_button, mouse_action;
    uint16_t x, y;
    int32_t reply_kind;
    uint8_t reply_final;
    uint8_t reserved[3];
    tui_bytes_v1 payload;
} tui_event_v1;

typedef struct tui_renderer_v1 tui_renderer_v1;
typedef struct tui_text_input_v1 tui_text_input_v1;
typedef struct tui_text_area_v1 tui_text_area_v1;
typedef struct tui_line_chart_v1 tui_line_chart_v1;
typedef struct tui_event_queue_v1 tui_event_queue_v1;
typedef struct tui_parser_v1 tui_parser_v1;

typedef struct {
    uint64_t max_cells;
    uint32_t grapheme_capacity;
    uint16_t style_capacity, image_capacity;
    uint8_t tile_width, tile_height;
    uint8_t reserved[6];
} tui_renderer_config_v1;

enum { TUI_COLOR_ANSI16_V1 = 0, TUI_COLOR_INDEXED256_V1 = 1, TUI_COLOR_TRUECOLOR_V1 = 2 };
enum { TUI_IMAGE_NONE_V1 = 0, TUI_IMAGE_KITTY_V1 = 1, TUI_IMAGE_ITERM2_V1 = 2, TUI_IMAGE_SIXEL_V1 = 3 };
typedef struct {
    int32_t color_depth, image_protocol;
    uint8_t synchronized_output, background_color_erase;
    uint8_t reserved[6];
} tui_capabilities_v1;
typedef struct {
    uint64_t bytes;
    uint32_t cells_compared, cells_changed, runs;
    uint16_t dirty_rows;
    uint8_t full_repaint;
    uint8_t reserved;
} tui_frame_stats_v1;
typedef tui_result_v1 (*tui_write_fn_v1)(void *context, const uint8_t *bytes, uint64_t len);
typedef struct { void *context; tui_write_fn_v1 write; } tui_output_v1;

enum { TUI_PIXELS_RGB8_V1 = 0, TUI_PIXELS_RGBA8_V1 = 1 };
typedef struct { tui_bytes_v1 pixels; uint32_t width, height; int32_t format; } tui_image_v1;
typedef struct {
    uint32_t image_id, placement_id;
    uint8_t background_red, background_green, background_blue, reserved;
} tui_image_options_v1;

tui_version_v1 tui_abi_version_v1(void);
tui_result_v1 tui_renderer_create_v1(tui_size_v1 size, const tui_renderer_config_v1 *config, tui_renderer_v1 **out);
void tui_renderer_destroy_v1(tui_renderer_v1 *renderer);
tui_result_v1 tui_renderer_resize_v1(tui_renderer_v1 *renderer, tui_size_v1 size);
tui_result_v1 tui_renderer_begin_frame_v1(tui_renderer_v1 *renderer);
void tui_renderer_invalidate_terminal_v1(tui_renderer_v1 *renderer);
tui_result_v1 tui_renderer_put_image_v1(tui_renderer_v1 *renderer, tui_rect_v1 bounds, tui_image_v1 image, tui_image_options_v1 options);
tui_result_v1 tui_renderer_present_v1(tui_renderer_v1 *renderer, tui_capabilities_v1 capabilities, tui_output_v1 output, tui_frame_stats_v1 *stats);

typedef struct { tui_utf8_v1 text; tui_role_v1 role; uint8_t enabled, focused, width_profile, alignment; } tui_text_desc_v1;
typedef struct { tui_utf8_v1 title; tui_role_v1 border_role, title_role; uint8_t enabled, focused; uint8_t reserved[2]; } tui_panel_desc_v1;
typedef struct { uint64_t value, total; tui_role_v1 filled_role, empty_role; uint8_t enabled; uint8_t reserved[7]; } tui_gauge_desc_v1;

tui_result_v1 tui_label_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_text_desc_v1 *);
tui_result_v1 tui_paragraph_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_text_desc_v1 *);
tui_result_v1 tui_panel_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_panel_desc_v1 *);
tui_result_v1 tui_panel_content_rect_v1(tui_rect_v1, tui_rect_v1 *out);
tui_result_v1 tui_gauge_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_gauge_desc_v1 *);

typedef struct { uint8_t activated; uint8_t reserved[7]; } tui_button_state_v1;
typedef struct { uint8_t checked; uint8_t reserved[7]; } tui_checkbox_state_v1;
typedef struct { uint32_t selected; uint8_t has_selected; uint8_t reserved[3]; } tui_radio_state_v1;
typedef struct { tui_utf8_v1 label; tui_role_v1 role, indicator_role; uint8_t enabled, focused; uint8_t reserved[2]; } tui_control_desc_v1;

tui_result_v1 tui_button_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_control_desc_v1 *, tui_button_state_v1 *);
tui_result_v1 tui_button_handle_v1(const tui_control_desc_v1 *, tui_button_state_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_checkbox_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_control_desc_v1 *, tui_checkbox_state_v1 *);
tui_result_v1 tui_checkbox_handle_v1(const tui_control_desc_v1 *, tui_checkbox_state_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_radio_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_control_desc_v1 *, tui_radio_state_v1 *, uint32_t value);
tui_result_v1 tui_radio_handle_v1(const tui_control_desc_v1 *, tui_radio_state_v1 *, uint32_t value, const tui_event_v1 *, tui_update_v1 *);

tui_result_v1 tui_text_input_create_v1(uint64_t capacity, tui_utf8_v1 initial, tui_text_input_v1 **out);
void tui_text_input_destroy_v1(tui_text_input_v1 *);
tui_result_v1 tui_text_input_draw_v1(tui_text_input_v1 *, tui_renderer_v1 *, tui_rect_v1);
tui_result_v1 tui_text_input_handle_v1(tui_text_input_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_text_input_set_focus_v1(tui_text_input_v1 *, uint8_t focused);
tui_result_v1 tui_text_input_set_selection_v1(tui_text_input_v1 *, uint64_t anchor, uint64_t cursor);
tui_result_v1 tui_text_input_replace_selection_v1(tui_text_input_v1 *, tui_utf8_v1 text);
tui_result_v1 tui_text_input_copy_value_v1(const tui_text_input_v1 *, uint8_t *out, uint64_t capacity, uint64_t *needed);
tui_result_v1 tui_text_input_take_failure_v1(tui_text_input_v1 *, int32_t *failure);

tui_result_v1 tui_text_area_create_v1(uint64_t capacity, tui_utf8_v1 initial, tui_text_area_v1 **out);
void tui_text_area_destroy_v1(tui_text_area_v1 *);
tui_result_v1 tui_text_area_layout_v1(tui_text_area_v1 *, tui_size_v1);
tui_result_v1 tui_text_area_draw_v1(tui_text_area_v1 *, tui_renderer_v1 *, tui_rect_v1);
tui_result_v1 tui_text_area_handle_v1(tui_text_area_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_text_area_set_focus_v1(tui_text_area_v1 *, uint8_t focused);
tui_result_v1 tui_text_area_set_soft_wrap_v1(tui_text_area_v1 *, uint8_t enabled);
tui_result_v1 tui_text_area_copy_value_v1(const tui_text_area_v1 *, uint8_t *out, uint64_t capacity, uint64_t *needed);
tui_result_v1 tui_text_area_take_failure_v1(tui_text_area_v1 *, int32_t *failure);

typedef struct { uint64_t top, selected; uint8_t has_selected; uint8_t reserved[7]; } tui_scroll_state_v1;
typedef struct {
    tui_utf8_v1 text;
    const tui_utf8_v1 *cells;
    uint32_t cell_count, depth;
    int32_t status;
    uint32_t flags;
} tui_provider_row_v1;
typedef tui_result_v1 (*tui_rows_read_fn_v1)(void *context, uint64_t first, uint32_t count, tui_provider_row_v1 *rows);
typedef struct { void *context; uint64_t count; tui_rows_read_fn_v1 read; } tui_rows_provider_v1;
typedef struct { tui_utf8_v1 title; uint16_t width; uint16_t reserved; } tui_column_v1;
enum { TUI_ROW_HAS_CHILDREN_V1 = 1u << 0, TUI_ROW_EXPANDED_V1 = 1u << 1 };
enum {
    TUI_TASK_PENDING_V1 = 0, TUI_TASK_RUNNING_V1 = 1, TUI_TASK_SUCCEEDED_V1 = 2,
    TUI_TASK_FAILED_V1 = 3, TUI_TASK_CANCELLED_V1 = 4
};
typedef struct { tui_role_v1 row_role, selected_role, header_role; uint8_t enabled, focused, width_profile; uint8_t reserved; } tui_collection_desc_v1;
typedef struct { tui_scroll_state_v1 scroll; uint64_t activated; uint8_t has_activated; uint8_t reserved[7]; } tui_menu_state_v1;
typedef struct { tui_scroll_state_v1 scroll; uint64_t toggled, activated; uint8_t has_toggled, has_activated; uint8_t reserved[6]; } tui_tree_state_v1;

tui_result_v1 tui_scrollback_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_collection_desc_v1 *, tui_scroll_state_v1 *, const tui_rows_provider_v1 *);
tui_result_v1 tui_scrollback_handle_v1(tui_rect_v1, tui_scroll_state_v1 *, const tui_rows_provider_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_list_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_collection_desc_v1 *, tui_scroll_state_v1 *, const tui_rows_provider_v1 *);
tui_result_v1 tui_list_handle_v1(tui_rect_v1, tui_scroll_state_v1 *, const tui_rows_provider_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_table_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_collection_desc_v1 *, tui_scroll_state_v1 *, const tui_rows_provider_v1 *, const tui_column_v1 *, uint32_t column_count);
tui_result_v1 tui_table_handle_v1(tui_rect_v1, tui_scroll_state_v1 *, const tui_rows_provider_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_tree_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_collection_desc_v1 *, tui_tree_state_v1 *, const tui_rows_provider_v1 *);
tui_result_v1 tui_tree_handle_v1(tui_rect_v1, tui_tree_state_v1 *, const tui_rows_provider_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_task_list_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_collection_desc_v1 *, tui_menu_state_v1 *, const tui_rows_provider_v1 *);
tui_result_v1 tui_task_list_handle_v1(tui_rect_v1, tui_menu_state_v1 *, const tui_rows_provider_v1 *, const tui_event_v1 *, tui_update_v1 *);
tui_result_v1 tui_menu_draw_v1(tui_renderer_v1 *, tui_rect_v1, const tui_collection_desc_v1 *, tui_menu_state_v1 *, const tui_rows_provider_v1 *);
tui_result_v1 tui_menu_handle_v1(tui_rect_v1, tui_menu_state_v1 *, const tui_rows_provider_v1 *, const tui_event_v1 *, tui_update_v1 *);

typedef tui_result_v1 (*tui_samples_read_fn_v1)(void *context, uint64_t first, uint32_t count, double *samples);
typedef struct { void *context; uint64_t count; tui_samples_read_fn_v1 read; } tui_samples_provider_v1;
tui_result_v1 tui_line_chart_create_v1(uint64_t sample_capacity, uint64_t cell_capacity, tui_line_chart_v1 **out);
void tui_line_chart_destroy_v1(tui_line_chart_v1 *);
tui_result_v1 tui_line_chart_draw_v1(tui_line_chart_v1 *, tui_renderer_v1 *, tui_rect_v1, const tui_samples_provider_v1 *, tui_role_v1);

/* The bounded event queue supports one producer and one consumer concurrently. */
tui_result_v1 tui_event_queue_create_v1(uint64_t capacity, tui_event_queue_v1 **out);
void tui_event_queue_destroy_v1(tui_event_queue_v1 *);
tui_result_v1 tui_event_queue_try_push_v1(tui_event_queue_v1 *, const tui_event_v1 *);
tui_result_v1 tui_event_queue_try_pop_v1(tui_event_queue_v1 *, uint8_t *payload, uint64_t capacity, tui_event_v1 *out);
tui_result_v1 tui_parser_create_v1(tui_parser_v1 **out);
void tui_parser_destroy_v1(tui_parser_v1 *);
tui_result_v1 tui_parser_feed_v1(tui_parser_v1 *, tui_bytes_v1, tui_event_queue_v1 *);
tui_result_v1 tui_parser_finish_v1(tui_parser_v1 *, tui_event_queue_v1 *);
tui_result_v1 tui_parser_abort_v1(tui_parser_v1 *, tui_event_queue_v1 *);

#ifdef __cplusplus
}
#endif

#endif
