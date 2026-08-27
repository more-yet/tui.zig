#define _POSIX_C_SOURCE 200809L

#include <node_api.h>
#include "tui.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

void napi_check(napi_status status) {
    if (status != napi_ok) throw std::runtime_error("Node-API call failed");
}

void tui_check(tui_result_v1 result) {
    if (result != TUI_OK_V1) throw std::runtime_error("tui error " + std::to_string(result));
}

napi_value property(napi_env env, napi_value object, const char *name) {
    napi_value result;
    napi_check(napi_get_named_property(env, object, name, &result));
    return result;
}

bool has_property(napi_env env, napi_value object, const char *name) {
    bool result;
    napi_check(napi_has_named_property(env, object, name, &result));
    return result;
}

double number(napi_env env, napi_value value) {
    double result;
    napi_check(napi_get_value_double(env, value, &result));
    if (!std::isfinite(result)) throw std::runtime_error("expected a finite number");
    return result;
}

uint64_t unsigned_integer(napi_env env, napi_value value) {
    double result = number(env, value);
    if (result < 0 || std::floor(result) != result || result > 9007199254740991.0) {
        throw std::runtime_error("expected a non-negative safe integer");
    }
    return static_cast<uint64_t>(result);
}

template <typename T>
T bounded_unsigned(napi_env env, napi_value value) {
    uint64_t result = unsigned_integer(env, value);
    if (result > std::numeric_limits<T>::max()) throw std::runtime_error("integer is out of range");
    return static_cast<T>(result);
}

int32_t signed_integer(napi_env env, napi_value value) {
    double result = number(env, value);
    if (std::floor(result) != result || result < std::numeric_limits<int32_t>::min() ||
        result > std::numeric_limits<int32_t>::max()) throw std::runtime_error("expected a 32-bit integer");
    return static_cast<int32_t>(result);
}

bool boolean(napi_env env, napi_value value) {
    bool result;
    napi_check(napi_get_value_bool(env, value, &result));
    return result;
}

std::string string(napi_env env, napi_value value) {
    size_t length;
    napi_check(napi_get_value_string_utf8(env, value, nullptr, 0, &length));
    std::vector<char> buffer(length + 1);
    size_t written;
    napi_check(napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &written));
    return std::string(buffer.data(), written);
}

std::vector<uint8_t> bytes(napi_env env, napi_value value) {
    bool is_buffer;
    napi_check(napi_is_buffer(env, value, &is_buffer));
    if (is_buffer) {
        void *data;
        size_t length;
        napi_check(napi_get_buffer_info(env, value, &data, &length));
        const auto *first = static_cast<const uint8_t *>(data);
        return std::vector<uint8_t>(first, first + length);
    }
    std::string text = string(env, value);
    return std::vector<uint8_t>(text.begin(), text.end());
}

napi_value js_number(napi_env env, double value) {
    napi_value result;
    napi_check(napi_create_double(env, value, &result));
    return result;
}

napi_value js_bool(napi_env env, bool value) {
    napi_value result;
    napi_check(napi_get_boolean(env, value, &result));
    return result;
}

napi_value js_object(napi_env env) {
    napi_value result;
    napi_check(napi_create_object(env, &result));
    return result;
}

void set(napi_env env, napi_value object, const char *name, napi_value value) {
    napi_check(napi_set_named_property(env, object, name, value));
}

napi_value js_buffer(napi_env env, const uint8_t *data, size_t length) {
    napi_value result;
    void *copy;
    napi_check(napi_create_buffer_copy(env, length, data, &copy, &result));
    (void)copy;
    return result;
}

tui_bytes_v1 view(const std::string &value) {
    return {reinterpret_cast<const uint8_t *>(value.data()), static_cast<uint64_t>(value.size())};
}

tui_bytes_v1 view(const std::vector<uint8_t> &value) {
    return {value.empty() ? nullptr : value.data(), static_cast<uint64_t>(value.size())};
}

tui_size_v1 parse_size(napi_env env, napi_value value) {
    return {
        bounded_unsigned<uint16_t>(env, property(env, value, "width")),
        bounded_unsigned<uint16_t>(env, property(env, value, "height")),
    };
}

tui_rect_v1 parse_rect(napi_env env, napi_value value) {
    return {
        bounded_unsigned<uint16_t>(env, property(env, value, "x")),
        bounded_unsigned<uint16_t>(env, property(env, value, "y")),
        bounded_unsigned<uint16_t>(env, property(env, value, "width")),
        bounded_unsigned<uint16_t>(env, property(env, value, "height")),
    };
}

napi_value rect_object(napi_env env, tui_rect_v1 value) {
    napi_value result = js_object(env);
    set(env, result, "x", js_number(env, value.x));
    set(env, result, "y", js_number(env, value.y));
    set(env, result, "width", js_number(env, value.width));
    set(env, result, "height", js_number(env, value.height));
    return result;
}

tui_color_v1 parse_color(napi_env env, napi_value value) {
    tui_color_v1 result{};
    result.kind = signed_integer(env, property(env, value, "kind"));
    if (has_property(env, value, "index")) result.index = bounded_unsigned<uint8_t>(env, property(env, value, "index"));
    if (has_property(env, value, "red")) result.red = bounded_unsigned<uint8_t>(env, property(env, value, "red"));
    if (has_property(env, value, "green")) result.green = bounded_unsigned<uint8_t>(env, property(env, value, "green"));
    if (has_property(env, value, "blue")) result.blue = bounded_unsigned<uint8_t>(env, property(env, value, "blue"));
    return result;
}

tui_style_v1 parse_style(napi_env env, napi_value value) {
    tui_style_v1 result{};
    result.foreground = parse_color(env, property(env, value, "foreground"));
    result.background = parse_color(env, property(env, value, "background"));
    if (has_property(env, value, "attributes")) result.attributes = bounded_unsigned<uint8_t>(env, property(env, value, "attributes"));
    return result;
}

tui_role_v1 parse_role(napi_env env, napi_value value) {
    tui_role_v1 result{};
    result.normal = parse_style(env, property(env, value, "normal"));
    result.focused = parse_style(env, property(env, value, "focused"));
    result.disabled = parse_style(env, property(env, value, "disabled"));
    result.has_focused = boolean(env, property(env, value, "hasFocused"));
    result.has_disabled = boolean(env, property(env, value, "hasDisabled"));
    return result;
}

tui_text_desc_v1 parse_text_desc(napi_env env, napi_value value, std::string &text) {
    text = string(env, property(env, value, "text"));
    tui_text_desc_v1 result{};
    result.text = view(text);
    result.role = parse_role(env, property(env, value, "role"));
    result.enabled = boolean(env, property(env, value, "enabled"));
    result.focused = has_property(env, value, "focused") && boolean(env, property(env, value, "focused"));
    result.width_profile = bounded_unsigned<uint8_t>(env, property(env, value, "widthProfile"));
    result.alignment = bounded_unsigned<uint8_t>(env, property(env, value, "alignment"));
    return result;
}

tui_control_desc_v1 parse_control(napi_env env, napi_value value, std::string &label) {
    label = string(env, property(env, value, "label"));
    tui_control_desc_v1 result{};
    result.label = view(label);
    result.role = parse_role(env, property(env, value, "role"));
    result.indicator_role = parse_role(env, property(env, value, "indicatorRole"));
    result.enabled = boolean(env, property(env, value, "enabled"));
    result.focused = boolean(env, property(env, value, "focused"));
    return result;
}

tui_collection_desc_v1 parse_collection(napi_env env, napi_value value) {
    tui_collection_desc_v1 result{};
    result.row_role = parse_role(env, property(env, value, "rowRole"));
    result.selected_role = parse_role(env, property(env, value, "selectedRole"));
    result.header_role = parse_role(env, property(env, value, "headerRole"));
    result.enabled = boolean(env, property(env, value, "enabled"));
    result.focused = boolean(env, property(env, value, "focused"));
    result.width_profile = bounded_unsigned<uint8_t>(env, property(env, value, "widthProfile"));
    return result;
}

void set_bool(napi_env env, napi_value object, const char *name, bool value) { set(env, object, name, js_bool(env, value)); }
void set_number(napi_env env, napi_value object, const char *name, double value) { set(env, object, name, js_number(env, value)); }

tui_button_state_v1 parse_button(napi_env env, napi_value value) {
    tui_button_state_v1 result{};
    result.activated = boolean(env, property(env, value, "activated"));
    return result;
}

tui_checkbox_state_v1 parse_checkbox(napi_env env, napi_value value) {
    tui_checkbox_state_v1 result{};
    result.checked = boolean(env, property(env, value, "checked"));
    return result;
}

tui_radio_state_v1 parse_radio(napi_env env, napi_value value) {
    tui_radio_state_v1 result{};
    result.selected = bounded_unsigned<uint32_t>(env, property(env, value, "selected"));
    result.has_selected = boolean(env, property(env, value, "hasSelected"));
    return result;
}

tui_scroll_state_v1 parse_scroll(napi_env env, napi_value value) {
    tui_scroll_state_v1 result{};
    result.top = unsigned_integer(env, property(env, value, "top"));
    result.selected = unsigned_integer(env, property(env, value, "selected"));
    result.has_selected = boolean(env, property(env, value, "hasSelected"));
    return result;
}

void update_scroll(napi_env env, napi_value object, const tui_scroll_state_v1 &value) {
    set_number(env, object, "top", static_cast<double>(value.top));
    set_number(env, object, "selected", static_cast<double>(value.selected));
    set_bool(env, object, "hasSelected", value.has_selected != 0);
}

tui_menu_state_v1 parse_menu(napi_env env, napi_value value) {
    tui_menu_state_v1 result{};
    result.scroll = parse_scroll(env, property(env, value, "scroll"));
    result.activated = unsigned_integer(env, property(env, value, "activated"));
    result.has_activated = boolean(env, property(env, value, "hasActivated"));
    return result;
}

void update_menu(napi_env env, napi_value object, const tui_menu_state_v1 &value) {
    update_scroll(env, property(env, object, "scroll"), value.scroll);
    set_number(env, object, "activated", static_cast<double>(value.activated));
    set_bool(env, object, "hasActivated", value.has_activated != 0);
}

tui_tree_state_v1 parse_tree(napi_env env, napi_value value) {
    tui_tree_state_v1 result{};
    result.scroll = parse_scroll(env, property(env, value, "scroll"));
    result.toggled = unsigned_integer(env, property(env, value, "toggled"));
    result.activated = unsigned_integer(env, property(env, value, "activated"));
    result.has_toggled = boolean(env, property(env, value, "hasToggled"));
    result.has_activated = boolean(env, property(env, value, "hasActivated"));
    return result;
}

void update_tree(napi_env env, napi_value object, const tui_tree_state_v1 &value) {
    update_scroll(env, property(env, object, "scroll"), value.scroll);
    set_number(env, object, "toggled", static_cast<double>(value.toggled));
    set_number(env, object, "activated", static_cast<double>(value.activated));
    set_bool(env, object, "hasToggled", value.has_toggled != 0);
    set_bool(env, object, "hasActivated", value.has_activated != 0);
}

struct EventData {
    tui_event_v1 event{};
    std::vector<uint8_t> payload;
};

EventData parse_event(napi_env env, napi_value value) {
    EventData result;
    result.event.kind = signed_integer(env, property(env, value, "kind"));
    result.event.key_kind = signed_integer(env, property(env, value, "keyKind"));
    result.event.key_value = bounded_unsigned<uint32_t>(env, property(env, value, "keyValue"));
    result.event.modifiers = bounded_unsigned<uint8_t>(env, property(env, value, "modifiers"));
    result.event.key_action = bounded_unsigned<uint8_t>(env, property(env, value, "keyAction"));
    result.event.mouse_button = bounded_unsigned<uint8_t>(env, property(env, value, "mouseButton"));
    result.event.mouse_action = bounded_unsigned<uint8_t>(env, property(env, value, "mouseAction"));
    result.event.x = bounded_unsigned<uint16_t>(env, property(env, value, "x"));
    result.event.y = bounded_unsigned<uint16_t>(env, property(env, value, "y"));
    result.event.reply_kind = signed_integer(env, property(env, value, "replyKind"));
    result.event.reply_final = bounded_unsigned<uint8_t>(env, property(env, value, "replyFinal"));
    result.payload = bytes(env, property(env, value, "payload"));
    result.event.payload = view(result.payload);
    return result;
}

napi_value event_object(napi_env env, const tui_event_v1 &event) {
    napi_value result = js_object(env);
    set_number(env, result, "kind", event.kind);
    set_number(env, result, "keyKind", event.key_kind);
    set_number(env, result, "keyValue", event.key_value);
    set_number(env, result, "modifiers", event.modifiers);
    set_number(env, result, "keyAction", event.key_action);
    set_number(env, result, "mouseButton", event.mouse_button);
    set_number(env, result, "mouseAction", event.mouse_action);
    set_number(env, result, "x", event.x);
    set_number(env, result, "y", event.y);
    set_number(env, result, "replyKind", event.reply_kind);
    set_number(env, result, "replyFinal", event.reply_final);
    set(env, result, "payload", js_buffer(env, event.payload.ptr, static_cast<size_t>(event.payload.len)));
    return result;
}

void *allocate(void *, uint64_t size, uint64_t alignment) {
    if (size > SIZE_MAX || alignment > SIZE_MAX || alignment == 0) return nullptr;
    size_t native_alignment = static_cast<size_t>(alignment);
    if (native_alignment < sizeof(void *)) native_alignment = sizeof(void *);
    void *memory = nullptr;
    if (posix_memalign(&memory, native_alignment, size == 0 ? 1 : static_cast<size_t>(size)) != 0) return nullptr;
    return memory;
}

void deallocate(void *, void *memory, uint64_t, uint64_t) { std::free(memory); }
const tui_allocator_v1 allocator{nullptr, allocate, deallocate};

enum class Kind { renderer, input, area, chart, queue, parser, rows, samples };

struct RendererData {
    tui_renderer_v1 *value{};
    std::vector<std::vector<uint8_t>> frame_images;
    ~RendererData() { tui_renderer_destroy_v1(value); }
};

struct RowData {
    std::string text;
    std::vector<std::string> cell_text;
    std::vector<tui_bytes_v1> cells;
    uint32_t depth{};
    int32_t status{};
    uint32_t flags{};
};

struct RowsData {
    std::vector<RowData> rows;
};

tui_result_v1 read_rows(void *context, uint64_t first, uint32_t count, tui_provider_row_v1 *output) noexcept {
    try {
        auto *provider = static_cast<RowsData *>(context);
        if (provider == nullptr || output == nullptr || first > provider->rows.size() || count > provider->rows.size() - first) {
            return TUI_ERROR_PROVIDER_V1;
        }
        for (uint32_t index = 0; index < count; ++index) {
            RowData &row = provider->rows[static_cast<size_t>(first + index)];
            output[index] = {};
            output[index].text = view(row.text);
            output[index].cells = row.cells.empty() ? nullptr : row.cells.data();
            output[index].cell_count = static_cast<uint32_t>(row.cells.size());
            output[index].depth = row.depth;
            output[index].status = row.status;
            output[index].flags = row.flags;
        }
        return TUI_OK_V1;
    } catch (...) {
        return TUI_ERROR_PROVIDER_V1;
    }
}

struct SamplesData { std::vector<double> samples; };

tui_result_v1 read_samples(void *context, uint64_t first, uint32_t count, double *output) noexcept {
    try {
        auto *provider = static_cast<SamplesData *>(context);
        if (provider == nullptr || output == nullptr || first > provider->samples.size() || count > provider->samples.size() - first) {
            return TUI_ERROR_PROVIDER_V1;
        }
        std::copy_n(provider->samples.data() + first, count, output);
        return TUI_OK_V1;
    } catch (...) {
        return TUI_ERROR_PROVIDER_V1;
    }
}

struct External { Kind kind; void *value; };

void destroy_external(External *external) {
    if (external == nullptr || external->value == nullptr) return;
    switch (external->kind) {
        case Kind::renderer: delete static_cast<RendererData *>(external->value); break;
        case Kind::input: tui_text_input_destroy_v1(static_cast<tui_text_input_v1 *>(external->value)); break;
        case Kind::area: tui_text_area_destroy_v1(static_cast<tui_text_area_v1 *>(external->value)); break;
        case Kind::chart: tui_line_chart_destroy_v1(static_cast<tui_line_chart_v1 *>(external->value)); break;
        case Kind::queue: tui_event_queue_destroy_v1(static_cast<tui_event_queue_v1 *>(external->value)); break;
        case Kind::parser: tui_parser_destroy_v1(static_cast<tui_parser_v1 *>(external->value)); break;
        case Kind::rows: delete static_cast<RowsData *>(external->value); break;
        case Kind::samples: delete static_cast<SamplesData *>(external->value); break;
    }
    external->value = nullptr;
}

void finalize_external(napi_env, void *data, void *) {
    auto *external = static_cast<External *>(data);
    destroy_external(external);
    delete external;
}

napi_value make_external(napi_env env, Kind kind, void *value) {
    auto external = std::make_unique<External>(External{kind, value});
    napi_value result;
    napi_check(napi_create_external(env, external.get(), finalize_external, nullptr, &result));
    external.release();
    return result;
}

External *external(napi_env env, napi_value value, Kind kind) {
    void *data;
    napi_check(napi_get_value_external(env, value, &data));
    auto *result = static_cast<External *>(data);
    if (result == nullptr || result->kind != kind || result->value == nullptr) throw std::runtime_error("invalid or closed tui handle");
    return result;
}

RendererData *renderer(napi_env env, napi_value value) { return static_cast<RendererData *>(external(env, value, Kind::renderer)->value); }
tui_text_input_v1 *input(napi_env env, napi_value value) { return static_cast<tui_text_input_v1 *>(external(env, value, Kind::input)->value); }
tui_text_area_v1 *area(napi_env env, napi_value value) { return static_cast<tui_text_area_v1 *>(external(env, value, Kind::area)->value); }
tui_line_chart_v1 *chart(napi_env env, napi_value value) { return static_cast<tui_line_chart_v1 *>(external(env, value, Kind::chart)->value); }
tui_event_queue_v1 *queue(napi_env env, napi_value value) { return static_cast<tui_event_queue_v1 *>(external(env, value, Kind::queue)->value); }
tui_parser_v1 *parser(napi_env env, napi_value value) { return static_cast<tui_parser_v1 *>(external(env, value, Kind::parser)->value); }
RowsData *rows(napi_env env, napi_value value) { return static_cast<RowsData *>(external(env, value, Kind::rows)->value); }
SamplesData *samples(napi_env env, napi_value value) { return static_cast<SamplesData *>(external(env, value, Kind::samples)->value); }

tui_rows_provider_v1 rows_provider(RowsData *value) { return {value, value->rows.size(), read_rows}; }
tui_samples_provider_v1 samples_provider(SamplesData *value) { return {value, value->samples.size(), read_samples}; }

struct OutputData { std::vector<uint8_t> bytes; };
tui_result_v1 write_output(void *context, const uint8_t *data, uint64_t length) noexcept {
    try {
        if (context == nullptr || (data == nullptr && length != 0) || length > SIZE_MAX) return TUI_ERROR_OUTPUT_V1;
        if (length == 0) return TUI_OK_V1;
        auto &output = static_cast<OutputData *>(context)->bytes;
        output.insert(output.end(), data, data + static_cast<size_t>(length));
        return TUI_OK_V1;
    } catch (...) {
        return TUI_ERROR_OUTPUT_V1;
    }
}

enum class Op {
    version, renderer_create, renderer_destroy, renderer_resize, renderer_begin, renderer_invalidate,
    renderer_put_image, renderer_present, label_draw, paragraph_draw, panel_draw, panel_content, gauge_draw,
    button_draw, button_handle, checkbox_draw, checkbox_handle, radio_draw, radio_handle,
    input_create, input_destroy, input_draw, input_handle, input_focus, input_selection, input_replace, input_copy, input_failure,
    area_create, area_destroy, area_layout, area_draw, area_handle, area_focus, area_wrap, area_copy, area_failure,
    scroll_draw, scroll_handle, list_draw, list_handle, table_draw, table_handle, tree_draw, tree_handle,
    task_draw, task_handle, menu_draw, menu_handle, chart_create, chart_destroy, chart_draw,
    queue_create, queue_destroy, queue_push, queue_pop, parser_create, parser_destroy, parser_feed, parser_finish, parser_abort,
    rows_create, rows_destroy, samples_create, samples_destroy,
};

napi_value undefined(napi_env env) { napi_value result; napi_check(napi_get_undefined(env, &result)); return result; }

napi_value dispatch(napi_env env, napi_callback_info info) {
    try {
        napi_value argv[8];
        size_t argc = 8;
        void *data;
        napi_check(napi_get_cb_info(env, info, &argc, argv, nullptr, &data));
        auto op = static_cast<Op>(reinterpret_cast<uintptr_t>(data));
        auto require = [argc](size_t count) { if (argc < count) throw std::runtime_error("not enough arguments"); };
        switch (op) {
            case Op::version: {
                tui_version_v1 value = tui_abi_version_v1();
                napi_value result = js_object(env);
                set_number(env, result, "major", value.major); set_number(env, result, "minor", value.minor); set_number(env, result, "patch", value.patch);
                return result;
            }
            case Op::renderer_create: {
                require(1); auto *data_value = new RendererData;
                try { tui_check(tui_renderer_create_v1(&allocator, parse_size(env, argv[0]), nullptr, &data_value->value)); }
                catch (...) { delete data_value; throw; }
                return make_external(env, Kind::renderer, data_value);
            }
            case Op::renderer_destroy: require(1); destroy_external(external(env, argv[0], Kind::renderer)); return undefined(env);
            case Op::renderer_resize: require(2); tui_check(tui_renderer_resize_v1(renderer(env, argv[0])->value, parse_size(env, argv[1]))); return undefined(env);
            case Op::renderer_begin: {
                require(1); RendererData *value = renderer(env, argv[0]); tui_check(tui_renderer_begin_frame_v1(value->value)); value->frame_images.clear(); return undefined(env);
            }
            case Op::renderer_invalidate: require(1); tui_renderer_invalidate_terminal_v1(renderer(env, argv[0])->value); return undefined(env);
            case Op::renderer_put_image: {
                require(4); RendererData *value = renderer(env, argv[0]);
                auto pixels = bytes(env, property(env, argv[2], "pixels"));
                uint32_t width = bounded_unsigned<uint32_t>(env, property(env, argv[2], "width"));
                uint32_t height = bounded_unsigned<uint32_t>(env, property(env, argv[2], "height"));
                int32_t format = signed_integer(env, property(env, argv[2], "format"));
                tui_image_options_v1 options{}; options.image_id = bounded_unsigned<uint32_t>(env, property(env, argv[3], "imageId")); options.placement_id = bounded_unsigned<uint32_t>(env, property(env, argv[3], "placementId"));
                if (has_property(env, argv[3], "backgroundRed")) options.background_red = bounded_unsigned<uint8_t>(env, property(env, argv[3], "backgroundRed"));
                if (has_property(env, argv[3], "backgroundGreen")) options.background_green = bounded_unsigned<uint8_t>(env, property(env, argv[3], "backgroundGreen"));
                if (has_property(env, argv[3], "backgroundBlue")) options.background_blue = bounded_unsigned<uint8_t>(env, property(env, argv[3], "backgroundBlue"));
                tui_rect_v1 bounds = parse_rect(env, argv[1]);
                value->frame_images.push_back(std::move(pixels));
                auto &retained = value->frame_images.back(); tui_image_v1 image{view(retained), width, height, format};
                try { tui_check(tui_renderer_put_image_v1(value->value, bounds, image, options)); }
                catch (...) { value->frame_images.pop_back(); throw; }
                return undefined(env);
            }
            case Op::renderer_present: {
                require(2); RendererData *value = renderer(env, argv[0]); tui_capabilities_v1 capabilities{};
                capabilities.color_depth = signed_integer(env, property(env, argv[1], "colorDepth")); capabilities.image_protocol = signed_integer(env, property(env, argv[1], "imageProtocol"));
                capabilities.synchronized_output = boolean(env, property(env, argv[1], "synchronizedOutput")); capabilities.background_color_erase = boolean(env, property(env, argv[1], "backgroundColorErase"));
                OutputData output; tui_frame_stats_v1 stats{}; tui_check(tui_renderer_present_v1(value->value, capabilities, {&output, write_output}, &stats)); value->frame_images.clear();
                napi_value result = js_object(env); set(env, result, "bytes", js_buffer(env, output.bytes.data(), output.bytes.size()));
                napi_value stats_value = js_object(env); set_number(env, stats_value, "bytes", static_cast<double>(stats.bytes)); set_number(env, stats_value, "cellsCompared", stats.cells_compared); set_number(env, stats_value, "cellsChanged", stats.cells_changed); set_number(env, stats_value, "runs", stats.runs); set_number(env, stats_value, "dirtyRows", stats.dirty_rows); set_bool(env, stats_value, "fullRepaint", stats.full_repaint != 0); set(env, result, "stats", stats_value); return result;
            }
            case Op::label_draw:
            case Op::paragraph_draw: {
                require(3); std::string storage; tui_text_desc_v1 desc = parse_text_desc(env, argv[2], storage);
                tui_result_v1 status = op == Op::label_draw ? tui_label_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc) : tui_paragraph_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc); tui_check(status); return undefined(env);
            }
            case Op::panel_draw: {
                require(3); std::string title = string(env, property(env, argv[2], "title")); tui_panel_desc_v1 desc{}; desc.title = view(title); desc.border_role = parse_role(env, property(env, argv[2], "borderRole")); desc.title_role = parse_role(env, property(env, argv[2], "titleRole")); desc.enabled = boolean(env, property(env, argv[2], "enabled")); desc.focused = boolean(env, property(env, argv[2], "focused")); tui_check(tui_panel_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc)); return undefined(env);
            }
            case Op::panel_content: { require(1); tui_rect_v1 result{}; tui_check(tui_panel_content_rect_v1(parse_rect(env, argv[0]), &result)); return rect_object(env, result); }
            case Op::gauge_draw: {
                require(3); tui_gauge_desc_v1 desc{}; desc.value = unsigned_integer(env, property(env, argv[2], "value")); desc.total = unsigned_integer(env, property(env, argv[2], "total")); desc.filled_role = parse_role(env, property(env, argv[2], "filledRole")); desc.empty_role = parse_role(env, property(env, argv[2], "emptyRole")); desc.enabled = boolean(env, property(env, argv[2], "enabled")); tui_check(tui_gauge_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc)); return undefined(env);
            }
            case Op::button_draw:
            case Op::checkbox_draw:
            case Op::radio_draw: {
                require(op == Op::radio_draw ? 5 : 4); std::string label; tui_control_desc_v1 desc = parse_control(env, argv[2], label); tui_result_v1 status;
                if (op == Op::button_draw) { auto state = parse_button(env, argv[3]); status = tui_button_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state); set_bool(env, argv[3], "activated", state.activated != 0); }
                else if (op == Op::checkbox_draw) { auto state = parse_checkbox(env, argv[3]); status = tui_checkbox_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state); set_bool(env, argv[3], "checked", state.checked != 0); }
                else { auto state = parse_radio(env, argv[3]); status = tui_radio_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state, bounded_unsigned<uint32_t>(env, argv[4])); set_number(env, argv[3], "selected", state.selected); set_bool(env, argv[3], "hasSelected", state.has_selected != 0); }
                tui_check(status); return undefined(env);
            }
            case Op::button_handle:
            case Op::checkbox_handle:
            case Op::radio_handle: {
                require(op == Op::radio_handle ? 4 : 3); std::string label; tui_control_desc_v1 desc = parse_control(env, argv[0], label); size_t event_index = op == Op::radio_handle ? 3 : 2; EventData event = parse_event(env, argv[event_index]); int32_t update{}; tui_result_v1 status;
                if (op == Op::button_handle) { auto state = parse_button(env, argv[1]); status = tui_button_handle_v1(&desc, &state, &event.event, &update); set_bool(env, argv[1], "activated", state.activated != 0); }
                else if (op == Op::checkbox_handle) { auto state = parse_checkbox(env, argv[1]); status = tui_checkbox_handle_v1(&desc, &state, &event.event, &update); set_bool(env, argv[1], "checked", state.checked != 0); }
                else { auto state = parse_radio(env, argv[1]); status = tui_radio_handle_v1(&desc, &state, bounded_unsigned<uint32_t>(env, argv[2]), &event.event, &update); set_number(env, argv[1], "selected", state.selected); set_bool(env, argv[1], "hasSelected", state.has_selected != 0); }
                tui_check(status); return js_number(env, update);
            }
            case Op::input_create:
            case Op::area_create: {
                require(2); std::string initial = string(env, argv[1]); void *value{}; tui_result_v1 status = op == Op::input_create ? tui_text_input_create_v1(&allocator, unsigned_integer(env, argv[0]), view(initial), reinterpret_cast<tui_text_input_v1 **>(&value)) : tui_text_area_create_v1(&allocator, unsigned_integer(env, argv[0]), view(initial), reinterpret_cast<tui_text_area_v1 **>(&value)); tui_check(status); return make_external(env, op == Op::input_create ? Kind::input : Kind::area, value);
            }
            case Op::input_destroy: require(1); destroy_external(external(env, argv[0], Kind::input)); return undefined(env);
            case Op::area_destroy: require(1); destroy_external(external(env, argv[0], Kind::area)); return undefined(env);
            case Op::input_draw: require(3); tui_check(tui_text_input_draw_v1(input(env, argv[0]), renderer(env, argv[1])->value, parse_rect(env, argv[2]))); return undefined(env);
            case Op::area_draw: require(3); tui_check(tui_text_area_draw_v1(area(env, argv[0]), renderer(env, argv[1])->value, parse_rect(env, argv[2]))); return undefined(env);
            case Op::input_handle:
            case Op::area_handle: { require(2); EventData event = parse_event(env, argv[1]); int32_t update{}; tui_check(op == Op::input_handle ? tui_text_input_handle_v1(input(env, argv[0]), &event.event, &update) : tui_text_area_handle_v1(area(env, argv[0]), &event.event, &update)); return js_number(env, update); }
            case Op::input_focus: require(2); tui_check(tui_text_input_set_focus_v1(input(env, argv[0]), boolean(env, argv[1]))); return undefined(env);
            case Op::area_focus: require(2); tui_check(tui_text_area_set_focus_v1(area(env, argv[0]), boolean(env, argv[1]))); return undefined(env);
            case Op::input_selection: require(3); tui_check(tui_text_input_set_selection_v1(input(env, argv[0]), unsigned_integer(env, argv[1]), unsigned_integer(env, argv[2]))); return undefined(env);
            case Op::input_replace: { require(2); std::string value = string(env, argv[1]); tui_check(tui_text_input_replace_selection_v1(input(env, argv[0]), view(value))); return undefined(env); }
            case Op::area_layout: require(2); tui_check(tui_text_area_layout_v1(area(env, argv[0]), parse_size(env, argv[1]))); return undefined(env);
            case Op::area_wrap: require(2); tui_check(tui_text_area_set_soft_wrap_v1(area(env, argv[0]), boolean(env, argv[1]))); return undefined(env);
            case Op::input_copy:
            case Op::area_copy: {
                require(1); uint64_t needed{}; tui_result_v1 status = op == Op::input_copy ? tui_text_input_copy_value_v1(input(env, argv[0]), nullptr, 0, &needed) : tui_text_area_copy_value_v1(area(env, argv[0]), nullptr, 0, &needed); if (status != TUI_OK_V1 && status != TUI_ERROR_BUFFER_TOO_SMALL_V1) tui_check(status); std::vector<uint8_t> value(static_cast<size_t>(needed)); status = op == Op::input_copy ? tui_text_input_copy_value_v1(input(env, argv[0]), value.data(), value.size(), &needed) : tui_text_area_copy_value_v1(area(env, argv[0]), value.data(), value.size(), &needed); tui_check(status); return js_buffer(env, value.data(), value.size());
            }
            case Op::input_failure:
            case Op::area_failure: { require(1); int32_t failure{}; tui_check(op == Op::input_failure ? tui_text_input_take_failure_v1(input(env, argv[0]), &failure) : tui_text_area_take_failure_v1(area(env, argv[0]), &failure)); return js_number(env, failure); }
            case Op::scroll_draw:
            case Op::list_draw: {
                require(5); auto desc = parse_collection(env, argv[2]); auto state = parse_scroll(env, argv[3]); auto provider = rows_provider(rows(env, argv[4])); tui_check(op == Op::scroll_draw ? tui_scrollback_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state, &provider) : tui_list_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state, &provider)); update_scroll(env, argv[3], state); return undefined(env);
            }
            case Op::scroll_handle:
            case Op::list_handle:
            case Op::table_handle: {
                require(4); auto state = parse_scroll(env, argv[1]); auto provider = rows_provider(rows(env, argv[2])); EventData event = parse_event(env, argv[3]); int32_t update{}; tui_result_v1 status = op == Op::scroll_handle ? tui_scrollback_handle_v1(parse_rect(env, argv[0]), &state, &provider, &event.event, &update) : op == Op::list_handle ? tui_list_handle_v1(parse_rect(env, argv[0]), &state, &provider, &event.event, &update) : tui_table_handle_v1(parse_rect(env, argv[0]), &state, &provider, &event.event, &update); tui_check(status); update_scroll(env, argv[1], state); return js_number(env, update);
            }
            case Op::table_draw: {
                require(6); auto desc = parse_collection(env, argv[2]); auto state = parse_scroll(env, argv[3]); auto provider = rows_provider(rows(env, argv[4])); uint32_t length; napi_check(napi_get_array_length(env, argv[5], &length)); std::vector<std::string> titles(length); std::vector<tui_column_v1> columns(length); for (uint32_t index = 0; index < length; ++index) { napi_value column; napi_check(napi_get_element(env, argv[5], index, &column)); titles[index] = string(env, property(env, column, "title")); columns[index] = {view(titles[index]), bounded_unsigned<uint16_t>(env, property(env, column, "width")), 0}; } tui_check(tui_table_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state, &provider, columns.data(), columns.size())); update_scroll(env, argv[3], state); return undefined(env);
            }
            case Op::tree_draw: {
                require(5); auto desc = parse_collection(env, argv[2]); auto state = parse_tree(env, argv[3]); auto provider = rows_provider(rows(env, argv[4])); tui_check(tui_tree_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state, &provider)); update_tree(env, argv[3], state); return undefined(env);
            }
            case Op::tree_handle: {
                require(4); auto state = parse_tree(env, argv[1]); auto provider = rows_provider(rows(env, argv[2])); EventData event = parse_event(env, argv[3]); int32_t update{}; tui_check(tui_tree_handle_v1(parse_rect(env, argv[0]), &state, &provider, &event.event, &update)); update_tree(env, argv[1], state); return js_number(env, update);
            }
            case Op::task_draw:
            case Op::menu_draw: {
                require(5); auto desc = parse_collection(env, argv[2]); auto state = parse_menu(env, argv[3]); auto provider = rows_provider(rows(env, argv[4])); tui_check(op == Op::task_draw ? tui_task_list_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state, &provider) : tui_menu_draw_v1(renderer(env, argv[0])->value, parse_rect(env, argv[1]), &desc, &state, &provider)); update_menu(env, argv[3], state); return undefined(env);
            }
            case Op::task_handle:
            case Op::menu_handle: {
                require(4); auto state = parse_menu(env, argv[1]); auto provider = rows_provider(rows(env, argv[2])); EventData event = parse_event(env, argv[3]); int32_t update{}; tui_check(op == Op::task_handle ? tui_task_list_handle_v1(parse_rect(env, argv[0]), &state, &provider, &event.event, &update) : tui_menu_handle_v1(parse_rect(env, argv[0]), &state, &provider, &event.event, &update)); update_menu(env, argv[1], state); return js_number(env, update);
            }
            case Op::chart_create: { require(2); tui_line_chart_v1 *value{}; tui_check(tui_line_chart_create_v1(&allocator, unsigned_integer(env, argv[0]), unsigned_integer(env, argv[1]), &value)); return make_external(env, Kind::chart, value); }
            case Op::chart_destroy: require(1); destroy_external(external(env, argv[0], Kind::chart)); return undefined(env);
            case Op::chart_draw: { require(5); auto provider = samples_provider(samples(env, argv[3])); tui_check(tui_line_chart_draw_v1(chart(env, argv[0]), renderer(env, argv[1])->value, parse_rect(env, argv[2]), &provider, parse_role(env, argv[4]))); return undefined(env); }
            case Op::queue_create: { require(1); tui_event_queue_v1 *value{}; tui_check(tui_event_queue_create_v1(&allocator, unsigned_integer(env, argv[0]), &value)); return make_external(env, Kind::queue, value); }
            case Op::queue_destroy: require(1); destroy_external(external(env, argv[0], Kind::queue)); return undefined(env);
            case Op::queue_push: { require(2); EventData event = parse_event(env, argv[1]); tui_check(tui_event_queue_try_push_v1(queue(env, argv[0]), &event.event)); return undefined(env); }
            case Op::queue_pop: { require(1); uint8_t payload[TUI_EVENT_PAYLOAD_CAPACITY_V1]; tui_event_v1 event{}; tui_check(tui_event_queue_try_pop_v1(queue(env, argv[0]), payload, sizeof(payload), &event)); return event_object(env, event); }
            case Op::parser_create: { tui_parser_v1 *value{}; tui_check(tui_parser_create_v1(&allocator, &value)); return make_external(env, Kind::parser, value); }
            case Op::parser_destroy: require(1); destroy_external(external(env, argv[0], Kind::parser)); return undefined(env);
            case Op::parser_feed: { require(3); auto value = bytes(env, argv[1]); tui_check(tui_parser_feed_v1(parser(env, argv[0]), view(value), queue(env, argv[2]))); return undefined(env); }
            case Op::parser_finish: require(2); tui_check(tui_parser_finish_v1(parser(env, argv[0]), queue(env, argv[1]))); return undefined(env);
            case Op::parser_abort: require(2); tui_check(tui_parser_abort_v1(parser(env, argv[0]), queue(env, argv[1]))); return undefined(env);
            case Op::rows_create: {
                require(1); uint32_t length; napi_check(napi_get_array_length(env, argv[0], &length)); auto *value = new RowsData;
                try { value->rows.resize(length); for (uint32_t index = 0; index < length; ++index) { napi_value row; napi_check(napi_get_element(env, argv[0], index, &row)); RowData &target = value->rows[index]; target.text = string(env, property(env, row, "text")); target.depth = bounded_unsigned<uint32_t>(env, property(env, row, "depth")); target.status = signed_integer(env, property(env, row, "status")); target.flags = bounded_unsigned<uint32_t>(env, property(env, row, "flags")); napi_value cells = property(env, row, "cells"); uint32_t cell_count; napi_check(napi_get_array_length(env, cells, &cell_count)); target.cell_text.resize(cell_count); target.cells.resize(cell_count); for (uint32_t cell = 0; cell < cell_count; ++cell) { napi_value item; napi_check(napi_get_element(env, cells, cell, &item)); target.cell_text[cell] = string(env, item); target.cells[cell] = view(target.cell_text[cell]); } } }
                catch (...) { delete value; throw; }
                return make_external(env, Kind::rows, value);
            }
            case Op::rows_destroy: require(1); destroy_external(external(env, argv[0], Kind::rows)); return undefined(env);
            case Op::samples_create: {
                require(1); uint32_t length; napi_check(napi_get_array_length(env, argv[0], &length)); auto *value = new SamplesData; try { value->samples.resize(length); for (uint32_t index = 0; index < length; ++index) { napi_value item; napi_check(napi_get_element(env, argv[0], index, &item)); value->samples[index] = number(env, item); } } catch (...) { delete value; throw; } return make_external(env, Kind::samples, value);
            }
            case Op::samples_destroy: require(1); destroy_external(external(env, argv[0], Kind::samples)); return undefined(env);
        }
        throw std::runtime_error("unknown operation");
    } catch (const std::exception &error) {
        napi_throw_error(env, nullptr, error.what());
        return nullptr;
    } catch (...) {
        napi_throw_error(env, nullptr, "unknown native exception");
        return nullptr;
    }
}

struct Export { const char *name; Op op; };
const Export exports[] = {
    {"abiVersion", Op::version}, {"rendererCreate", Op::renderer_create}, {"rendererDestroy", Op::renderer_destroy}, {"rendererResize", Op::renderer_resize}, {"rendererBeginFrame", Op::renderer_begin}, {"rendererInvalidateTerminal", Op::renderer_invalidate}, {"rendererPutImage", Op::renderer_put_image}, {"rendererPresent", Op::renderer_present},
    {"labelDraw", Op::label_draw}, {"paragraphDraw", Op::paragraph_draw}, {"panelDraw", Op::panel_draw}, {"panelContentRect", Op::panel_content}, {"gaugeDraw", Op::gauge_draw}, {"buttonDraw", Op::button_draw}, {"buttonHandle", Op::button_handle}, {"checkboxDraw", Op::checkbox_draw}, {"checkboxHandle", Op::checkbox_handle}, {"radioDraw", Op::radio_draw}, {"radioHandle", Op::radio_handle},
    {"textInputCreate", Op::input_create}, {"textInputDestroy", Op::input_destroy}, {"textInputDraw", Op::input_draw}, {"textInputHandle", Op::input_handle}, {"textInputSetFocus", Op::input_focus}, {"textInputSetSelection", Op::input_selection}, {"textInputReplaceSelection", Op::input_replace}, {"textInputCopyValue", Op::input_copy}, {"textInputTakeFailure", Op::input_failure},
    {"textAreaCreate", Op::area_create}, {"textAreaDestroy", Op::area_destroy}, {"textAreaLayout", Op::area_layout}, {"textAreaDraw", Op::area_draw}, {"textAreaHandle", Op::area_handle}, {"textAreaSetFocus", Op::area_focus}, {"textAreaSetSoftWrap", Op::area_wrap}, {"textAreaCopyValue", Op::area_copy}, {"textAreaTakeFailure", Op::area_failure},
    {"scrollbackDraw", Op::scroll_draw}, {"scrollbackHandle", Op::scroll_handle}, {"listDraw", Op::list_draw}, {"listHandle", Op::list_handle}, {"tableDraw", Op::table_draw}, {"tableHandle", Op::table_handle}, {"treeDraw", Op::tree_draw}, {"treeHandle", Op::tree_handle}, {"taskListDraw", Op::task_draw}, {"taskListHandle", Op::task_handle}, {"menuDraw", Op::menu_draw}, {"menuHandle", Op::menu_handle},
    {"lineChartCreate", Op::chart_create}, {"lineChartDestroy", Op::chart_destroy}, {"lineChartDraw", Op::chart_draw}, {"eventQueueCreate", Op::queue_create}, {"eventQueueDestroy", Op::queue_destroy}, {"eventQueueTryPush", Op::queue_push}, {"eventQueueTryPop", Op::queue_pop}, {"parserCreate", Op::parser_create}, {"parserDestroy", Op::parser_destroy}, {"parserFeed", Op::parser_feed}, {"parserFinish", Op::parser_finish}, {"parserAbort", Op::parser_abort},
    {"rowsProviderCreate", Op::rows_create}, {"rowsProviderDestroy", Op::rows_destroy}, {"samplesProviderCreate", Op::samples_create}, {"samplesProviderDestroy", Op::samples_destroy},
};

napi_value initialize(napi_env env, napi_value result) {
    for (const auto &item : exports) {
        napi_value function;
        napi_check(napi_create_function(env, item.name, NAPI_AUTO_LENGTH, dispatch, reinterpret_cast<void *>(static_cast<uintptr_t>(item.op)), &function));
        set(env, result, item.name, function);
    }
    return result;
}

} // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, initialize)
