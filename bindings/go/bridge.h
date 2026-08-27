#ifndef TUI_GO_BRIDGE_H
#define TUI_GO_BRIDGE_H

#include "../../include/tui.h"

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t *data;
    uint64_t len;
    uint64_t capacity;
} tui_go_output_buffer;

const tui_allocator_v1 *tui_go_allocator(void);
void tui_go_output_reset(tui_go_output_buffer *buffer);
void tui_go_output_deinit(tui_go_output_buffer *buffer);
tui_output_v1 tui_go_output(tui_go_output_buffer *buffer);
tui_rows_provider_v1 tui_go_rows_provider(uintptr_t handle, uint64_t count);
tui_samples_provider_v1 tui_go_samples_provider(uintptr_t handle, uint64_t count);

extern int32_t tui_go_rows_read(uintptr_t handle, uint64_t first, uint32_t count, tui_provider_row_v1 *rows);
extern int32_t tui_go_samples_read(uintptr_t handle, uint64_t first, uint32_t count, double *samples);

#endif
