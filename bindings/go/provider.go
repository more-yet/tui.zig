package tui

/*
#cgo CFLAGS: -std=c11 -I${SRCDIR}/../../include
#include "bridge.h"
#include <stdlib.h>
*/
import "C"

import (
	"math"
	"runtime/cgo"
	"unicode/utf8"
	"unsafe"
)

type RowsProvider struct {
	noCopy      noCopy
	handle      cgo.Handle
	rows        []C.tui_provider_row_v1
	allocations []unsafe.Pointer
}

func NewRowsProvider(rows []Row) (*RowsProvider, error) {
	provider := &RowsProvider{rows: make([]C.tui_provider_row_v1, len(rows))}
	for index, row := range rows {
		if !utf8.ValidString(row.Text) {
			provider.Close()
			return nil, Error(ErrorInvalidText)
		}
		text, allocation := allocBytes([]byte(row.Text))
		provider.allocations = append(provider.allocations, allocation)
		provider.rows[index].text = text
		provider.rows[index].cell_count = C.uint32_t(len(row.Cells))
		provider.rows[index].depth = C.uint32_t(row.Depth)
		provider.rows[index].status = C.int32_t(row.Status)
		provider.rows[index].flags = C.uint32_t(row.Flags)
		if len(row.Cells) == 0 {
			continue
		}
		if uint64(len(row.Cells)) > uint64(math.MaxUint32) {
			provider.Close()
			return nil, Error(ErrorCapacity)
		}
		memory := C.malloc(C.size_t(len(row.Cells)) * C.size_t(C.sizeof_tui_utf8_v1))
		if memory == nil {
			provider.Close()
			return nil, Error(ErrorOutOfMemory)
		}
		provider.allocations = append(provider.allocations, memory)
		cells := unsafe.Slice((*C.tui_utf8_v1)(memory), len(row.Cells))
		for cellIndex, value := range row.Cells {
			if !utf8.ValidString(value) {
				provider.Close()
				return nil, Error(ErrorInvalidText)
			}
			cell, cellAllocation := allocBytes([]byte(value))
			provider.allocations = append(provider.allocations, cellAllocation)
			cells[cellIndex] = cell
		}
		provider.rows[index].cells = (*C.tui_utf8_v1)(memory)
	}
	provider.handle = cgo.NewHandle(provider)
	return provider, nil
}

func (provider *RowsProvider) native() C.tui_rows_provider_v1 {
	if provider == nil {
		return C.tui_go_rows_provider(0, 0)
	}
	return C.tui_go_rows_provider(C.uintptr_t(provider.handle), C.uint64_t(len(provider.rows)))
}

func (provider *RowsProvider) Close() {
	if provider == nil {
		return
	}
	if provider.handle != 0 {
		provider.handle.Delete()
		provider.handle = 0
	}
	for _, allocation := range provider.allocations {
		C.free(allocation)
	}
	provider.allocations = nil
	provider.rows = nil
}

//export tui_go_rows_read
func tui_go_rows_read(
	handle C.uintptr_t,
	first C.uint64_t,
	count C.uint32_t,
	rows *C.tui_provider_row_v1,
) (status C.int32_t) {
	status = ErrorProvider
	defer func() {
		if recover() != nil {
			status = ErrorProvider
		}
	}()
	provider := cgo.Handle(handle).Value().(*RowsProvider)
	start, length := uint64(first), uint64(count)
	if rows == nil || start > uint64(len(provider.rows)) || length > uint64(len(provider.rows))-start {
		return status
	}
	copy(
		unsafe.Slice(rows, int(count)),
		provider.rows[int(start):int(start+length)],
	)
	return OK
}

type SamplesProvider struct {
	noCopy  noCopy
	handle  cgo.Handle
	samples []float64
}

func NewSamplesProvider(samples []float64) *SamplesProvider {
	provider := &SamplesProvider{samples: append([]float64(nil), samples...)}
	provider.handle = cgo.NewHandle(provider)
	return provider
}

func (provider *SamplesProvider) native() C.tui_samples_provider_v1 {
	if provider == nil {
		return C.tui_go_samples_provider(0, 0)
	}
	return C.tui_go_samples_provider(C.uintptr_t(provider.handle), C.uint64_t(len(provider.samples)))
}

func (provider *SamplesProvider) Close() {
	if provider != nil && provider.handle != 0 {
		provider.handle.Delete()
		provider.handle = 0
		provider.samples = nil
	}
}

//export tui_go_samples_read
func tui_go_samples_read(
	handle C.uintptr_t,
	first C.uint64_t,
	count C.uint32_t,
	samples *C.double,
) (status C.int32_t) {
	status = ErrorProvider
	defer func() {
		if recover() != nil {
			status = ErrorProvider
		}
	}()
	provider := cgo.Handle(handle).Value().(*SamplesProvider)
	start, length := uint64(first), uint64(count)
	if samples == nil || start > uint64(len(provider.samples)) || length > uint64(len(provider.samples))-start {
		return status
	}
	output := unsafe.Slice(samples, int(count))
	for index := range output {
		output[index] = C.double(provider.samples[int(start)+index])
	}
	return OK
}
