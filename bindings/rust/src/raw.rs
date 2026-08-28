#![allow(non_camel_case_types)]

use core::ffi::{c_double, c_int, c_void};

pub type tui_result_v1 = i32;
pub type tui_update_v1 = i32;

pub const TUI_OK_V1: i32 = 0;
pub const TUI_ERROR_INVALID_ARGUMENT_V1: i32 = -1;
pub const TUI_ERROR_OUT_OF_MEMORY_V1: i32 = -2;
pub const TUI_ERROR_CAPACITY_V1: i32 = -3;
pub const TUI_ERROR_INVALID_TEXT_V1: i32 = -4;
pub const TUI_ERROR_BUFFER_TOO_SMALL_V1: i32 = -5;
pub const TUI_ERROR_QUEUE_FULL_V1: i32 = -6;
pub const TUI_ERROR_QUEUE_EMPTY_V1: i32 = -7;
pub const TUI_ERROR_OUTPUT_V1: i32 = -8;
pub const TUI_ERROR_PROVIDER_V1: i32 = -9;
pub const TUI_ERROR_INVALID_STATE_V1: i32 = -10;
pub const TUI_ERROR_UNSUPPORTED_V1: i32 = -11;

pub const TUI_UPDATE_IGNORED_V1: i32 = 0;
pub const TUI_UPDATE_HANDLED_V1: i32 = 1;
pub const TUI_UPDATE_REDRAW_V1: i32 = 2;
pub const TUI_UPDATE_RELAYOUT_V1: i32 = 3;

pub const TUI_EVENT_KEY_V1: i32 = 1;
pub const TUI_EVENT_TEXT_V1: i32 = 2;
pub const TUI_EVENT_MOUSE_V1: i32 = 3;
pub const TUI_EVENT_PASTE_START_V1: i32 = 4;
pub const TUI_EVENT_PASTE_CHUNK_V1: i32 = 5;
pub const TUI_EVENT_PASTE_END_V1: i32 = 6;
pub const TUI_EVENT_FOCUS_IN_V1: i32 = 7;
pub const TUI_EVENT_FOCUS_OUT_V1: i32 = 8;
pub const TUI_EVENT_CURSOR_POSITION_V1: i32 = 9;
pub const TUI_EVENT_TERMINAL_REPLY_V1: i32 = 10;
pub const TUI_EVENT_MALFORMED_V1: i32 = 11;

pub const TUI_KEY_CODEPOINT_V1: i32 = 0;
pub const TUI_KEY_FUNCTIONAL_V1: i32 = 1;
pub const TUI_KEY_ESCAPE_V1: i32 = 2;
pub const TUI_KEY_ENTER_V1: i32 = 3;
pub const TUI_KEY_TAB_V1: i32 = 4;
pub const TUI_KEY_BACKSPACE_V1: i32 = 5;
pub const TUI_KEY_UP_V1: i32 = 6;
pub const TUI_KEY_DOWN_V1: i32 = 7;
pub const TUI_KEY_LEFT_V1: i32 = 8;
pub const TUI_KEY_RIGHT_V1: i32 = 9;
pub const TUI_KEY_HOME_V1: i32 = 10;
pub const TUI_KEY_END_V1: i32 = 11;
pub const TUI_KEY_INSERT_V1: i32 = 12;
pub const TUI_KEY_DELETE_V1: i32 = 13;
pub const TUI_KEY_PAGE_UP_V1: i32 = 14;
pub const TUI_KEY_PAGE_DOWN_V1: i32 = 15;
pub const TUI_KEY_FUNCTION_V1: i32 = 16;

pub const TUI_KEY_PRESS_V1: u8 = 0;
pub const TUI_WIDTH_NARROW_V1: u8 = 0;
pub const TUI_ALIGN_LEFT_V1: u8 = 0;
pub const TUI_ALIGN_CENTER_V1: u8 = 1;
pub const TUI_ALIGN_RIGHT_V1: u8 = 2;
pub const TUI_COLOR_DEFAULT_V1: i32 = 0;
pub const TUI_COLOR_INDEXED_V1: i32 = 1;
pub const TUI_COLOR_RGB_V1: i32 = 2;
pub const TUI_COLOR_TRUECOLOR_V1: i32 = 2;
pub const TUI_IMAGE_NONE_V1: i32 = 0;
pub const TUI_PIXELS_RGB8_V1: i32 = 0;
pub const TUI_ROW_HAS_CHILDREN_V1: u32 = 1;
pub const TUI_ROW_EXPANDED_V1: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct tui_version_v1 {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_bytes_v1 {
    pub ptr: *const u8,
    pub len: u64,
}
pub type tui_utf8_v1 = tui_bytes_v1;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_size_v1 {
    pub width: u16,
    pub height: u16,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_point_v1 {
    pub x: u16,
    pub y: u16,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_rect_v1 {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

pub type tui_allocate_fn_v1 = unsafe extern "C" fn(*mut c_void, u64, u64) -> *mut c_void;
pub type tui_deallocate_fn_v1 = unsafe extern "C" fn(*mut c_void, *mut c_void, u64, u64);
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_allocator_v1 {
    pub context: *mut c_void,
    pub allocate: Option<tui_allocate_fn_v1>,
    pub deallocate: Option<tui_deallocate_fn_v1>,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_color_v1 {
    pub kind: i32,
    pub index: u8,
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub reserved: [u8; 3],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_style_v1 {
    pub foreground: tui_color_v1,
    pub background: tui_color_v1,
    pub attributes: u8,
    pub reserved: [u8; 3],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_role_v1 {
    pub normal: tui_style_v1,
    pub focused: tui_style_v1,
    pub disabled: tui_style_v1,
    pub has_focused: u8,
    pub has_disabled: u8,
    pub reserved: [u8; 2],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_event_v1 {
    pub kind: i32,
    pub key_kind: i32,
    pub key_value: u32,
    pub modifiers: u8,
    pub key_action: u8,
    pub mouse_button: u8,
    pub mouse_action: u8,
    pub x: u16,
    pub y: u16,
    pub reply_kind: i32,
    pub reply_final: u8,
    pub reserved: [u8; 3],
    pub payload: tui_bytes_v1,
}

#[repr(C)]
pub struct tui_renderer_v1 {
    _private: [u8; 0],
}
#[repr(C)]
pub struct tui_text_input_v1 {
    _private: [u8; 0],
}
#[repr(C)]
pub struct tui_text_area_v1 {
    _private: [u8; 0],
}
#[repr(C)]
pub struct tui_line_chart_v1 {
    _private: [u8; 0],
}
#[repr(C)]
pub struct tui_event_queue_v1 {
    _private: [u8; 0],
}
#[repr(C)]
pub struct tui_parser_v1 {
    _private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_renderer_config_v1 {
    pub max_cells: u64,
    pub grapheme_capacity: u32,
    pub style_capacity: u16,
    pub image_capacity: u16,
    pub tile_width: u8,
    pub tile_height: u8,
    pub reserved: [u8; 6],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_capabilities_v1 {
    pub color_depth: i32,
    pub image_protocol: i32,
    pub synchronized_output: u8,
    pub background_color_erase: u8,
    pub reserved: [u8; 6],
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct tui_frame_stats_v1 {
    pub bytes: u64,
    pub cells_compared: u32,
    pub cells_changed: u32,
    pub runs: u32,
    pub dirty_rows: u16,
    pub full_repaint: u8,
    pub reserved: u8,
}
pub type tui_write_fn_v1 = unsafe extern "C" fn(*mut c_void, *const u8, u64) -> i32;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_output_v1 {
    pub context: *mut c_void,
    pub write: Option<tui_write_fn_v1>,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_image_v1 {
    pub pixels: tui_bytes_v1,
    pub width: u32,
    pub height: u32,
    pub format: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_image_options_v1 {
    pub image_id: u32,
    pub placement_id: u32,
    pub background_red: u8,
    pub background_green: u8,
    pub background_blue: u8,
    pub reserved: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_text_desc_v1 {
    pub text: tui_utf8_v1,
    pub role: tui_role_v1,
    pub enabled: u8,
    pub focused: u8,
    pub width_profile: u8,
    pub alignment: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_panel_desc_v1 {
    pub title: tui_utf8_v1,
    pub border_role: tui_role_v1,
    pub title_role: tui_role_v1,
    pub enabled: u8,
    pub focused: u8,
    pub reserved: [u8; 2],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_gauge_desc_v1 {
    pub value: u64,
    pub total: u64,
    pub filled_role: tui_role_v1,
    pub empty_role: tui_role_v1,
    pub enabled: u8,
    pub reserved: [u8; 7],
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct tui_button_state_v1 {
    pub activated: u8,
    pub reserved: [u8; 7],
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct tui_checkbox_state_v1 {
    pub checked: u8,
    pub reserved: [u8; 7],
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct tui_radio_state_v1 {
    pub selected: u32,
    pub has_selected: u8,
    pub reserved: [u8; 3],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_control_desc_v1 {
    pub label: tui_utf8_v1,
    pub role: tui_role_v1,
    pub indicator_role: tui_role_v1,
    pub enabled: u8,
    pub focused: u8,
    pub reserved: [u8; 2],
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct tui_scroll_state_v1 {
    pub top: u64,
    pub selected: u64,
    pub has_selected: u8,
    pub reserved: [u8; 7],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_provider_row_v1 {
    pub text: tui_utf8_v1,
    pub cells: *const tui_utf8_v1,
    pub cell_count: u32,
    pub depth: u32,
    pub status: i32,
    pub flags: u32,
}
pub type tui_rows_read_fn_v1 =
    unsafe extern "C" fn(*mut c_void, u64, u32, *mut tui_provider_row_v1) -> i32;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_rows_provider_v1 {
    pub context: *mut c_void,
    pub count: u64,
    pub read: Option<tui_rows_read_fn_v1>,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_column_v1 {
    pub title: tui_utf8_v1,
    pub width: u16,
    pub reserved: u16,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_collection_desc_v1 {
    pub row_role: tui_role_v1,
    pub selected_role: tui_role_v1,
    pub header_role: tui_role_v1,
    pub enabled: u8,
    pub focused: u8,
    pub width_profile: u8,
    pub reserved: u8,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct tui_menu_state_v1 {
    pub scroll: tui_scroll_state_v1,
    pub activated: u64,
    pub has_activated: u8,
    pub reserved: [u8; 7],
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct tui_tree_state_v1 {
    pub scroll: tui_scroll_state_v1,
    pub toggled: u64,
    pub activated: u64,
    pub has_toggled: u8,
    pub has_activated: u8,
    pub reserved: [u8; 6],
}
pub type tui_samples_read_fn_v1 = unsafe extern "C" fn(*mut c_void, u64, u32, *mut c_double) -> i32;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct tui_samples_provider_v1 {
    pub context: *mut c_void,
    pub count: u64,
    pub read: Option<tui_samples_read_fn_v1>,
}

unsafe extern "C" {
    pub fn tui_abi_version_v1() -> tui_version_v1;
    pub fn tui_renderer_create_v1(
        a: *const tui_allocator_v1,
        size: tui_size_v1,
        config: *const tui_renderer_config_v1,
        out: *mut *mut tui_renderer_v1,
    ) -> i32;
    pub fn tui_renderer_destroy_v1(value: *mut tui_renderer_v1);
    pub fn tui_renderer_resize_v1(value: *mut tui_renderer_v1, size: tui_size_v1) -> i32;
    pub fn tui_renderer_begin_frame_v1(value: *mut tui_renderer_v1) -> i32;
    pub fn tui_renderer_invalidate_terminal_v1(value: *mut tui_renderer_v1);
    pub fn tui_renderer_put_image_v1(
        value: *mut tui_renderer_v1,
        bounds: tui_rect_v1,
        image: tui_image_v1,
        options: tui_image_options_v1,
    ) -> i32;
    pub fn tui_renderer_present_v1(
        value: *mut tui_renderer_v1,
        capabilities: tui_capabilities_v1,
        output: tui_output_v1,
        stats: *mut tui_frame_stats_v1,
    ) -> i32;
    pub fn tui_label_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_text_desc_v1,
    ) -> i32;
    pub fn tui_paragraph_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_text_desc_v1,
    ) -> i32;
    pub fn tui_panel_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_panel_desc_v1,
    ) -> i32;
    pub fn tui_panel_content_rect_v1(b: tui_rect_v1, out: *mut tui_rect_v1) -> i32;
    pub fn tui_gauge_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_gauge_desc_v1,
    ) -> i32;
    pub fn tui_button_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_control_desc_v1,
        s: *mut tui_button_state_v1,
    ) -> i32;
    pub fn tui_button_handle_v1(
        d: *const tui_control_desc_v1,
        s: *mut tui_button_state_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_checkbox_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_control_desc_v1,
        s: *mut tui_checkbox_state_v1,
    ) -> i32;
    pub fn tui_checkbox_handle_v1(
        d: *const tui_control_desc_v1,
        s: *mut tui_checkbox_state_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_radio_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_control_desc_v1,
        s: *mut tui_radio_state_v1,
        v: u32,
    ) -> i32;
    pub fn tui_radio_handle_v1(
        d: *const tui_control_desc_v1,
        s: *mut tui_radio_state_v1,
        v: u32,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_text_input_create_v1(
        a: *const tui_allocator_v1,
        capacity: u64,
        initial: tui_utf8_v1,
        out: *mut *mut tui_text_input_v1,
    ) -> i32;
    pub fn tui_text_input_destroy_v1(value: *mut tui_text_input_v1);
    pub fn tui_text_input_draw_v1(
        value: *mut tui_text_input_v1,
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
    ) -> i32;
    pub fn tui_text_input_handle_v1(
        value: *mut tui_text_input_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_text_input_set_focus_v1(value: *mut tui_text_input_v1, focused: u8) -> i32;
    pub fn tui_text_input_set_selection_v1(
        value: *mut tui_text_input_v1,
        anchor: u64,
        cursor: u64,
    ) -> i32;
    pub fn tui_text_input_replace_selection_v1(
        value: *mut tui_text_input_v1,
        text: tui_utf8_v1,
    ) -> i32;
    pub fn tui_text_input_copy_value_v1(
        value: *const tui_text_input_v1,
        out: *mut u8,
        capacity: u64,
        needed: *mut u64,
    ) -> i32;
    pub fn tui_text_input_take_failure_v1(
        value: *mut tui_text_input_v1,
        failure: *mut c_int,
    ) -> i32;
    pub fn tui_text_area_create_v1(
        a: *const tui_allocator_v1,
        capacity: u64,
        initial: tui_utf8_v1,
        out: *mut *mut tui_text_area_v1,
    ) -> i32;
    pub fn tui_text_area_destroy_v1(value: *mut tui_text_area_v1);
    pub fn tui_text_area_layout_v1(value: *mut tui_text_area_v1, size: tui_size_v1) -> i32;
    pub fn tui_text_area_draw_v1(
        value: *mut tui_text_area_v1,
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
    ) -> i32;
    pub fn tui_text_area_handle_v1(
        value: *mut tui_text_area_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_text_area_set_focus_v1(value: *mut tui_text_area_v1, focused: u8) -> i32;
    pub fn tui_text_area_set_soft_wrap_v1(value: *mut tui_text_area_v1, enabled: u8) -> i32;
    pub fn tui_text_area_copy_value_v1(
        value: *const tui_text_area_v1,
        out: *mut u8,
        capacity: u64,
        needed: *mut u64,
    ) -> i32;
    pub fn tui_text_area_take_failure_v1(value: *mut tui_text_area_v1, failure: *mut c_int) -> i32;
    pub fn tui_scrollback_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_collection_desc_v1,
        s: *mut tui_scroll_state_v1,
        p: *const tui_rows_provider_v1,
    ) -> i32;
    pub fn tui_scrollback_handle_v1(
        b: tui_rect_v1,
        s: *mut tui_scroll_state_v1,
        p: *const tui_rows_provider_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_list_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_collection_desc_v1,
        s: *mut tui_scroll_state_v1,
        p: *const tui_rows_provider_v1,
    ) -> i32;
    pub fn tui_list_handle_v1(
        b: tui_rect_v1,
        s: *mut tui_scroll_state_v1,
        p: *const tui_rows_provider_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_table_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_collection_desc_v1,
        s: *mut tui_scroll_state_v1,
        p: *const tui_rows_provider_v1,
        columns: *const tui_column_v1,
        count: u32,
    ) -> i32;
    pub fn tui_table_handle_v1(
        b: tui_rect_v1,
        s: *mut tui_scroll_state_v1,
        p: *const tui_rows_provider_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_tree_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_collection_desc_v1,
        s: *mut tui_tree_state_v1,
        p: *const tui_rows_provider_v1,
    ) -> i32;
    pub fn tui_tree_handle_v1(
        b: tui_rect_v1,
        s: *mut tui_tree_state_v1,
        p: *const tui_rows_provider_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_task_list_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_collection_desc_v1,
        s: *mut tui_menu_state_v1,
        p: *const tui_rows_provider_v1,
    ) -> i32;
    pub fn tui_task_list_handle_v1(
        b: tui_rect_v1,
        s: *mut tui_menu_state_v1,
        p: *const tui_rows_provider_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_menu_draw_v1(
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        d: *const tui_collection_desc_v1,
        s: *mut tui_menu_state_v1,
        p: *const tui_rows_provider_v1,
    ) -> i32;
    pub fn tui_menu_handle_v1(
        b: tui_rect_v1,
        s: *mut tui_menu_state_v1,
        p: *const tui_rows_provider_v1,
        e: *const tui_event_v1,
        u: *mut i32,
    ) -> i32;
    pub fn tui_line_chart_create_v1(
        a: *const tui_allocator_v1,
        samples: u64,
        cells: u64,
        out: *mut *mut tui_line_chart_v1,
    ) -> i32;
    pub fn tui_line_chart_destroy_v1(value: *mut tui_line_chart_v1);
    pub fn tui_line_chart_draw_v1(
        value: *mut tui_line_chart_v1,
        r: *mut tui_renderer_v1,
        b: tui_rect_v1,
        p: *const tui_samples_provider_v1,
        role: tui_role_v1,
    ) -> i32;
    pub fn tui_event_queue_create_v1(
        a: *const tui_allocator_v1,
        capacity: u64,
        out: *mut *mut tui_event_queue_v1,
    ) -> i32;
    pub fn tui_event_queue_destroy_v1(value: *mut tui_event_queue_v1);
    pub fn tui_event_queue_try_push_v1(
        value: *mut tui_event_queue_v1,
        e: *const tui_event_v1,
    ) -> i32;
    pub fn tui_event_queue_try_pop_v1(
        value: *mut tui_event_queue_v1,
        payload: *mut u8,
        capacity: u64,
        out: *mut tui_event_v1,
    ) -> i32;
    pub fn tui_parser_create_v1(a: *const tui_allocator_v1, out: *mut *mut tui_parser_v1) -> i32;
    pub fn tui_parser_destroy_v1(value: *mut tui_parser_v1);
    pub fn tui_parser_feed_v1(
        value: *mut tui_parser_v1,
        input: tui_bytes_v1,
        q: *mut tui_event_queue_v1,
    ) -> i32;
    pub fn tui_parser_finish_v1(value: *mut tui_parser_v1, q: *mut tui_event_queue_v1) -> i32;
    pub fn tui_parser_abort_v1(value: *mut tui_parser_v1, q: *mut tui_event_queue_v1) -> i32;
}
