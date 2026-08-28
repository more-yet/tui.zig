using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Tui.Zig;

public static class Constants
{
    public const int Ok = 0;
    public const int ErrorInvalidArgument = -1;
    public const int ErrorOutOfMemory = -2;
    public const int ErrorCapacity = -3;
    public const int ErrorInvalidText = -4;
    public const int ErrorBufferTooSmall = -5;
    public const int ErrorQueueFull = -6;
    public const int ErrorQueueEmpty = -7;
    public const int ErrorOutput = -8;
    public const int ErrorProvider = -9;
    public const int ErrorInvalidState = -10;
    public const int ErrorUnsupported = -11;
    public const int UpdateIgnored = 0;
    public const int UpdateHandled = 1;
    public const int UpdateRedraw = 2;
    public const int UpdateRelayout = 3;
    public const int EventKey = 1;
    public const int EventText = 2;
    public const int EventMouse = 3;
    public const int EventPasteStart = 4;
    public const int EventPasteChunk = 5;
    public const int EventPasteEnd = 6;
    public const int EventFocusIn = 7;
    public const int EventFocusOut = 8;
    public const int EventCursorPosition = 9;
    public const int EventTerminalReply = 10;
    public const int EventMalformed = 11;
    public const int KeyCodepoint = 0;
    public const int KeyFunctional = 1;
    public const int KeyEscape = 2;
    public const int KeyEnter = 3;
    public const int KeyTab = 4;
    public const int KeyBackspace = 5;
    public const int KeyUp = 6;
    public const int KeyDown = 7;
    public const int KeyLeft = 8;
    public const int KeyRight = 9;
    public const int KeyHome = 10;
    public const int KeyEnd = 11;
    public const int KeyInsert = 12;
    public const int KeyDelete = 13;
    public const int KeyPageUp = 14;
    public const int KeyPageDown = 15;
    public const int KeyFunction = 16;
    public const byte KeyPress = 0;
    public const byte KeyRepeat = 1;
    public const byte KeyRelease = 2;
    public const int ColorDefault = 0;
    public const int ColorIndexed = 1;
    public const int ColorRgb = 2;
    public const int ColorAnsi16 = 0;
    public const int ColorIndexed256 = 1;
    public const int ColorTruecolor = 2;
    public const int ImageNone = 0;
    public const int ImageKitty = 1;
    public const int ImageIterm2 = 2;
    public const int ImageSixel = 3;
    public const int PixelsRgb8 = 0;
    public const int PixelsRgba8 = 1;
    public const byte WidthNarrow = 0;
    public const byte WidthWideAmbiguous = 1;
    public const byte AlignLeft = 0;
    public const byte AlignCenter = 1;
    public const byte AlignRight = 2;
    public const uint RowHasChildren = 1;
    public const uint RowExpanded = 2;
}

[StructLayout(LayoutKind.Sequential)]
public struct TuiVersion { public uint Major, Minor, Patch; }

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiBytes { public byte* Pointer; public ulong Length; }

[StructLayout(LayoutKind.Sequential)]
public struct TuiSize { public ushort Width, Height; }

[StructLayout(LayoutKind.Sequential)]
public struct TuiPoint { public ushort X, Y; }

[StructLayout(LayoutKind.Sequential)]
public struct TuiRect { public ushort X, Y, Width, Height; }

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiAllocator
{
    public void* Context;
    public delegate* unmanaged[Cdecl]<void*, ulong, ulong, void*> Allocate;
    public delegate* unmanaged[Cdecl]<void*, void*, ulong, ulong, void> Deallocate;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiColor
{
    public int Kind;
    public byte Index, Red, Green, Blue;
    public fixed byte Reserved[3];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiStyle
{
    public TuiColor Foreground, Background;
    public byte Attributes;
    public fixed byte Reserved[3];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiRole
{
    public TuiStyle Normal, Focused, Disabled;
    public byte HasFocused, HasDisabled;
    public fixed byte Reserved[2];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiEvent
{
    public int Kind, KeyKind;
    public uint KeyValue;
    public byte Modifiers, KeyAction, MouseButton, MouseAction;
    public ushort X, Y;
    public int ReplyKind;
    public byte ReplyFinal;
    public fixed byte Reserved[3];
    public TuiBytes Payload;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiRendererConfig
{
    public ulong MaxCells;
    public uint GraphemeCapacity;
    public ushort StyleCapacity, ImageCapacity;
    public byte TileWidth, TileHeight;
    public fixed byte Reserved[6];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiCapabilities
{
    public int ColorDepth, ImageProtocol;
    public byte SynchronizedOutput, BackgroundColorErase;
    public fixed byte Reserved[6];
}

[StructLayout(LayoutKind.Sequential)]
public struct TuiFrameStats
{
    public ulong Bytes;
    public uint CellsCompared, CellsChanged, Runs;
    public ushort DirtyRows;
    public byte FullRepaint, Reserved;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiOutput
{
    public void* Context;
    public delegate* unmanaged[Cdecl]<void*, byte*, ulong, int> Write;
}

[StructLayout(LayoutKind.Sequential)]
public struct TuiImage { public TuiBytes Pixels; public uint Width, Height; public int Format; }

[StructLayout(LayoutKind.Sequential)]
public struct TuiImageOptions
{
    public uint ImageId, PlacementId;
    public byte BackgroundRed, BackgroundGreen, BackgroundBlue, Reserved;
}

[StructLayout(LayoutKind.Sequential)]
public struct TuiTextDesc
{
    public TuiBytes Text;
    public TuiRole Role;
    public byte Enabled, Focused, WidthProfile, Alignment;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiPanelDesc
{
    public TuiBytes Title;
    public TuiRole BorderRole, TitleRole;
    public byte Enabled, Focused;
    public fixed byte Reserved[2];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiGaugeDesc
{
    public ulong Value, Total;
    public TuiRole FilledRole, EmptyRole;
    public byte Enabled;
    public fixed byte Reserved[7];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiButtonState { public byte Activated; public fixed byte Reserved[7]; }

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiCheckboxState { public byte Checked; public fixed byte Reserved[7]; }

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiRadioState { public uint Selected; public byte HasSelected; public fixed byte Reserved[3]; }

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiControlDesc
{
    public TuiBytes Label;
    public TuiRole Role, IndicatorRole;
    public byte Enabled, Focused;
    public fixed byte Reserved[2];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiScrollState
{
    public ulong Top, Selected;
    public byte HasSelected;
    public fixed byte Reserved[7];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiProviderRow
{
    public TuiBytes Text;
    public TuiBytes* Cells;
    public uint CellCount, Depth;
    public int Status;
    public uint Flags;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiRowsProvider
{
    public void* Context;
    public ulong Count;
    public delegate* unmanaged[Cdecl]<void*, ulong, uint, TuiProviderRow*, int> Read;
}

[StructLayout(LayoutKind.Sequential)]
public struct TuiColumn { public TuiBytes Title; public ushort Width, Reserved; }

[StructLayout(LayoutKind.Sequential)]
public struct TuiCollectionDesc
{
    public TuiRole RowRole, SelectedRole, HeaderRole;
    public byte Enabled, Focused, WidthProfile, Reserved;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiMenuState
{
    public TuiScrollState Scroll;
    public ulong Activated;
    public byte HasActivated;
    public fixed byte Reserved[7];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiTreeState
{
    public TuiScrollState Scroll;
    public ulong Toggled, Activated;
    public byte HasToggled, HasActivated;
    public fixed byte Reserved[6];
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct TuiSamplesProvider
{
    public void* Context;
    public ulong Count;
    public delegate* unmanaged[Cdecl]<void*, ulong, uint, double*, int> Read;
}

public static unsafe class Native
{
    private const string Library = "tui";
    private const CallingConvention Convention = CallingConvention.Cdecl;

    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern TuiVersion tui_abi_version_v1();
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_renderer_create_v1(TuiAllocator* allocator, TuiSize size, TuiRendererConfig* config, nint* output);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern void tui_renderer_destroy_v1(nint renderer);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_renderer_resize_v1(nint renderer, TuiSize size);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_renderer_begin_frame_v1(nint renderer);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern void tui_renderer_invalidate_terminal_v1(nint renderer);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_renderer_put_image_v1(nint renderer, TuiRect bounds, TuiImage image, TuiImageOptions options);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_renderer_present_v1(nint renderer, TuiCapabilities capabilities, TuiOutput output, TuiFrameStats* stats);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_label_draw_v1(nint renderer, TuiRect bounds, TuiTextDesc* description);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_paragraph_draw_v1(nint renderer, TuiRect bounds, TuiTextDesc* description);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_panel_draw_v1(nint renderer, TuiRect bounds, TuiPanelDesc* description);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_panel_content_rect_v1(TuiRect bounds, TuiRect* output);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_gauge_draw_v1(nint renderer, TuiRect bounds, TuiGaugeDesc* description);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_button_draw_v1(nint renderer, TuiRect bounds, TuiControlDesc* description, TuiButtonState* state);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_button_handle_v1(TuiControlDesc* description, TuiButtonState* state, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_checkbox_draw_v1(nint renderer, TuiRect bounds, TuiControlDesc* description, TuiCheckboxState* state);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_checkbox_handle_v1(TuiControlDesc* description, TuiCheckboxState* state, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_radio_draw_v1(nint renderer, TuiRect bounds, TuiControlDesc* description, TuiRadioState* state, uint value);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_radio_handle_v1(TuiControlDesc* description, TuiRadioState* state, uint value, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_input_create_v1(TuiAllocator* allocator, ulong capacity, TuiBytes initial, nint* output);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern void tui_text_input_destroy_v1(nint input);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_input_draw_v1(nint input, nint renderer, TuiRect bounds);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_input_handle_v1(nint input, TuiEvent* inputEvent, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_input_set_focus_v1(nint input, byte focused);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_input_set_selection_v1(nint input, ulong anchor, ulong cursor);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_input_replace_selection_v1(nint input, TuiBytes text);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_input_copy_value_v1(nint input, byte* output, ulong capacity, ulong* needed);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_input_take_failure_v1(nint input, int* failure);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_area_create_v1(TuiAllocator* allocator, ulong capacity, TuiBytes initial, nint* output);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern void tui_text_area_destroy_v1(nint area);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_area_layout_v1(nint area, TuiSize size);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_area_draw_v1(nint area, nint renderer, TuiRect bounds);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_area_handle_v1(nint area, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_area_set_focus_v1(nint area, byte focused);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_area_set_soft_wrap_v1(nint area, byte enabled);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_area_copy_value_v1(nint area, byte* output, ulong capacity, ulong* needed);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_text_area_take_failure_v1(nint area, int* failure);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_scrollback_draw_v1(nint renderer, TuiRect bounds, TuiCollectionDesc* description, TuiScrollState* state, TuiRowsProvider* provider);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_scrollback_handle_v1(TuiRect bounds, TuiScrollState* state, TuiRowsProvider* provider, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_list_draw_v1(nint renderer, TuiRect bounds, TuiCollectionDesc* description, TuiScrollState* state, TuiRowsProvider* provider);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_list_handle_v1(TuiRect bounds, TuiScrollState* state, TuiRowsProvider* provider, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_table_draw_v1(nint renderer, TuiRect bounds, TuiCollectionDesc* description, TuiScrollState* state, TuiRowsProvider* provider, TuiColumn* columns, uint columnCount);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_table_handle_v1(TuiRect bounds, TuiScrollState* state, TuiRowsProvider* provider, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_tree_draw_v1(nint renderer, TuiRect bounds, TuiCollectionDesc* description, TuiTreeState* state, TuiRowsProvider* provider);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_tree_handle_v1(TuiRect bounds, TuiTreeState* state, TuiRowsProvider* provider, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_task_list_draw_v1(nint renderer, TuiRect bounds, TuiCollectionDesc* description, TuiMenuState* state, TuiRowsProvider* provider);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_task_list_handle_v1(TuiRect bounds, TuiMenuState* state, TuiRowsProvider* provider, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_menu_draw_v1(nint renderer, TuiRect bounds, TuiCollectionDesc* description, TuiMenuState* state, TuiRowsProvider* provider);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_menu_handle_v1(TuiRect bounds, TuiMenuState* state, TuiRowsProvider* provider, TuiEvent* input, int* update);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_line_chart_create_v1(TuiAllocator* allocator, ulong sampleCapacity, ulong cellCapacity, nint* output);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern void tui_line_chart_destroy_v1(nint chart);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_line_chart_draw_v1(nint chart, nint renderer, TuiRect bounds, TuiSamplesProvider* provider, TuiRole role);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_event_queue_create_v1(TuiAllocator* allocator, ulong capacity, nint* output);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern void tui_event_queue_destroy_v1(nint queue);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_event_queue_try_push_v1(nint queue, TuiEvent* input);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_event_queue_try_pop_v1(nint queue, byte* payload, ulong capacity, TuiEvent* output);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_parser_create_v1(TuiAllocator* allocator, nint* output);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern void tui_parser_destroy_v1(nint parser);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_parser_feed_v1(nint parser, TuiBytes input, nint queue);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_parser_finish_v1(nint parser, nint queue);
    [DllImport(Library, CallingConvention = Convention, ExactSpelling = true)] public static extern int tui_parser_abort_v1(nint parser, nint queue);
}
