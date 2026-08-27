#include "tui.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t attempts;
    uint64_t allocations;
    uint64_t deallocations;
    uint64_t live_bytes;
    uint64_t fail_at;
    int reject;
} allocator_state;

static void *allocate(void *context, uint64_t size, uint64_t alignment) {
    allocator_state *state = (allocator_state *)context;
    void *memory;
    state->attempts += 1;
    if (state->reject || (state->fail_at != 0 && state->allocations == state->fail_at) ||
        size > SIZE_MAX || alignment == 0 || alignment > _Alignof(max_align_t)) return NULL;
    memory = malloc((size_t)size);
    if (memory == NULL) return NULL;
    if ((uintptr_t)memory % alignment != 0) {
        free(memory);
        return NULL;
    }
    state->allocations += 1;
    state->live_bytes += size;
    return memory;
}

static void deallocate(void *context, void *memory, uint64_t size, uint64_t alignment) {
    allocator_state *state = (allocator_state *)context;
    (void)alignment;
    state->deallocations += 1;
    state->live_bytes -= size;
    free(memory);
}

static _Alignas(max_align_t) uint8_t misaligned_storage[4096];

static void *allocate_misaligned(void *context, uint64_t size, uint64_t alignment) {
    uintptr_t base = (uintptr_t)misaligned_storage;
    uintptr_t aligned;
    (void)context;
    if (alignment == 0 || alignment >= sizeof(misaligned_storage) ||
        size > sizeof(misaligned_storage) - alignment - 1) return NULL;
    aligned = (base + alignment - 1) & ~(uintptr_t)(alignment - 1);
    return (void *)(aligned + 1);
}

static void deallocate_misaligned(void *context, void *memory, uint64_t size, uint64_t alignment) {
    uint64_t *calls = (uint64_t *)context;
    (void)memory;
    (void)size;
    (void)alignment;
    *calls += 1;
}

static tui_utf8_v1 text(const char *value) {
    tui_utf8_v1 result;
    result.ptr = (const uint8_t *)value;
    result.len = (uint64_t)strlen(value);
    return result;
}

static tui_result_v1 write_output(void *context, const uint8_t *bytes, uint64_t len) {
    uint64_t *total = (uint64_t *)context;
    (void)bytes;
    *total += len;
    return TUI_OK_V1;
}

static const char *labels[] = {"root", "child", "test"};
static tui_utf8_v1 table_cells[3][2];

static tui_result_v1 read_rows(void *context, uint64_t first, uint32_t count, tui_provider_row_v1 *rows) {
    uint32_t i;
    (void)context;
    for (i = 0; i < count; ++i) {
        uint64_t index = first + i;
        memset(&rows[i], 0, sizeof(rows[i]));
        rows[i].text = text(labels[index]);
        table_cells[index][0] = text(labels[index]);
        table_cells[index][1] = text(index == 2 ? "running" : "done");
        rows[i].cells = table_cells[index];
        rows[i].cell_count = 2;
        rows[i].depth = index == 1 ? 1u : 0u;
        rows[i].status = index == 2 ? 1 : 2;
        rows[i].flags = index == 0 ? 3u : 0u;
    }
    return TUI_OK_V1;
}

static tui_result_v1 read_samples(void *context, uint64_t first, uint32_t count, double *samples) {
    uint32_t i;
    (void)context;
    for (i = 0; i < count; ++i) samples[i] = (double)((first + i) % 2u);
    return TUI_OK_V1;
}

int main(void) {
    allocator_state allocation = {0};
    tui_allocator_v1 allocator = {&allocation, allocate, deallocate};
    tui_allocator_v1 incomplete_allocator = {NULL, NULL, NULL};
    uint64_t misaligned_deallocations = 0;
    tui_allocator_v1 misaligned_allocator = {&misaligned_deallocations, allocate_misaligned, deallocate_misaligned};
    tui_renderer_v1 *renderer = NULL;
    tui_text_input_v1 *input = NULL;
    tui_text_area_v1 *area = NULL;
    tui_line_chart_v1 *chart = NULL;
    tui_event_queue_v1 *queue = NULL;
    tui_parser_v1 *parser = NULL;
    tui_renderer_v1 *rejected_renderer = (tui_renderer_v1 *)(uintptr_t)1;
    tui_text_desc_v1 text_desc;
    tui_panel_desc_v1 panel_desc;
    tui_gauge_desc_v1 gauge_desc;
    tui_control_desc_v1 control_desc;
    tui_collection_desc_v1 collection_desc;
    tui_button_state_v1 button_state;
    tui_checkbox_state_v1 checkbox_state;
    tui_radio_state_v1 radio_state;
    tui_scroll_state_v1 scroll_state;
    tui_menu_state_v1 menu_state;
    tui_tree_state_v1 tree_state;
    tui_rows_provider_v1 rows_provider;
    tui_samples_provider_v1 samples_provider;
    tui_column_v1 columns[2];
    tui_event_v1 event;
    tui_event_v1 popped;
    tui_update_v1 update = 0;
    tui_frame_stats_v1 stats;
    tui_capabilities_v1 capabilities;
    tui_output_v1 output;
    uint8_t payload[256];
    uint8_t image_pixels[3] = {255, 0, 0};
    uint64_t output_bytes = 0;
    uint64_t steady_attempts;
    tui_parser_v1 *rejected = (tui_parser_v1 *)(uintptr_t)1;

    memset(&text_desc, 0, sizeof(text_desc));
    memset(&panel_desc, 0, sizeof(panel_desc));
    memset(&gauge_desc, 0, sizeof(gauge_desc));
    memset(&control_desc, 0, sizeof(control_desc));
    memset(&collection_desc, 0, sizeof(collection_desc));
    memset(&button_state, 0, sizeof(button_state));
    memset(&checkbox_state, 0, sizeof(checkbox_state));
    memset(&radio_state, 0, sizeof(radio_state));
    memset(&scroll_state, 0, sizeof(scroll_state));
    memset(&menu_state, 0, sizeof(menu_state));
    memset(&tree_state, 0, sizeof(tree_state));
    memset(&event, 0, sizeof(event));
    memset(&capabilities, 0, sizeof(capabilities));

    if (tui_abi_version_v1().major != TUI_ABI_MAJOR_V1) return 1;
    if (tui_parser_create_v1(NULL, &rejected) != TUI_ERROR_INVALID_ARGUMENT_V1 || rejected != NULL) return 2;
    rejected = (tui_parser_v1 *)(uintptr_t)1;
    if (tui_parser_create_v1(&incomplete_allocator, &rejected) != TUI_ERROR_INVALID_ARGUMENT_V1 || rejected != NULL) return 2;
    rejected = (tui_parser_v1 *)(uintptr_t)1;
    if (tui_parser_create_v1(&misaligned_allocator, &rejected) != TUI_ERROR_OUT_OF_MEMORY_V1 ||
        rejected != NULL || misaligned_deallocations != 1) return 2;
    rejected = (tui_parser_v1 *)(uintptr_t)1;
    allocation.reject = 1;
    if (tui_parser_create_v1(&allocator, &rejected) != TUI_ERROR_OUT_OF_MEMORY_V1 || rejected != NULL) return 2;
    allocation.reject = 0;
    allocation.fail_at = allocation.allocations + 2;
    if (tui_renderer_create_v1(&allocator, (tui_size_v1){4, 2}, NULL, &rejected_renderer) != TUI_ERROR_OUT_OF_MEMORY_V1 ||
        rejected_renderer != NULL || allocation.live_bytes != 0) return 2;
    allocation.fail_at = 0;
    if (tui_renderer_create_v1(&allocator, (tui_size_v1){40, 16}, NULL, &renderer) != TUI_OK_V1) return 2;
    if (tui_renderer_resize_v1(renderer, (tui_size_v1){41, 16}) != TUI_OK_V1) return 2;
    if (tui_text_input_create_v1(&allocator, 32, text("ready"), &input) != 0) return 2;
    if (tui_text_area_create_v1(&allocator, 64, text("one\ntwo"), &area) != 0) return 2;
    if (tui_line_chart_create_v1(&allocator, 8, 8, &chart) != 0) return 2;
    if (tui_event_queue_create_v1(&allocator, 4, &queue) != 0 || tui_parser_create_v1(&allocator, &parser) != 0) return 2;
    steady_attempts = allocation.attempts;
    allocation.reject = 1;
    if (tui_renderer_begin_frame_v1(renderer) != TUI_OK_V1) return 3;

    text_desc.text = text("label");
    text_desc.enabled = 1;
    if (tui_label_draw_v1(renderer, (tui_rect_v1){0, 0, 10, 1}, &text_desc) != 0) return 4;
    text_desc.text = text("paragraph text");
    if (tui_paragraph_draw_v1(renderer, (tui_rect_v1){0, 1, 20, 2}, &text_desc) != 0) return 5;
    panel_desc.title = text("panel");
    panel_desc.enabled = 1;
    if (tui_panel_draw_v1(renderer, (tui_rect_v1){20, 0, 20, 4}, &panel_desc) != 0) return 6;
    if (tui_panel_content_rect_v1((tui_rect_v1){20, 0, 20, 4}, &(tui_rect_v1){0}) != 0) return 7;
    gauge_desc.value = 1;
    gauge_desc.total = 2;
    gauge_desc.enabled = 1;
    if (tui_gauge_draw_v1(renderer, (tui_rect_v1){0, 3, 10, 1}, &gauge_desc) != 0) return 8;

    control_desc.label = text("control");
    control_desc.enabled = 1;
    event.kind = TUI_EVENT_KEY_V1;
    event.key_kind = TUI_KEY_ENTER_V1;
    event.key_action = TUI_KEY_PRESS_V1;
    if (tui_button_handle_v1(&control_desc, &button_state, &event, &update) != 0) return 9;
    if (tui_button_draw_v1(renderer, (tui_rect_v1){0, 4, 12, 1}, &control_desc, &button_state) != 0) return 10;
    if (tui_checkbox_handle_v1(&control_desc, &checkbox_state, &event, &update) != 0) return 11;
    if (tui_checkbox_draw_v1(renderer, (tui_rect_v1){0, 5, 12, 1}, &control_desc, &checkbox_state) != 0) return 12;
    if (tui_radio_handle_v1(&control_desc, &radio_state, 7, &event, &update) != 0) return 13;
    if (tui_radio_draw_v1(renderer, (tui_rect_v1){0, 6, 12, 1}, &control_desc, &radio_state, 7) != 0) return 14;

    if (tui_text_input_set_focus_v1(input, 1) != 0) return 16;
    event.kind = TUI_EVENT_TEXT_V1;
    event.payload = text("!");
    if (tui_text_input_handle_v1(input, &event, &update) != 0) return 17;
    if (tui_text_input_draw_v1(input, renderer, (tui_rect_v1){0, 7, 15, 1}) != 0) return 18;

    if (tui_text_area_layout_v1(area, (tui_size_v1){15, 2}) != 0) return 20;
    if (tui_text_area_set_focus_v1(area, 1) != 0 || tui_text_area_set_soft_wrap_v1(area, 1) != 0) return 21;
    if (tui_text_area_draw_v1(area, renderer, (tui_rect_v1){0, 8, 15, 2}) != 0) return 22;

    rows_provider.context = NULL;
    rows_provider.count = 3;
    rows_provider.read = read_rows;
    collection_desc.enabled = 1;
    if (tui_scrollback_draw_v1(renderer, (tui_rect_v1){16, 4, 10, 2}, &collection_desc, &scroll_state, &rows_provider) != 0) return 23;
    if (tui_list_draw_v1(renderer, (tui_rect_v1){16, 6, 10, 2}, &collection_desc, &scroll_state, &rows_provider) != 0) return 24;
    columns[0].title = text("name"); columns[0].width = 5;
    columns[1].title = text("state"); columns[1].width = 5;
    if (tui_table_draw_v1(renderer, (tui_rect_v1){27, 4, 10, 3}, &collection_desc, &scroll_state, &rows_provider, columns, 2) != 0) return 25;
    if (tui_tree_draw_v1(renderer, (tui_rect_v1){16, 8, 10, 2}, &collection_desc, &tree_state, &rows_provider) != 0) return 26;
    if (tui_task_list_draw_v1(renderer, (tui_rect_v1){27, 8, 12, 2}, &collection_desc, &menu_state, &rows_provider) != 0) return 27;
    if (tui_menu_draw_v1(renderer, (tui_rect_v1){16, 10, 10, 2}, &collection_desc, &menu_state, &rows_provider) != 0) return 28;
    event.kind = TUI_EVENT_KEY_V1; event.key_kind = TUI_KEY_DOWN_V1; event.key_action = TUI_KEY_PRESS_V1; event.payload = text("");
    if (tui_list_handle_v1((tui_rect_v1){16, 6, 10, 2}, &scroll_state, &rows_provider, &event, &update) != 0) return 29;
    if (tui_scrollback_handle_v1((tui_rect_v1){16, 4, 10, 2}, &scroll_state, &rows_provider, &event, &update) != 0) return 30;
    if (tui_table_handle_v1((tui_rect_v1){27, 4, 10, 3}, &scroll_state, &rows_provider, &event, &update) != 0) return 31;
    if (tui_tree_handle_v1((tui_rect_v1){16, 8, 10, 2}, &tree_state, &rows_provider, &event, &update) != 0) return 32;
    if (tui_task_list_handle_v1((tui_rect_v1){27, 8, 12, 2}, &menu_state, &rows_provider, &event, &update) != 0) return 33;
    if (tui_menu_handle_v1((tui_rect_v1){16, 10, 10, 2}, &menu_state, &rows_provider, &event, &update) != 0) return 34;

    samples_provider.context = NULL; samples_provider.count = 4; samples_provider.read = read_samples;
    if (tui_line_chart_draw_v1(chart, renderer, (tui_rect_v1){27, 11, 2, 2}, &samples_provider, collection_desc.row_role) != 0) return 36;

    if (tui_renderer_put_image_v1(renderer, (tui_rect_v1){30, 11, 1, 1},
        (tui_image_v1){{image_pixels, 3}, 1, 1, TUI_PIXELS_RGB8_V1},
        (tui_image_options_v1){1, 1, 0, 0, 0, 0}) != 0) return 37;
    output.context = &output_bytes; output.write = write_output;
    if (tui_renderer_present_v1(renderer, capabilities, output, &stats) != 0 || output_bytes == 0) return 38;

    if (tui_parser_feed_v1(parser, text("a"), queue) != 0) return 40;
    if (tui_event_queue_try_pop_v1(queue, payload, sizeof(payload), &popped) != 0) return 41;
    if (popped.kind != TUI_EVENT_TEXT_V1 || popped.payload.len != 1 || payload[0] != 'a') return 42;
    if (tui_parser_finish_v1(parser, queue) != 0 || tui_parser_abort_v1(parser, queue) != 0) return 43;
    if (allocation.attempts != steady_attempts) return 44;

    tui_parser_destroy_v1(parser);
    tui_event_queue_destroy_v1(queue);
    tui_line_chart_destroy_v1(chart);
    tui_text_area_destroy_v1(area);
    tui_text_input_destroy_v1(input);
    tui_renderer_destroy_v1(renderer);
    if (allocation.allocations == 0 || allocation.allocations != allocation.deallocations || allocation.live_bytes != 0) return 45;
    return 0;
}
