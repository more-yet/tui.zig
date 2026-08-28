#define _POSIX_C_SOURCE 200809L

#include "bridge.h"

#include <stdlib.h>
#include <string.h>

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

const tui_allocator_v1 *tui_go_allocator(void) {
    return &allocator;
}

static tui_result_v1 write_output(void *context, const uint8_t *bytes, uint64_t len) {
    tui_go_output_buffer *buffer = context;
    uint64_t required;
    uint64_t capacity;
    uint8_t *data;
    if (buffer == NULL || len > UINT64_MAX - buffer->len) return TUI_ERROR_OUTPUT_V1;
    required = buffer->len + len;
    if (required > buffer->capacity) {
        capacity = buffer->capacity == 0 ? 4096 : buffer->capacity;
        while (capacity < required) {
            if (capacity > UINT64_MAX / 2) {
                capacity = required;
                break;
            }
            capacity *= 2;
        }
        if (capacity > SIZE_MAX) return TUI_ERROR_OUTPUT_V1;
        data = realloc(buffer->data, (size_t)capacity);
        if (data == NULL) return TUI_ERROR_OUTPUT_V1;
        buffer->data = data;
        buffer->capacity = capacity;
    }
    if (len != 0) memcpy(buffer->data + buffer->len, bytes, (size_t)len);
    buffer->len = required;
    return TUI_OK_V1;
}

void tui_go_output_reset(tui_go_output_buffer *buffer) {
    if (buffer != NULL) buffer->len = 0;
}

void tui_go_output_deinit(tui_go_output_buffer *buffer) {
    if (buffer == NULL) return;
    free(buffer->data);
    buffer->data = NULL;
    buffer->len = 0;
    buffer->capacity = 0;
}

tui_output_v1 tui_go_output(tui_go_output_buffer *buffer) {
    tui_output_v1 output = {buffer, write_output};
    return output;
}

static tui_result_v1 rows_read(void *context, uint64_t first, uint32_t count, tui_provider_row_v1 *rows) {
    return tui_go_rows_read((uintptr_t)context, first, count, rows);
}

tui_rows_provider_v1 tui_go_rows_provider(uintptr_t handle, uint64_t count) {
    tui_rows_provider_v1 provider = {(void *)handle, count, rows_read};
    return provider;
}

static tui_result_v1 samples_read(void *context, uint64_t first, uint32_t count, double *samples) {
    return tui_go_samples_read((uintptr_t)context, first, count, samples);
}

tui_samples_provider_v1 tui_go_samples_provider(uintptr_t handle, uint64_t count) {
    tui_samples_provider_v1 provider = {(void *)handle, count, samples_read};
    return provider;
}
