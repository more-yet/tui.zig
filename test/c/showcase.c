#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include "tui.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

typedef struct {
    tui_renderer_v1 *renderer;
    tui_text_input_v1 *input;
    tui_text_area_v1 *area;
    tui_line_chart_v1 *chart;
    tui_event_queue_v1 *queue;
    tui_parser_v1 *parser;
    tui_button_state_v1 button;
    tui_checkbox_state_v1 checkbox;
    tui_radio_state_v1 radio;
    tui_scroll_state_v1 scroll;
    tui_menu_state_v1 menu;
    tui_tree_state_v1 tree;
    uint8_t page;
} app;

typedef struct {
    FILE *file;
    uint64_t bytes;
    uint64_t hash;
} output_context;

static struct termios original_termios;
static int terminal_active;
static volatile sig_atomic_t stop_requested;
static volatile sig_atomic_t resize_requested;

static const char *row_labels[] = {
    "renderer", "controls", "editors", "providers", "parser"
};
static const char *row_states[] = {
    "ready", "checked", "editing", "streaming", "bounded"
};
static tui_utf8_v1 row_cells[5][2];
static const double chart_samples[] = {
    1.0, 2.5, 1.5, 4.0, 3.0, 5.5, 4.5, 7.0, 6.0, 8.0, 7.0, 9.0
};
static const uint8_t image_pixels[] = {
    230, 70, 80,  245, 155, 55,  55, 190, 145,  60, 135, 225,
    245, 155, 55, 55, 190, 145,  60, 135, 225,  230, 70, 80,
    55, 190, 145,  60, 135, 225,  230, 70, 80,   245, 155, 55,
    60, 135, 225,  230, 70, 80,   245, 155, 55,  55, 190, 145,
};

static tui_utf8_v1 utf8(const char *value) {
    tui_utf8_v1 result = {(const uint8_t *)value, (uint64_t)strlen(value)};
    return result;
}

static tui_color_v1 indexed(uint8_t value) {
    tui_color_v1 color = {0};
    color.kind = TUI_COLOR_INDEXED_V1;
    color.index = value;
    return color;
}

static tui_style_v1 style(uint8_t foreground, uint8_t background, uint8_t attributes) {
    tui_style_v1 result = {0};
    result.foreground = indexed(foreground);
    result.background = indexed(background);
    result.attributes = attributes;
    return result;
}

static tui_role_v1 role(uint8_t foreground, uint8_t background) {
    tui_role_v1 result = {0};
    result.normal = style(foreground, background, 0);
    result.focused = style(0, 14, 1);
    result.disabled = style(8, background, 0);
    result.has_focused = 1;
    result.has_disabled = 1;
    return result;
}

static void *allocate(void *context, uint64_t size, uint64_t alignment) {
    void *memory = NULL;
    size_t native_alignment;
    (void)context;
    if (size > SIZE_MAX || alignment > SIZE_MAX || alignment == 0) return NULL;
    native_alignment = (size_t)alignment;
    if (native_alignment < sizeof(void *)) native_alignment = sizeof(void *);
    if (posix_memalign(&memory, native_alignment, size == 0 ? 1 : (size_t)size) != 0) return NULL;
    return memory;
}

static void deallocate(void *context, void *memory, uint64_t size, uint64_t alignment) {
    (void)context;
    (void)size;
    (void)alignment;
    free(memory);
}

static const tui_allocator_v1 allocator = {NULL, allocate, deallocate};

static int check_result(tui_result_v1 result, const char *operation) {
    if (result == TUI_OK_V1) return 1;
    fprintf(stderr, "%s failed with tui error %d\n", operation, result);
    return 0;
}

#define CHECK(expression) \
    do { if (!check_result((expression), #expression)) return 0; } while (0)

static tui_result_v1 write_output(void *context, const uint8_t *bytes, uint64_t len) {
    output_context *output = context;
    uint64_t index;
    if (len > SIZE_MAX) return TUI_ERROR_OUTPUT_V1;
    if (output->file != NULL && fwrite(bytes, 1, (size_t)len, output->file) != (size_t)len) {
        return TUI_ERROR_OUTPUT_V1;
    }
    for (index = 0; index < len; ++index) {
        output->hash ^= bytes[index];
        output->hash *= UINT64_C(1099511628211);
    }
    output->bytes += len;
    return TUI_OK_V1;
}

static tui_result_v1 read_rows(
    void *context,
    uint64_t first,
    uint32_t count,
    tui_provider_row_v1 *rows
) {
    uint32_t index;
    (void)context;
    if (first > 5 || count > 5 - first) return TUI_ERROR_PROVIDER_V1;
    for (index = 0; index < count; ++index) {
        uint64_t row_index = first + index;
        memset(&rows[index], 0, sizeof(rows[index]));
        rows[index].text = utf8(row_labels[row_index]);
        row_cells[row_index][0] = utf8(row_labels[row_index]);
        row_cells[row_index][1] = utf8(row_states[row_index]);
        rows[index].cells = row_cells[row_index];
        rows[index].cell_count = 2;
        rows[index].depth = row_index == 1 || row_index == 2 ? 1u : 0u;
        rows[index].status = (int32_t)(row_index % 5);
        if (row_index == 0) rows[index].flags = TUI_ROW_HAS_CHILDREN_V1 | TUI_ROW_EXPANDED_V1;
    }
    return TUI_OK_V1;
}

static tui_result_v1 read_samples(void *context, uint64_t first, uint32_t count, double *samples) {
    uint32_t index;
    (void)context;
    if (first > 12 || count > 12 - first) return TUI_ERROR_PROVIDER_V1;
    for (index = 0; index < count; ++index) samples[index] = chart_samples[first + index];
    return TUI_OK_V1;
}

static tui_control_desc_v1 control(const char *label, int focused) {
    tui_control_desc_v1 result = {0};
    result.label = utf8(label);
    result.role = role(15, 0);
    result.indicator_role = role(10, 0);
    result.enabled = 1;
    result.focused = focused != 0;
    return result;
}

static tui_collection_desc_v1 collection(void) {
    tui_collection_desc_v1 result = {0};
    result.row_role = role(15, 0);
    result.selected_role = role(0, 14);
    result.header_role = role(11, 0);
    result.enabled = 1;
    result.focused = 1;
    result.width_profile = TUI_WIDTH_NARROW_V1;
    return result;
}

static tui_rows_provider_v1 rows_provider(void) {
    tui_rows_provider_v1 result = {NULL, 5, read_rows};
    return result;
}

static int app_init(app *state) {
    tui_version_v1 version;
    memset(state, 0, sizeof(*state));
    version = tui_abi_version_v1();
    if (version.major != TUI_ABI_MAJOR_V1
#if TUI_ABI_MINOR_V1 > 0
        || version.minor < TUI_ABI_MINOR_V1
#endif
    ) {
        fprintf(stderr, "unsupported tui ABI %u.%u.%u\n", version.major, version.minor, version.patch);
        return 0;
    }
    CHECK(tui_renderer_create_v1(&allocator, (tui_size_v1){80, 24}, NULL, &state->renderer));
    CHECK(tui_text_input_create_v1(&allocator, 128, utf8("edit me"), &state->input));
    CHECK(tui_text_area_create_v1(
        &allocator,
        1024,
        utf8("Unicode: e\xCC\x81 and \xE4\xB8\x96\xE7\x95\x8C\nSoft-wrapped editor"),
        &state->area
    ));
    CHECK(tui_line_chart_create_v1(&allocator, 64, 80 * 24, &state->chart));
    CHECK(tui_event_queue_create_v1(&allocator, 64, &state->queue));
    CHECK(tui_parser_create_v1(&allocator, &state->parser));
    return 1;
}

static void app_deinit(app *state) {
    tui_parser_destroy_v1(state->parser);
    tui_event_queue_destroy_v1(state->queue);
    tui_line_chart_destroy_v1(state->chart);
    tui_text_area_destroy_v1(state->area);
    tui_text_input_destroy_v1(state->input);
    tui_renderer_destroy_v1(state->renderer);
    memset(state, 0, sizeof(*state));
}

static int pop_event(app *state, tui_event_v1 *event) {
    static uint8_t payload[TUI_EVENT_PAYLOAD_CAPACITY_V1];
    return tui_event_queue_try_pop_v1(state->queue, payload, sizeof(payload), event);
}

static int exercise_nonvisual_api(app *state) {
    tui_control_desc_v1 button_desc = control("Activate", 1);
    tui_control_desc_v1 checkbox_desc = control("Checked", 1);
    tui_control_desc_v1 radio_desc = control("Choice two", 1);
    tui_rows_provider_v1 rows = rows_provider();
    tui_event_v1 event = {0};
    tui_event_v1 popped = {0};
    tui_update_v1 update;
    uint8_t value[1024];
    uint64_t needed;
    int32_t failure;

    event.kind = TUI_EVENT_KEY_V1;
    event.key_kind = TUI_KEY_ENTER_V1;
    event.key_action = TUI_KEY_PRESS_V1;
    CHECK(tui_button_handle_v1(&button_desc, &state->button, &event, &update));
    CHECK(tui_checkbox_handle_v1(&checkbox_desc, &state->checkbox, &event, &update));
    CHECK(tui_radio_handle_v1(&radio_desc, &state->radio, 2, &event, &update));

    event.key_kind = TUI_KEY_DOWN_V1;
    CHECK(tui_scrollback_handle_v1((tui_rect_v1){2, 2, 24, 4}, &state->scroll, &rows, &event, &update));
    CHECK(tui_list_handle_v1((tui_rect_v1){2, 7, 24, 4}, &state->scroll, &rows, &event, &update));
    CHECK(tui_table_handle_v1((tui_rect_v1){28, 2, 28, 7}, &state->scroll, &rows, &event, &update));
    CHECK(tui_tree_handle_v1((tui_rect_v1){2, 12, 24, 5}, &state->tree, &rows, &event, &update));
    CHECK(tui_task_list_handle_v1((tui_rect_v1){28, 10, 28, 6}, &state->menu, &rows, &event, &update));
    CHECK(tui_menu_handle_v1((tui_rect_v1){2, 18, 24, 4}, &state->menu, &rows, &event, &update));

    CHECK(tui_text_input_set_focus_v1(state->input, 1));
    CHECK(tui_text_input_set_selection_v1(state->input, 0, 4));
    CHECK(tui_text_input_replace_selection_v1(state->input, utf8("type")));
    event.kind = TUI_EVENT_TEXT_V1;
    event.payload = utf8("!");
    CHECK(tui_text_input_handle_v1(state->input, &event, &update));
    CHECK(tui_text_input_copy_value_v1(state->input, value, sizeof(value), &needed));
    CHECK(tui_text_input_take_failure_v1(state->input, &failure));

    CHECK(tui_text_area_set_focus_v1(state->area, 1));
    CHECK(tui_text_area_set_soft_wrap_v1(state->area, 1));
    CHECK(tui_text_area_layout_v1(state->area, (tui_size_v1){48, 8}));
    CHECK(tui_text_area_handle_v1(state->area, &event, &update));
    CHECK(tui_text_area_copy_value_v1(state->area, value, sizeof(value), &needed));
    CHECK(tui_text_area_take_failure_v1(state->area, &failure));

    event.kind = TUI_EVENT_TEXT_V1;
    event.payload = utf8("queued");
    CHECK(tui_event_queue_try_push_v1(state->queue, &event));
    CHECK(pop_event(state, &popped));
    CHECK(tui_parser_feed_v1(state->parser, utf8("p"), state->queue));
    CHECK(pop_event(state, &popped));
    CHECK(tui_parser_finish_v1(state->parser, state->queue));
    CHECK(tui_parser_abort_v1(state->parser, state->queue));
    tui_renderer_invalidate_terminal_v1(state->renderer);
    return 1;
}

static int draw_frame(app *state, tui_size_v1 size, output_context *output_context_value) {
    tui_panel_desc_v1 outer = {0};
    tui_text_desc_v1 text_desc = {0};
    tui_gauge_desc_v1 gauge = {0};
    tui_rect_v1 content_bounds;
    tui_capabilities_v1 capabilities = {0};
    tui_frame_stats_v1 stats = {0};
    tui_output_v1 output = {output_context_value, write_output};

    CHECK(tui_renderer_resize_v1(state->renderer, size));
    CHECK(tui_renderer_begin_frame_v1(state->renderer));
    outer.title = utf8(state->page == 0 ? " tui.zig C ABI: controls " : " tui.zig C ABI: data ");
    outer.border_role = role(14, 0);
    outer.title_role = role(11, 0);
    outer.enabled = 1;
    outer.focused = 1;
    CHECK(tui_panel_draw_v1(state->renderer, (tui_rect_v1){0, 0, size.width, size.height}, &outer));
    CHECK(tui_panel_content_rect_v1((tui_rect_v1){0, 0, size.width, size.height}, &content_bounds));

    if (size.width < 80 || size.height < 24) {
        text_desc.text = utf8("The showcase needs an 80x24 terminal.");
        text_desc.role = role(15, 0);
        text_desc.enabled = 1;
        text_desc.width_profile = TUI_WIDTH_NARROW_V1;
        text_desc.alignment = TUI_ALIGN_CENTER_V1;
        CHECK(tui_paragraph_draw_v1(
            state->renderer,
            (tui_rect_v1){content_bounds.x, content_bounds.y, content_bounds.width, content_bounds.height},
            &text_desc
        ));
    } else if (state->page == 0) {
        tui_control_desc_v1 button_desc = control("Activate", 1);
        tui_control_desc_v1 checkbox_desc = control("Checked", 1);
        tui_control_desc_v1 radio_desc = control("Choice two", 1);
        text_desc.text = utf8("All bindings call the same versioned C ABI. Tab changes page; q or Escape quits.");
        text_desc.role = role(15, 0);
        text_desc.enabled = 1;
        text_desc.width_profile = TUI_WIDTH_NARROW_V1;
        text_desc.alignment = TUI_ALIGN_LEFT_V1;
        CHECK(tui_paragraph_draw_v1(state->renderer, (tui_rect_v1){2, 2, size.width > 4 ? size.width - 4 : 0, 2}, &text_desc));
        text_desc.text = utf8("Unicode 17: e\xCC\x81  \xE4\xB8\x96\xE7\x95\x8C  \xF0\x9F\xA6\x80");
        CHECK(tui_label_draw_v1(state->renderer, (tui_rect_v1){2, 5, 44, 1}, &text_desc));
        gauge.value = 73;
        gauge.total = 100;
        gauge.filled_role = role(0, 10);
        gauge.empty_role = role(8, 0);
        gauge.enabled = 1;
        CHECK(tui_gauge_draw_v1(state->renderer, (tui_rect_v1){2, 7, 44, 1}, &gauge));
        CHECK(tui_button_draw_v1(state->renderer, (tui_rect_v1){2, 10, 18, 1}, &button_desc, &state->button));
        CHECK(tui_checkbox_draw_v1(state->renderer, (tui_rect_v1){2, 12, 18, 1}, &checkbox_desc, &state->checkbox));
        CHECK(tui_radio_draw_v1(state->renderer, (tui_rect_v1){2, 14, 18, 1}, &radio_desc, &state->radio, 2));
        CHECK(tui_text_input_draw_v1(state->input, state->renderer, (tui_rect_v1){28, 10, 48, 1}));
        CHECK(tui_text_area_layout_v1(state->area, (tui_size_v1){48, 8}));
        CHECK(tui_text_area_draw_v1(state->area, state->renderer, (tui_rect_v1){28, 13, 48, 8}));
    } else {
        tui_collection_desc_v1 desc = collection();
        tui_rows_provider_v1 rows = rows_provider();
        tui_samples_provider_v1 samples = {NULL, 12, read_samples};
        tui_column_v1 columns[2] = {
            {utf8("component"), 14, 0},
            {utf8("state"), 11, 0},
        };
        tui_image_v1 image = {{image_pixels, sizeof(image_pixels)}, 4, 4, TUI_PIXELS_RGB8_V1};
        tui_image_options_v1 image_options = {7, 1, 0, 0, 0, 0};
        CHECK(tui_scrollback_draw_v1(state->renderer, (tui_rect_v1){2, 2, 24, 4}, &desc, &state->scroll, &rows));
        CHECK(tui_list_draw_v1(state->renderer, (tui_rect_v1){2, 7, 24, 4}, &desc, &state->scroll, &rows));
        CHECK(tui_tree_draw_v1(state->renderer, (tui_rect_v1){2, 12, 24, 5}, &desc, &state->tree, &rows));
        CHECK(tui_menu_draw_v1(state->renderer, (tui_rect_v1){2, 18, 24, 4}, &desc, &state->menu, &rows));
        CHECK(tui_table_draw_v1(state->renderer, (tui_rect_v1){28, 2, 28, 7}, &desc, &state->scroll, &rows, columns, 2));
        CHECK(tui_task_list_draw_v1(state->renderer, (tui_rect_v1){28, 10, 28, 6}, &desc, &state->menu, &rows));
        CHECK(tui_line_chart_draw_v1(state->chart, state->renderer, (tui_rect_v1){58, 2, 20, 10}, &samples, role(10, 0)));
        CHECK(tui_renderer_put_image_v1(state->renderer, (tui_rect_v1){58, 14, 4, 4}, image, image_options));
        text_desc.text = utf8("parser + SPSC queue\nRGB image 4x4");
        text_desc.role = role(15, 0);
        text_desc.enabled = 1;
        text_desc.width_profile = TUI_WIDTH_NARROW_V1;
        CHECK(tui_paragraph_draw_v1(state->renderer, (tui_rect_v1){64, 14, 14, 4}, &text_desc));
    }

    capabilities.color_depth = TUI_COLOR_TRUECOLOR_V1;
    capabilities.image_protocol = TUI_IMAGE_NONE_V1;
    capabilities.synchronized_output = 1;
    CHECK(tui_renderer_present_v1(state->renderer, capabilities, output, &stats));
    return output_context_value->file == NULL || fflush(output_context_value->file) == 0;
}

static int dispatch_event(app *state, const tui_event_v1 *event) {
    tui_control_desc_v1 button_desc = control("Activate", 1);
    tui_control_desc_v1 checkbox_desc = control("Checked", 1);
    tui_control_desc_v1 radio_desc = control("Choice two", 1);
    tui_rows_provider_v1 rows = rows_provider();
    tui_update_v1 update;

    if (event->kind == TUI_EVENT_KEY_V1 && event->key_action != TUI_KEY_RELEASE_V1) {
        if (event->key_kind == TUI_KEY_ESCAPE_V1 ||
            (event->key_kind == TUI_KEY_CODEPOINT_V1 && event->key_value == 'q')) return 0;
        if (event->key_kind == TUI_KEY_TAB_V1) {
            state->page ^= 1;
            return 1;
        }
    }
#define DISPATCH(expression) \
    do { if (!check_result((expression), #expression)) return -1; } while (0)
    DISPATCH(tui_button_handle_v1(&button_desc, &state->button, event, &update));
    DISPATCH(tui_checkbox_handle_v1(&checkbox_desc, &state->checkbox, event, &update));
    DISPATCH(tui_radio_handle_v1(&radio_desc, &state->radio, 2, event, &update));
    DISPATCH(tui_text_input_handle_v1(state->input, event, &update));
    DISPATCH(tui_text_area_handle_v1(state->area, event, &update));
    DISPATCH(tui_scrollback_handle_v1((tui_rect_v1){2, 2, 24, 4}, &state->scroll, &rows, event, &update));
    DISPATCH(tui_list_handle_v1((tui_rect_v1){2, 7, 24, 4}, &state->scroll, &rows, event, &update));
    DISPATCH(tui_table_handle_v1((tui_rect_v1){28, 2, 28, 7}, &state->scroll, &rows, event, &update));
    DISPATCH(tui_tree_handle_v1((tui_rect_v1){2, 12, 24, 5}, &state->tree, &rows, event, &update));
    DISPATCH(tui_task_list_handle_v1((tui_rect_v1){28, 10, 28, 6}, &state->menu, &rows, event, &update));
    DISPATCH(tui_menu_handle_v1((tui_rect_v1){2, 18, 24, 4}, &state->menu, &rows, event, &update));
#undef DISPATCH
    return 1;
}

static void restore_terminal(void) {
    static const char leave[] = "\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l";
    if (!terminal_active) return;
    (void)tcsetattr(STDIN_FILENO, TCSAFLUSH, &original_termios);
    (void)write(STDOUT_FILENO, leave, sizeof(leave) - 1);
    terminal_active = 0;
}

static void handle_signal(int signal_number) {
    if (signal_number == SIGWINCH) resize_requested = 1;
    else stop_requested = 1;
}

static int enter_terminal(void) {
    static const char enter[] = "\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h";
    struct termios raw;
    struct sigaction action;
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        fprintf(stderr, "interactive mode requires a terminal; use --headless otherwise\n");
        return 0;
    }
    if (tcgetattr(STDIN_FILENO, &original_termios) != 0) return 0;
    raw = original_termios;
    raw.c_iflag &= (tcflag_t)~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= (tcflag_t)~OPOST;
    raw.c_cflag |= CS8;
    raw.c_lflag &= (tcflag_t)~(ECHO | ICANON | IEXTEN);
    raw.c_lflag |= ISIG;
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 1;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) return 0;
    terminal_active = 1;
    if (atexit(restore_terminal) != 0) {
        restore_terminal();
        return 0;
    }
    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGTERM, &action, NULL);
    (void)sigaction(SIGWINCH, &action, NULL);
    if (write(STDOUT_FILENO, enter, sizeof(enter) - 1) != (ssize_t)(sizeof(enter) - 1)) {
        restore_terminal();
        return 0;
    }
    return 1;
}

static tui_size_v1 terminal_size(void) {
    struct winsize size;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 && size.ws_row > 0) {
        return (tui_size_v1){size.ws_col, size.ws_row};
    }
    return (tui_size_v1){80, 24};
}

static int run_headless(app *state, int hash_only) {
    output_context output = {
        hash_only ? NULL : stdout,
        0,
        UINT64_C(14695981039346656037),
    };
    if (!draw_frame(state, (tui_size_v1){80, 24}, &output)) return 0;
    state->page = 1;
    tui_renderer_invalidate_terminal_v1(state->renderer);
    if (!draw_frame(state, (tui_size_v1){80, 24}, &output)) return 0;
    if (hash_only) printf("%016llx %llu\n", (unsigned long long)output.hash, (unsigned long long)output.bytes);
    return 1;
}

static int run_interactive(app *state) {
    uint8_t input[64];
    output_context output = {stdout, 0, UINT64_C(14695981039346656037)};
    int redraw = 1;
    if (!enter_terminal()) return 0;
    resize_requested = 1;
    while (!stop_requested) {
        struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
        if (resize_requested) {
            resize_requested = 0;
            tui_renderer_invalidate_terminal_v1(state->renderer);
            redraw = 1;
        }
        if (redraw) {
            if (!draw_frame(state, terminal_size(), &output)) return 0;
            redraw = 0;
        }
        if (poll(&descriptor, 1, 100) < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        if ((descriptor.revents & POLLIN) != 0) {
            ssize_t length = read(STDIN_FILENO, input, sizeof(input));
            tui_event_v1 event;
            int result;
            if (length < 0 && errno != EINTR) return 0;
            if (length <= 0) continue;
            CHECK(tui_parser_feed_v1(state->parser, (tui_bytes_v1){input, (uint64_t)length}, state->queue));
            while ((result = pop_event(state, &event)) != TUI_ERROR_QUEUE_EMPTY_V1) {
                int dispatched;
                CHECK(result);
                dispatched = dispatch_event(state, &event);
                if (dispatched < 0) return 0;
                if (dispatched == 0) return 1;
                redraw = 1;
            }
        }
    }
    return 1;
}

int main(int argc, char **argv) {
    app state;
    int headless = argc == 2 && strcmp(argv[1], "--headless") == 0;
    int hash_only = argc == 2 && strcmp(argv[1], "--headless-hash") == 0;
    int success;
    if (argc > 2 || (argc == 2 && !headless && !hash_only)) {
        fprintf(stderr, "usage: %s [--headless|--headless-hash]\n", argv[0]);
        return 2;
    }
    if (!app_init(&state)) {
        app_deinit(&state);
        return 1;
    }
    if (!exercise_nonvisual_api(&state)) {
        app_deinit(&state);
        return 1;
    }
    success = headless || hash_only ? run_headless(&state, hash_only) : run_interactive(&state);
    app_deinit(&state);
    return success ? 0 : 1;
}
