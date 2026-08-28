using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace Tui.Zig;

public sealed class TuiException(int result) : Exception($"tui error {result}")
{
    public int Result { get; } = result;
}

public static unsafe class Tui
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static void Check(int result)
    {
        if (result != Constants.Ok) throw new TuiException(result);
    }

    public static TuiAllocator Allocator => new()
    {
        Allocate = &Allocate,
        Deallocate = &Deallocate,
    };

    public static TuiBytes Utf8(string value, out void* allocation)
    {
        int length = StrictUtf8.GetByteCount(value);
        allocation = length == 0 ? null : NativeMemory.Alloc((nuint)length);
        if (length != 0 && allocation == null) throw new OutOfMemoryException();
        if (length != 0) StrictUtf8.GetBytes(value, new Span<byte>(allocation, length));
        return new TuiBytes { Pointer = (byte*)allocation, Length = (ulong)length };
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void* Allocate(void* context, ulong size, ulong alignment)
    {
        _ = context;
        try
        {
            if (alignment == 0 || (alignment & (alignment - 1)) != 0 ||
                size > (ulong)nuint.MaxValue || alignment > (ulong)nuint.MaxValue) return null;
            if (alignment < (ulong)sizeof(void*)) alignment = (ulong)sizeof(void*);
            ulong effective = size == 0 ? 1 : size;
            ulong mask = alignment - 1;
            if (effective > ulong.MaxValue - mask) return null;
            ulong rounded = (effective + mask) & ~mask;
            return NativeMemory.AlignedAlloc((nuint)rounded, (nuint)alignment);
        }
        catch
        {
            return null;
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void Deallocate(void* context, void* memory, ulong size, ulong alignment)
    {
        _ = context;
        _ = size;
        _ = alignment;
        try { NativeMemory.AlignedFree(memory); } catch { }
    }
}

public abstract class TuiSafeHandle : SafeHandle
{
    protected TuiSafeHandle(nint value) : base(nint.Zero, true) => SetHandle(value);
    public override bool IsInvalid => handle == nint.Zero;
}

public sealed unsafe class RendererHandle : TuiSafeHandle
{
    private RendererHandle(nint value) : base(value) { }
    public static RendererHandle Create(TuiSize size)
    {
        TuiAllocator allocator = Tui.Allocator;
        nint value;
        Tui.Check(Native.tui_renderer_create_v1(&allocator, size, null, &value));
        return new RendererHandle(value);
    }
    protected override bool ReleaseHandle() { Native.tui_renderer_destroy_v1(handle); return true; }
}

public sealed unsafe class TextInputHandle : TuiSafeHandle
{
    private TextInputHandle(nint value) : base(value) { }
    public static TextInputHandle Create(ulong capacity, string initial)
    {
        TuiAllocator allocator = Tui.Allocator;
        TuiBytes text = Tui.Utf8(initial, out void* allocation);
        try
        {
            nint value;
            Tui.Check(Native.tui_text_input_create_v1(&allocator, capacity, text, &value));
            return new TextInputHandle(value);
        }
        finally { NativeMemory.Free(allocation); }
    }
    protected override bool ReleaseHandle() { Native.tui_text_input_destroy_v1(handle); return true; }
}

public sealed unsafe class TextAreaHandle : TuiSafeHandle
{
    private TextAreaHandle(nint value) : base(value) { }
    public static TextAreaHandle Create(ulong capacity, string initial)
    {
        TuiAllocator allocator = Tui.Allocator;
        TuiBytes text = Tui.Utf8(initial, out void* allocation);
        try
        {
            nint value;
            Tui.Check(Native.tui_text_area_create_v1(&allocator, capacity, text, &value));
            return new TextAreaHandle(value);
        }
        finally { NativeMemory.Free(allocation); }
    }
    protected override bool ReleaseHandle() { Native.tui_text_area_destroy_v1(handle); return true; }
}

public sealed unsafe class LineChartHandle : TuiSafeHandle
{
    private LineChartHandle(nint value) : base(value) { }
    public static LineChartHandle Create(ulong sampleCapacity, ulong cellCapacity)
    {
        TuiAllocator allocator = Tui.Allocator;
        nint value;
        Tui.Check(Native.tui_line_chart_create_v1(&allocator, sampleCapacity, cellCapacity, &value));
        return new LineChartHandle(value);
    }
    protected override bool ReleaseHandle() { Native.tui_line_chart_destroy_v1(handle); return true; }
}

public sealed unsafe class EventQueueHandle : TuiSafeHandle
{
    private EventQueueHandle(nint value) : base(value) { }
    public static EventQueueHandle Create(ulong capacity)
    {
        TuiAllocator allocator = Tui.Allocator;
        nint value;
        Tui.Check(Native.tui_event_queue_create_v1(&allocator, capacity, &value));
        return new EventQueueHandle(value);
    }
    protected override bool ReleaseHandle() { Native.tui_event_queue_destroy_v1(handle); return true; }
}

public sealed unsafe class ParserHandle : TuiSafeHandle
{
    private ParserHandle(nint value) : base(value) { }
    public static ParserHandle Create()
    {
        TuiAllocator allocator = Tui.Allocator;
        nint value;
        Tui.Check(Native.tui_parser_create_v1(&allocator, &value));
        return new ParserHandle(value);
    }
    protected override bool ReleaseHandle() { Native.tui_parser_destroy_v1(handle); return true; }
}
