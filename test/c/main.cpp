#include "tui.h"

#include <cstdint>
#include <cstring>

static tui_result_v1 write_output(void *context, const uint8_t *, uint64_t len) {
    *static_cast<uint64_t *>(context) += len;
    return TUI_OK_V1;
}

int main() {
    tui_renderer_v1 *renderer = nullptr;
    if (tui_renderer_create_v1(tui_size_v1{8, 1}, nullptr, &renderer) != TUI_OK_V1) return 1;
    if (tui_renderer_begin_frame_v1(renderer) != TUI_OK_V1) return 2;
    tui_text_desc_v1 label{};
    const char value[] = "C++";
    label.text = tui_utf8_v1{reinterpret_cast<const uint8_t *>(value), 3};
    label.enabled = 1;
    if (tui_label_draw_v1(renderer, tui_rect_v1{0, 0, 8, 1}, &label) != TUI_OK_V1) return 3;
    uint64_t bytes = 0;
    tui_output_v1 output{&bytes, write_output};
    tui_capabilities_v1 capabilities{};
    if (tui_renderer_present_v1(renderer, capabilities, output, nullptr) != TUI_OK_V1 || bytes == 0) return 4;
    tui_renderer_destroy_v1(renderer);
    return 0;
}
