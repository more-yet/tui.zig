package tui

/*
#cgo CFLAGS: -std=c11 -I${SRCDIR}/../../include
#cgo LDFLAGS: -L${SRCDIR}/../../zig-out/lib -ltui
#include "bridge.h"
#include <stdlib.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"math"
	"unicode/utf8"
	"unsafe"
)

type noCopy struct{}

func (*noCopy) Lock() {}

const (
	OK                          = 0
	ErrorInvalidArgument        = -1
	ErrorOutOfMemory            = -2
	ErrorCapacity               = -3
	ErrorInvalidText            = -4
	ErrorBufferTooSmall         = -5
	ErrorQueueFull              = -6
	ErrorQueueEmpty             = -7
	ErrorOutput                 = -8
	ErrorProvider               = -9
	ErrorInvalidState           = -10
	ErrorUnsupported            = -11
	UpdateIgnored               = 0
	UpdateHandled               = 1
	UpdateRedraw                = 2
	UpdateRelayout              = 3
	EventKey                    = 1
	EventText                   = 2
	EventMouse                  = 3
	EventPasteStart             = 4
	EventPasteChunk             = 5
	EventPasteEnd               = 6
	EventFocusIn                = 7
	EventFocusOut               = 8
	EventCursorPosition         = 9
	EventTerminalReply          = 10
	EventMalformed              = 11
	KeyCodepoint                = 0
	KeyFunctional               = 1
	KeyEscape                   = 2
	KeyEnter                    = 3
	KeyTab                      = 4
	KeyBackspace                = 5
	KeyUp                       = 6
	KeyDown                     = 7
	KeyLeft                     = 8
	KeyRight                    = 9
	KeyHome                     = 10
	KeyEnd                      = 11
	KeyInsert                   = 12
	KeyDelete                   = 13
	KeyPageUp                   = 14
	KeyPageDown                 = 15
	KeyFunction                 = 16
	KeyPress                    = 0
	KeyRepeat                   = 1
	KeyRelease                  = 2
	ColorDefault                = 0
	ColorIndexed                = 1
	ColorRGB                    = 2
	ColorANSI16                 = 0
	ColorIndexed256             = 1
	ColorTruecolor              = 2
	ImageNone                   = 0
	ImageKitty                  = 1
	ImageITerm2                 = 2
	ImageSixel                  = 3
	PixelsRGB8                  = 0
	PixelsRGBA8                 = 1
	WidthNarrow                 = 0
	WidthWideAmbiguous          = 1
	AlignLeft                   = 0
	AlignCenter                 = 1
	AlignRight                  = 2
	RowHasChildren       uint32 = 1
	RowExpanded          uint32 = 2
)

type Error int32

func (e Error) Error() string { return fmt.Sprintf("tui error %d", int32(e)) }

func result(value C.int32_t) error {
	if value == OK {
		return nil
	}
	return Error(value)
}

type Version struct{ Major, Minor, Patch uint32 }
type Size struct{ Width, Height uint16 }
type Point struct{ X, Y uint16 }
type Rect struct{ X, Y, Width, Height uint16 }

type Color struct {
	Kind                    int32
	Index, Red, Green, Blue uint8
}

type Style struct {
	Foreground, Background Color
	Attributes             uint8
}

type Role struct {
	Normal, Focused, Disabled Style
	HasFocused, HasDisabled   bool
}

type Capabilities struct {
	ColorDepth, ImageProtocol           int32
	SynchronizedOutput, BackgroundErase bool
}

type FrameStats struct {
	Bytes                             uint64
	CellsCompared, CellsChanged, Runs uint32
	DirtyRows                         uint16
	FullRepaint                       bool
}

type Event struct {
	Kind, KeyKind, ReplyKind                       int32
	KeyValue                                       uint32
	Modifiers, KeyAction, MouseButton, MouseAction uint8
	X, Y                                           uint16
	ReplyFinal                                     uint8
	Payload                                        []byte
}

type TextDesc struct {
	Text                    string
	Role                    Role
	Enabled, Focused        bool
	WidthProfile, Alignment uint8
}

type PanelDesc struct {
	Title            string
	BorderRole       Role
	TitleRole        Role
	Enabled, Focused bool
}

type GaugeDesc struct {
	Value, Total uint64
	FilledRole   Role
	EmptyRole    Role
	Enabled      bool
}

type ControlDesc struct {
	Label            string
	Role             Role
	IndicatorRole    Role
	Enabled, Focused bool
}

type ButtonState struct{ Activated bool }
type CheckboxState struct{ Checked bool }
type RadioState struct {
	Selected    uint32
	HasSelected bool
}
type ScrollState struct {
	Top, Selected uint64
	HasSelected   bool
}
type MenuState struct {
	Scroll       ScrollState
	Activated    uint64
	HasActivated bool
}
type TreeState struct {
	Scroll                   ScrollState
	Toggled, Activated       uint64
	HasToggled, HasActivated bool
}

type CollectionDesc struct {
	RowRole, SelectedRole, HeaderRole Role
	Enabled, Focused                  bool
	WidthProfile                      uint8
}

type Column struct {
	Title string
	Width uint16
}

type Row struct {
	Text   string
	Cells  []string
	Depth  uint32
	Status int32
	Flags  uint32
}

type Image struct {
	Pixels        []byte
	Width, Height uint32
	Format        int32
}

type ImageOptions struct {
	ImageID, PlacementID                           uint32
	BackgroundRed, BackgroundGreen, BackgroundBlue uint8
}

func ABIVersion() Version {
	version := C.tui_abi_version_v1()
	return Version{uint32(version.major), uint32(version.minor), uint32(version.patch)}
}

func cSize(value Size) C.tui_size_v1 {
	var result C.tui_size_v1
	result.width, result.height = C.uint16_t(value.Width), C.uint16_t(value.Height)
	return result
}

func cRect(value Rect) C.tui_rect_v1 {
	var result C.tui_rect_v1
	result.x, result.y = C.uint16_t(value.X), C.uint16_t(value.Y)
	result.width, result.height = C.uint16_t(value.Width), C.uint16_t(value.Height)
	return result
}

func goRect(value C.tui_rect_v1) Rect {
	return Rect{uint16(value.x), uint16(value.y), uint16(value.width), uint16(value.height)}
}

func cColor(value Color) C.tui_color_v1 {
	var result C.tui_color_v1
	result.kind, result.index = C.int32_t(value.Kind), C.uint8_t(value.Index)
	result.red, result.green, result.blue = C.uint8_t(value.Red), C.uint8_t(value.Green), C.uint8_t(value.Blue)
	return result
}

func cStyle(value Style) C.tui_style_v1 {
	var result C.tui_style_v1
	result.foreground, result.background = cColor(value.Foreground), cColor(value.Background)
	result.attributes = C.uint8_t(value.Attributes)
	return result
}

func cRole(value Role) C.tui_role_v1 {
	var result C.tui_role_v1
	result.normal, result.focused, result.disabled = cStyle(value.Normal), cStyle(value.Focused), cStyle(value.Disabled)
	result.has_focused, result.has_disabled = cBool(value.HasFocused), cBool(value.HasDisabled)
	return result
}

func cBool(value bool) C.uint8_t {
	if value {
		return 1
	}
	return 0
}

func allocBytes(value []byte) (C.tui_bytes_v1, unsafe.Pointer) {
	var result C.tui_bytes_v1
	result.len = C.uint64_t(len(value))
	if len(value) == 0 {
		return result, nil
	}
	memory := C.CBytes(value)
	result.ptr = (*C.uint8_t)(memory)
	return result, memory
}

func allocUTF8(value string) (C.tui_utf8_v1, unsafe.Pointer, error) {
	if !utf8.ValidString(value) {
		return C.tui_utf8_v1{}, nil, Error(ErrorInvalidText)
	}
	bytes, memory := allocBytes([]byte(value))
	return C.tui_utf8_v1(bytes), memory, nil
}

func cEvent(value Event) (C.tui_event_v1, unsafe.Pointer) {
	var event C.tui_event_v1
	event.kind, event.key_kind, event.reply_kind = C.int32_t(value.Kind), C.int32_t(value.KeyKind), C.int32_t(value.ReplyKind)
	event.key_value = C.uint32_t(value.KeyValue)
	event.modifiers, event.key_action = C.uint8_t(value.Modifiers), C.uint8_t(value.KeyAction)
	event.mouse_button, event.mouse_action = C.uint8_t(value.MouseButton), C.uint8_t(value.MouseAction)
	event.x, event.y, event.reply_final = C.uint16_t(value.X), C.uint16_t(value.Y), C.uint8_t(value.ReplyFinal)
	event.payload, _ = allocBytes(value.Payload)
	return event, unsafe.Pointer(event.payload.ptr)
}

func goEvent(value C.tui_event_v1) Event {
	event := Event{
		Kind: int32(value.kind), KeyKind: int32(value.key_kind), ReplyKind: int32(value.reply_kind),
		KeyValue: uint32(value.key_value), Modifiers: uint8(value.modifiers), KeyAction: uint8(value.key_action),
		MouseButton: uint8(value.mouse_button), MouseAction: uint8(value.mouse_action), X: uint16(value.x), Y: uint16(value.y),
		ReplyFinal: uint8(value.reply_final),
	}
	if value.payload.len != 0 {
		event.Payload = C.GoBytes(unsafe.Pointer(value.payload.ptr), C.int(value.payload.len))
	}
	return event
}

type Renderer struct {
	noCopy           noCopy
	ptr              *C.tui_renderer_v1
	frameAllocations []unsafe.Pointer
}

func NewRenderer(size Size) (*Renderer, error) {
	var pointer *C.tui_renderer_v1
	if err := result(C.tui_renderer_create_v1(C.tui_go_allocator(), cSize(size), nil, &pointer)); err != nil {
		return nil, err
	}
	return &Renderer{ptr: pointer}, nil
}

func (r *Renderer) Close() {
	if r != nil && r.ptr != nil {
		C.tui_renderer_destroy_v1(r.ptr)
		r.ptr = nil
		r.freeFrameAllocations()
	}
}

func (r *Renderer) Resize(size Size) error {
	return result(C.tui_renderer_resize_v1(r.ptr, cSize(size)))
}
func (r *Renderer) BeginFrame() error {
	if err := result(C.tui_renderer_begin_frame_v1(r.ptr)); err != nil {
		return err
	}
	r.freeFrameAllocations()
	return nil
}
func (r *Renderer) InvalidateTerminal() { C.tui_renderer_invalidate_terminal_v1(r.ptr) }

func (r *Renderer) freeFrameAllocations() {
	for _, allocation := range r.frameAllocations {
		C.free(allocation)
	}
	r.frameAllocations = r.frameAllocations[:0]
}

type Output struct {
	noCopy noCopy
	buffer *C.tui_go_output_buffer
}

func (o *Output) ensure() error {
	if o.buffer != nil {
		return nil
	}
	o.buffer = (*C.tui_go_output_buffer)(C.malloc(C.size_t(unsafe.Sizeof(C.tui_go_output_buffer{}))))
	if o.buffer == nil {
		return Error(ErrorOutOfMemory)
	}
	*o.buffer = C.tui_go_output_buffer{}
	return nil
}

func (o *Output) Close() {
	if o == nil || o.buffer == nil {
		return
	}
	C.tui_go_output_deinit(o.buffer)
	C.free(unsafe.Pointer(o.buffer))
	o.buffer = nil
}
func (o *Output) Reset() {
	if o != nil && o.buffer != nil {
		C.tui_go_output_reset(o.buffer)
	}
}
func (o *Output) Bytes() ([]byte, error) {
	if o == nil || o.buffer == nil || o.buffer.len == 0 {
		return nil, nil
	}
	if uint64(o.buffer.len) > uint64(math.MaxInt) {
		return nil, Error(ErrorCapacity)
	}
	value := unsafe.Slice((*byte)(unsafe.Pointer(o.buffer.data)), int(o.buffer.len))
	return append([]byte(nil), value...), nil
}

func (r *Renderer) Present(capabilities Capabilities, output *Output) (FrameStats, error) {
	if output == nil {
		return FrameStats{}, Error(ErrorInvalidArgument)
	}
	if err := output.ensure(); err != nil {
		return FrameStats{}, err
	}
	var native C.tui_capabilities_v1
	native.color_depth, native.image_protocol = C.int32_t(capabilities.ColorDepth), C.int32_t(capabilities.ImageProtocol)
	native.synchronized_output, native.background_color_erase = cBool(capabilities.SynchronizedOutput), cBool(capabilities.BackgroundErase)
	var stats C.tui_frame_stats_v1
	err := result(C.tui_renderer_present_v1(r.ptr, native, C.tui_go_output(output.buffer), &stats))
	if err == nil {
		r.freeFrameAllocations()
	}
	return FrameStats{
		Bytes: uint64(stats.bytes), CellsCompared: uint32(stats.cells_compared), CellsChanged: uint32(stats.cells_changed),
		Runs: uint32(stats.runs), DirtyRows: uint16(stats.dirty_rows), FullRepaint: stats.full_repaint != 0,
	}, err
}

func (r *Renderer) PutImage(bounds Rect, image Image, options ImageOptions) error {
	pixels, memory := allocBytes(image.Pixels)
	var native C.tui_image_v1
	native.pixels, native.width, native.height, native.format = pixels, C.uint32_t(image.Width), C.uint32_t(image.Height), C.int32_t(image.Format)
	var nativeOptions C.tui_image_options_v1
	nativeOptions.image_id, nativeOptions.placement_id = C.uint32_t(options.ImageID), C.uint32_t(options.PlacementID)
	nativeOptions.background_red, nativeOptions.background_green = C.uint8_t(options.BackgroundRed), C.uint8_t(options.BackgroundGreen)
	nativeOptions.background_blue = C.uint8_t(options.BackgroundBlue)
	if err := result(C.tui_renderer_put_image_v1(r.ptr, cRect(bounds), native, nativeOptions)); err != nil {
		C.free(memory)
		return err
	}
	r.frameAllocations = append(r.frameAllocations, memory)
	return nil
}

func cTextDesc(value TextDesc) (C.tui_text_desc_v1, unsafe.Pointer, error) {
	var native C.tui_text_desc_v1
	text, memory, err := allocUTF8(value.Text)
	if err != nil {
		return native, nil, err
	}
	native.text, native.role = text, cRole(value.Role)
	native.enabled, native.focused = cBool(value.Enabled), cBool(value.Focused)
	native.width_profile, native.alignment = C.uint8_t(value.WidthProfile), C.uint8_t(value.Alignment)
	return native, memory, nil
}

func (r *Renderer) drawText(bounds Rect, desc TextDesc, paragraph bool) error {
	native, memory, err := cTextDesc(desc)
	if err != nil {
		return err
	}
	defer C.free(memory)
	if paragraph {
		return result(C.tui_paragraph_draw_v1(r.ptr, cRect(bounds), &native))
	}
	return result(C.tui_label_draw_v1(r.ptr, cRect(bounds), &native))
}

func (r *Renderer) DrawLabel(bounds Rect, desc TextDesc) error {
	return r.drawText(bounds, desc, false)
}
func (r *Renderer) DrawParagraph(bounds Rect, desc TextDesc) error {
	return r.drawText(bounds, desc, true)
}

func (r *Renderer) DrawPanel(bounds Rect, desc PanelDesc) error {
	var native C.tui_panel_desc_v1
	title, memory, err := allocUTF8(desc.Title)
	if err != nil {
		return err
	}
	defer C.free(memory)
	native.title, native.border_role, native.title_role = title, cRole(desc.BorderRole), cRole(desc.TitleRole)
	native.enabled, native.focused = cBool(desc.Enabled), cBool(desc.Focused)
	return result(C.tui_panel_draw_v1(r.ptr, cRect(bounds), &native))
}

func PanelContentRect(bounds Rect) (Rect, error) {
	var output C.tui_rect_v1
	err := result(C.tui_panel_content_rect_v1(cRect(bounds), &output))
	return goRect(output), err
}

func (r *Renderer) DrawGauge(bounds Rect, desc GaugeDesc) error {
	var native C.tui_gauge_desc_v1
	native.value, native.total = C.uint64_t(desc.Value), C.uint64_t(desc.Total)
	native.filled_role, native.empty_role, native.enabled = cRole(desc.FilledRole), cRole(desc.EmptyRole), cBool(desc.Enabled)
	return result(C.tui_gauge_draw_v1(r.ptr, cRect(bounds), &native))
}

func cControl(desc ControlDesc) (C.tui_control_desc_v1, unsafe.Pointer, error) {
	var native C.tui_control_desc_v1
	label, memory, err := allocUTF8(desc.Label)
	if err != nil {
		return native, nil, err
	}
	native.label, native.role, native.indicator_role = label, cRole(desc.Role), cRole(desc.IndicatorRole)
	native.enabled, native.focused = cBool(desc.Enabled), cBool(desc.Focused)
	return native, memory, nil
}

func withControl(desc ControlDesc, call func(*C.tui_control_desc_v1) C.int32_t) error {
	native, memory, err := cControl(desc)
	if err != nil {
		return err
	}
	defer C.free(memory)
	return result(call(&native))
}

func (r *Renderer) DrawButton(bounds Rect, desc ControlDesc, state *ButtonState) error {
	return withControl(desc, func(native *C.tui_control_desc_v1) C.int32_t {
		var nativeState C.tui_button_state_v1
		nativeState.activated = cBool(state.Activated)
		value := C.tui_button_draw_v1(r.ptr, cRect(bounds), native, &nativeState)
		state.Activated = nativeState.activated != 0
		return value
	})
}

func HandleButton(desc ControlDesc, state *ButtonState, event Event) (int32, error) {
	var update C.int32_t
	nativeEvent, payload := cEvent(event)
	defer C.free(payload)
	err := withControl(desc, func(native *C.tui_control_desc_v1) C.int32_t {
		var nativeState C.tui_button_state_v1
		nativeState.activated = cBool(state.Activated)
		value := C.tui_button_handle_v1(native, &nativeState, &nativeEvent, &update)
		state.Activated = nativeState.activated != 0
		return value
	})
	return int32(update), err
}

func (r *Renderer) DrawCheckbox(bounds Rect, desc ControlDesc, state *CheckboxState) error {
	return withControl(desc, func(native *C.tui_control_desc_v1) C.int32_t {
		var nativeState C.tui_checkbox_state_v1
		nativeState.checked = cBool(state.Checked)
		value := C.tui_checkbox_draw_v1(r.ptr, cRect(bounds), native, &nativeState)
		state.Checked = nativeState.checked != 0
		return value
	})
}

func HandleCheckbox(desc ControlDesc, state *CheckboxState, event Event) (int32, error) {
	var update C.int32_t
	nativeEvent, payload := cEvent(event)
	defer C.free(payload)
	err := withControl(desc, func(native *C.tui_control_desc_v1) C.int32_t {
		var nativeState C.tui_checkbox_state_v1
		nativeState.checked = cBool(state.Checked)
		value := C.tui_checkbox_handle_v1(native, &nativeState, &nativeEvent, &update)
		state.Checked = nativeState.checked != 0
		return value
	})
	return int32(update), err
}

func (r *Renderer) DrawRadio(bounds Rect, desc ControlDesc, state *RadioState, value uint32) error {
	return withControl(desc, func(native *C.tui_control_desc_v1) C.int32_t {
		stateValue := cRadioState(*state)
		status := C.tui_radio_draw_v1(r.ptr, cRect(bounds), native, &stateValue, C.uint32_t(value))
		*state = goRadioState(stateValue)
		return status
	})
}

func HandleRadio(desc ControlDesc, state *RadioState, value uint32, event Event) (int32, error) {
	var update C.int32_t
	nativeEvent, payload := cEvent(event)
	defer C.free(payload)
	err := withControl(desc, func(native *C.tui_control_desc_v1) C.int32_t {
		stateValue := cRadioState(*state)
		status := C.tui_radio_handle_v1(native, &stateValue, C.uint32_t(value), &nativeEvent, &update)
		*state = goRadioState(stateValue)
		return status
	})
	return int32(update), err
}

func cRadioState(value RadioState) C.tui_radio_state_v1 {
	var state C.tui_radio_state_v1
	state.selected, state.has_selected = C.uint32_t(value.Selected), cBool(value.HasSelected)
	return state
}
func goRadioState(value C.tui_radio_state_v1) RadioState {
	return RadioState{uint32(value.selected), value.has_selected != 0}
}

type TextInput struct {
	noCopy noCopy
	ptr    *C.tui_text_input_v1
}

func NewTextInput(capacity uint64, initial string) (*TextInput, error) {
	value, memory, err := allocUTF8(initial)
	if err != nil {
		return nil, err
	}
	defer C.free(memory)
	var pointer *C.tui_text_input_v1
	if err := result(C.tui_text_input_create_v1(C.tui_go_allocator(), C.uint64_t(capacity), value, &pointer)); err != nil {
		return nil, err
	}
	return &TextInput{ptr: pointer}, nil
}
func (input *TextInput) Close() {
	if input != nil && input.ptr != nil {
		C.tui_text_input_destroy_v1(input.ptr)
		input.ptr = nil
	}
}
func (input *TextInput) Draw(renderer *Renderer, bounds Rect) error {
	return result(C.tui_text_input_draw_v1(input.ptr, renderer.ptr, cRect(bounds)))
}
func (input *TextInput) Handle(event Event) (int32, error) {
	native, payload := cEvent(event)
	defer C.free(payload)
	var update C.int32_t
	err := result(C.tui_text_input_handle_v1(input.ptr, &native, &update))
	return int32(update), err
}
func (input *TextInput) SetFocus(value bool) error {
	return result(C.tui_text_input_set_focus_v1(input.ptr, cBool(value)))
}
func (input *TextInput) SetSelection(anchor, cursor uint64) error {
	return result(C.tui_text_input_set_selection_v1(input.ptr, C.uint64_t(anchor), C.uint64_t(cursor)))
}
func (input *TextInput) ReplaceSelection(value string) error {
	text, memory, err := allocUTF8(value)
	if err != nil {
		return err
	}
	defer C.free(memory)
	return result(C.tui_text_input_replace_selection_v1(input.ptr, text))
}
func (input *TextInput) Value() ([]byte, error) {
	return copyValue(func(out *C.uint8_t, capacity C.uint64_t, needed *C.uint64_t) C.int32_t {
		return C.tui_text_input_copy_value_v1(input.ptr, out, capacity, needed)
	})
}
func (input *TextInput) TakeFailure() (int32, error) {
	var failure C.int32_t
	err := result(C.tui_text_input_take_failure_v1(input.ptr, &failure))
	return int32(failure), err
}

type TextArea struct {
	noCopy noCopy
	ptr    *C.tui_text_area_v1
}

func NewTextArea(capacity uint64, initial string) (*TextArea, error) {
	value, memory, err := allocUTF8(initial)
	if err != nil {
		return nil, err
	}
	defer C.free(memory)
	var pointer *C.tui_text_area_v1
	if err := result(C.tui_text_area_create_v1(C.tui_go_allocator(), C.uint64_t(capacity), value, &pointer)); err != nil {
		return nil, err
	}
	return &TextArea{ptr: pointer}, nil
}
func (area *TextArea) Close() {
	if area != nil && area.ptr != nil {
		C.tui_text_area_destroy_v1(area.ptr)
		area.ptr = nil
	}
}
func (area *TextArea) Layout(size Size) error {
	return result(C.tui_text_area_layout_v1(area.ptr, cSize(size)))
}
func (area *TextArea) Draw(renderer *Renderer, bounds Rect) error {
	return result(C.tui_text_area_draw_v1(area.ptr, renderer.ptr, cRect(bounds)))
}
func (area *TextArea) Handle(event Event) (int32, error) {
	native, payload := cEvent(event)
	defer C.free(payload)
	var update C.int32_t
	err := result(C.tui_text_area_handle_v1(area.ptr, &native, &update))
	return int32(update), err
}
func (area *TextArea) SetFocus(value bool) error {
	return result(C.tui_text_area_set_focus_v1(area.ptr, cBool(value)))
}
func (area *TextArea) SetSoftWrap(value bool) error {
	return result(C.tui_text_area_set_soft_wrap_v1(area.ptr, cBool(value)))
}
func (area *TextArea) Value() ([]byte, error) {
	return copyValue(func(out *C.uint8_t, capacity C.uint64_t, needed *C.uint64_t) C.int32_t {
		return C.tui_text_area_copy_value_v1(area.ptr, out, capacity, needed)
	})
}
func (area *TextArea) TakeFailure() (int32, error) {
	var failure C.int32_t
	err := result(C.tui_text_area_take_failure_v1(area.ptr, &failure))
	return int32(failure), err
}

func copyValue(call func(*C.uint8_t, C.uint64_t, *C.uint64_t) C.int32_t) ([]byte, error) {
	var needed C.uint64_t
	status := call(nil, 0, &needed)
	if status != OK && status != ErrorBufferTooSmall {
		return nil, Error(status)
	}
	if uint64(needed) > uint64(math.MaxInt) {
		return nil, Error(ErrorCapacity)
	}
	value := make([]byte, int(needed))
	if len(value) == 0 {
		return value, nil
	}
	if err := result(call((*C.uint8_t)(unsafe.Pointer(&value[0])), C.uint64_t(len(value)), &needed)); err != nil {
		return nil, err
	}
	return value, nil
}

type collectionKind uint8

const (
	collectionScrollback collectionKind = iota
	collectionList
)

func (r *Renderer) drawScrollCollection(kind collectionKind, bounds Rect, desc CollectionDesc, state *ScrollState, provider *RowsProvider) error {
	nativeDesc := cCollection(desc)
	nativeState := cScroll(*state)
	nativeProvider := provider.native()
	var status C.int32_t
	if kind == collectionScrollback {
		status = C.tui_scrollback_draw_v1(r.ptr, cRect(bounds), &nativeDesc, &nativeState, &nativeProvider)
	} else {
		status = C.tui_list_draw_v1(r.ptr, cRect(bounds), &nativeDesc, &nativeState, &nativeProvider)
	}
	*state = goScroll(nativeState)
	return result(status)
}
func (r *Renderer) DrawScrollback(bounds Rect, desc CollectionDesc, state *ScrollState, provider *RowsProvider) error {
	return r.drawScrollCollection(collectionScrollback, bounds, desc, state, provider)
}
func (r *Renderer) DrawList(bounds Rect, desc CollectionDesc, state *ScrollState, provider *RowsProvider) error {
	return r.drawScrollCollection(collectionList, bounds, desc, state, provider)
}

func handleScrollCollection(kind collectionKind, bounds Rect, state *ScrollState, provider *RowsProvider, event Event) (int32, error) {
	nativeState := cScroll(*state)
	nativeProvider := provider.native()
	nativeEvent, payload := cEvent(event)
	defer C.free(payload)
	var update C.int32_t
	var status C.int32_t
	if kind == collectionScrollback {
		status = C.tui_scrollback_handle_v1(cRect(bounds), &nativeState, &nativeProvider, &nativeEvent, &update)
	} else {
		status = C.tui_list_handle_v1(cRect(bounds), &nativeState, &nativeProvider, &nativeEvent, &update)
	}
	*state = goScroll(nativeState)
	return int32(update), result(status)
}
func HandleScrollback(bounds Rect, state *ScrollState, provider *RowsProvider, event Event) (int32, error) {
	return handleScrollCollection(collectionScrollback, bounds, state, provider, event)
}
func HandleList(bounds Rect, state *ScrollState, provider *RowsProvider, event Event) (int32, error) {
	return handleScrollCollection(collectionList, bounds, state, provider, event)
}

func (r *Renderer) DrawTable(bounds Rect, desc CollectionDesc, state *ScrollState, provider *RowsProvider, columns []Column) error {
	nativeColumns, free, err := cColumns(columns)
	if err != nil {
		return err
	}
	defer free()
	nativeDesc, nativeState, nativeProvider := cCollection(desc), cScroll(*state), provider.native()
	status := C.tui_table_draw_v1(r.ptr, cRect(bounds), &nativeDesc, &nativeState, &nativeProvider, nativeColumns, C.uint32_t(len(columns)))
	*state = goScroll(nativeState)
	return result(status)
}
func HandleTable(bounds Rect, state *ScrollState, provider *RowsProvider, event Event) (int32, error) {
	nativeState, nativeProvider := cScroll(*state), provider.native()
	nativeEvent, payload := cEvent(event)
	defer C.free(payload)
	var update C.int32_t
	status := C.tui_table_handle_v1(cRect(bounds), &nativeState, &nativeProvider, &nativeEvent, &update)
	*state = goScroll(nativeState)
	return int32(update), result(status)
}

func (r *Renderer) DrawTree(bounds Rect, desc CollectionDesc, state *TreeState, provider *RowsProvider) error {
	nativeDesc, nativeState, nativeProvider := cCollection(desc), cTree(*state), provider.native()
	status := C.tui_tree_draw_v1(r.ptr, cRect(bounds), &nativeDesc, &nativeState, &nativeProvider)
	*state = goTree(nativeState)
	return result(status)
}
func HandleTree(bounds Rect, state *TreeState, provider *RowsProvider, event Event) (int32, error) {
	nativeState, nativeProvider := cTree(*state), provider.native()
	nativeEvent, payload := cEvent(event)
	defer C.free(payload)
	var update C.int32_t
	status := C.tui_tree_handle_v1(cRect(bounds), &nativeState, &nativeProvider, &nativeEvent, &update)
	*state = goTree(nativeState)
	return int32(update), result(status)
}

type menuKind uint8

const (
	menuTaskList menuKind = iota
	menuMenu
)

func (r *Renderer) drawMenu(kind menuKind, bounds Rect, desc CollectionDesc, state *MenuState, provider *RowsProvider) error {
	nativeDesc, nativeState, nativeProvider := cCollection(desc), cMenu(*state), provider.native()
	var status C.int32_t
	if kind == menuTaskList {
		status = C.tui_task_list_draw_v1(r.ptr, cRect(bounds), &nativeDesc, &nativeState, &nativeProvider)
	} else {
		status = C.tui_menu_draw_v1(r.ptr, cRect(bounds), &nativeDesc, &nativeState, &nativeProvider)
	}
	*state = goMenu(nativeState)
	return result(status)
}
func (r *Renderer) DrawTaskList(bounds Rect, desc CollectionDesc, state *MenuState, provider *RowsProvider) error {
	return r.drawMenu(menuTaskList, bounds, desc, state, provider)
}
func (r *Renderer) DrawMenu(bounds Rect, desc CollectionDesc, state *MenuState, provider *RowsProvider) error {
	return r.drawMenu(menuMenu, bounds, desc, state, provider)
}
func handleMenu(kind menuKind, bounds Rect, state *MenuState, provider *RowsProvider, event Event) (int32, error) {
	nativeState, nativeProvider := cMenu(*state), provider.native()
	nativeEvent, payload := cEvent(event)
	defer C.free(payload)
	var update C.int32_t
	var status C.int32_t
	if kind == menuTaskList {
		status = C.tui_task_list_handle_v1(cRect(bounds), &nativeState, &nativeProvider, &nativeEvent, &update)
	} else {
		status = C.tui_menu_handle_v1(cRect(bounds), &nativeState, &nativeProvider, &nativeEvent, &update)
	}
	*state = goMenu(nativeState)
	return int32(update), result(status)
}
func HandleTaskList(bounds Rect, state *MenuState, provider *RowsProvider, event Event) (int32, error) {
	return handleMenu(menuTaskList, bounds, state, provider, event)
}
func HandleMenu(bounds Rect, state *MenuState, provider *RowsProvider, event Event) (int32, error) {
	return handleMenu(menuMenu, bounds, state, provider, event)
}

func cCollection(value CollectionDesc) C.tui_collection_desc_v1 {
	var result C.tui_collection_desc_v1
	result.row_role, result.selected_role, result.header_role = cRole(value.RowRole), cRole(value.SelectedRole), cRole(value.HeaderRole)
	result.enabled, result.focused, result.width_profile = cBool(value.Enabled), cBool(value.Focused), C.uint8_t(value.WidthProfile)
	return result
}
func cScroll(value ScrollState) C.tui_scroll_state_v1 {
	var result C.tui_scroll_state_v1
	result.top, result.selected, result.has_selected = C.uint64_t(value.Top), C.uint64_t(value.Selected), cBool(value.HasSelected)
	return result
}
func goScroll(value C.tui_scroll_state_v1) ScrollState {
	return ScrollState{uint64(value.top), uint64(value.selected), value.has_selected != 0}
}
func cMenu(value MenuState) C.tui_menu_state_v1 {
	var result C.tui_menu_state_v1
	result.scroll, result.activated, result.has_activated = cScroll(value.Scroll), C.uint64_t(value.Activated), cBool(value.HasActivated)
	return result
}
func goMenu(value C.tui_menu_state_v1) MenuState {
	return MenuState{goScroll(value.scroll), uint64(value.activated), value.has_activated != 0}
}
func cTree(value TreeState) C.tui_tree_state_v1 {
	var result C.tui_tree_state_v1
	result.scroll, result.toggled, result.activated = cScroll(value.Scroll), C.uint64_t(value.Toggled), C.uint64_t(value.Activated)
	result.has_toggled, result.has_activated = cBool(value.HasToggled), cBool(value.HasActivated)
	return result
}
func goTree(value C.tui_tree_state_v1) TreeState {
	return TreeState{goScroll(value.scroll), uint64(value.toggled), uint64(value.activated), value.has_toggled != 0, value.has_activated != 0}
}

func cColumns(columns []Column) (*C.tui_column_v1, func(), error) {
	if len(columns) == 0 {
		return nil, func() {}, nil
	}
	bytes := C.size_t(len(columns)) * C.size_t(C.sizeof_tui_column_v1)
	memory := C.malloc(bytes)
	if memory == nil {
		return nil, nil, Error(ErrorOutOfMemory)
	}
	values := unsafe.Slice((*C.tui_column_v1)(memory), len(columns))
	allocations := make([]unsafe.Pointer, 0, len(columns))
	for index, column := range columns {
		title, allocation, err := allocUTF8(column.Title)
		if err != nil {
			for _, value := range allocations {
				C.free(value)
			}
			C.free(memory)
			return nil, nil, err
		}
		allocations = append(allocations, allocation)
		values[index].title, values[index].width = title, C.uint16_t(column.Width)
	}
	return (*C.tui_column_v1)(memory), func() {
		for _, value := range allocations {
			C.free(value)
		}
		C.free(memory)
	}, nil
}

type LineChart struct {
	noCopy noCopy
	ptr    *C.tui_line_chart_v1
}

func NewLineChart(sampleCapacity, cellCapacity uint64) (*LineChart, error) {
	var pointer *C.tui_line_chart_v1
	if err := result(C.tui_line_chart_create_v1(C.tui_go_allocator(), C.uint64_t(sampleCapacity), C.uint64_t(cellCapacity), &pointer)); err != nil {
		return nil, err
	}
	return &LineChart{ptr: pointer}, nil
}
func (chart *LineChart) Close() {
	if chart != nil && chart.ptr != nil {
		C.tui_line_chart_destroy_v1(chart.ptr)
		chart.ptr = nil
	}
}
func (chart *LineChart) Draw(renderer *Renderer, bounds Rect, provider *SamplesProvider, role Role) error {
	native := provider.native()
	return result(C.tui_line_chart_draw_v1(chart.ptr, renderer.ptr, cRect(bounds), &native, cRole(role)))
}

type EventQueue struct {
	noCopy noCopy
	ptr    *C.tui_event_queue_v1
}

func NewEventQueue(capacity uint64) (*EventQueue, error) {
	var pointer *C.tui_event_queue_v1
	if err := result(C.tui_event_queue_create_v1(C.tui_go_allocator(), C.uint64_t(capacity), &pointer)); err != nil {
		return nil, err
	}
	return &EventQueue{ptr: pointer}, nil
}
func (queue *EventQueue) Close() {
	if queue != nil && queue.ptr != nil {
		C.tui_event_queue_destroy_v1(queue.ptr)
		queue.ptr = nil
	}
}
func (queue *EventQueue) TryPush(event Event) error {
	native, payload := cEvent(event)
	defer C.free(payload)
	return result(C.tui_event_queue_try_push_v1(queue.ptr, &native))
}
func (queue *EventQueue) TryPop() (Event, error) {
	payload := make([]byte, 256)
	var event C.tui_event_v1
	err := result(C.tui_event_queue_try_pop_v1(queue.ptr, (*C.uint8_t)(unsafe.Pointer(&payload[0])), C.uint64_t(len(payload)), &event))
	if err != nil {
		return Event{}, err
	}
	return goEvent(event), nil
}

type Parser struct {
	noCopy noCopy
	ptr    *C.tui_parser_v1
}

func NewParser() (*Parser, error) {
	var pointer *C.tui_parser_v1
	if err := result(C.tui_parser_create_v1(C.tui_go_allocator(), &pointer)); err != nil {
		return nil, err
	}
	return &Parser{ptr: pointer}, nil
}
func (parser *Parser) Close() {
	if parser != nil && parser.ptr != nil {
		C.tui_parser_destroy_v1(parser.ptr)
		parser.ptr = nil
	}
}
func (parser *Parser) Feed(input []byte, queue *EventQueue) error {
	native, memory := allocBytes(input)
	defer C.free(memory)
	return result(C.tui_parser_feed_v1(parser.ptr, native, queue.ptr))
}
func (parser *Parser) Finish(queue *EventQueue) error {
	return result(C.tui_parser_finish_v1(parser.ptr, queue.ptr))
}
func (parser *Parser) Abort(queue *EventQueue) error {
	return result(C.tui_parser_abort_v1(parser.ptr, queue.ptr))
}

func IsError(err error, code int32) bool {
	var value Error
	return errors.As(err, &value) && int32(value) == code
}
