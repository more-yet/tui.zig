using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Tui.Zig;

namespace TuiZig.Showcase;

using Tui = global::Tui.Zig.Tui;

internal static unsafe class Program
{
    private const ushort Width = 80;
    private const ushort Height = 24;
    private static readonly double[] ChartSamples = [1, 2.5, 1.5, 4, 3, 5.5, 4.5, 7, 6, 8, 7, 9];
    private static readonly byte[] ImagePixels =
    [
        230, 70, 80, 245, 155, 55, 55, 190, 145, 60, 135, 225,
        245, 155, 55, 55, 190, 145, 60, 135, 225, 230, 70, 80,
        55, 190, 145, 60, 135, 225, 230, 70, 80, 245, 155, 55,
        60, 135, 225, 230, 70, 80, 245, 155, 55, 55, 190, 145,
    ];

    private static int Main(string[] arguments)
    {
        if (arguments.Length > 1 ||
            (arguments.Length == 1 && arguments[0] is not "--headless" and not "--headless-hash"))
        {
            Console.Error.WriteLine("usage: Showcase [--headless|--headless-hash]");
            return 2;
        }
        try
        {
            using Application application = new();
            application.Exercise();
            if (arguments.Length == 0)
            {
                RunInteractive(application);
                return 0;
            }
            byte[] output = RenderHeadless(application);
            if (arguments[0] == "--headless-hash")
                Console.WriteLine($"{Fnv1a(output):x16} {output.Length}");
            else
                Console.OpenStandardOutput().Write(output);
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    private sealed class Application : IDisposable
    {
        internal RendererHandle Renderer { get; private set; } = null!;
        internal TextInputHandle Input { get; private set; } = null!;
        internal TextAreaHandle Area { get; private set; } = null!;
        internal LineChartHandle Chart { get; private set; } = null!;
        internal EventQueueHandle Queue { get; private set; } = null!;
        internal ParserHandle Parser { get; private set; } = null!;
        internal Rows Rows { get; private set; } = null!;
        internal Samples Samples { get; private set; } = null!;
        internal OutputBuffer Output { get; } = new();
        internal TuiButtonState Button;
        internal TuiCheckboxState Checkbox;
        internal TuiRadioState Radio;
        internal TuiScrollState Scroll;
        internal TuiMenuState Menu;
        internal TuiTreeState Tree;
        internal byte Page;

        internal nint RendererPointer => Renderer.DangerousGetHandle();
        internal nint InputPointer => Input.DangerousGetHandle();
        internal nint AreaPointer => Area.DangerousGetHandle();
        internal nint ChartPointer => Chart.DangerousGetHandle();
        internal nint QueuePointer => Queue.DangerousGetHandle();
        internal nint ParserPointer => Parser.DangerousGetHandle();

        internal Application()
        {
            try
            {
                TuiVersion version = Native.tui_abi_version_v1();
                if (version.Major != 1) throw new InvalidOperationException($"unsupported tui ABI {version.Major}.{version.Minor}.{version.Patch}");
                Renderer = RendererHandle.Create(new TuiSize { Width = Width, Height = Height });
                Input = TextInputHandle.Create(128, "edit me");
                Area = TextAreaHandle.Create(1024, "Unicode: e\u0301 and 世界\nSoft-wrapped editor");
                Chart = LineChartHandle.Create(64, Width * Height);
                Queue = EventQueueHandle.Create(64);
                Parser = ParserHandle.Create();
                Rows = new Rows();
                Samples = new Samples(ChartSamples);
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            Output.Dispose();
            Samples?.Dispose();
            Rows?.Dispose();
            Parser?.Dispose();
            Queue?.Dispose();
            Chart?.Dispose();
            Area?.Dispose();
            Input?.Dispose();
            Renderer?.Dispose();
        }

        internal void Exercise()
        {
            TuiEvent inputEvent = new() { Kind = Constants.EventKey, KeyKind = Constants.KeyEnter, KeyAction = Constants.KeyPress };
            int update = Constants.UpdateIgnored;
            HandleControls(ref inputEvent, ref update);
            inputEvent.KeyKind = Constants.KeyDown;
            HandleCollections(ref inputEvent, ref update);

            Tui.Check(Native.tui_text_input_set_focus_v1(InputPointer, 1));
            Tui.Check(Native.tui_text_input_set_selection_v1(InputPointer, 0, 4));
            TuiBytes replacement = Tui.Utf8("type", out void* replacementAllocation);
            try { Tui.Check(Native.tui_text_input_replace_selection_v1(InputPointer, replacement)); }
            finally { NativeMemory.Free(replacementAllocation); }

            inputEvent.Kind = Constants.EventText;
            inputEvent.Payload = Tui.Utf8("!", out void* eventAllocation);
            try
            {
                Tui.Check(Native.tui_text_input_handle_v1(InputPointer, &inputEvent, &update));
                byte* value = stackalloc byte[1024];
                ulong needed;
                int failure;
                Tui.Check(Native.tui_text_input_copy_value_v1(InputPointer, value, 1024, &needed));
                Tui.Check(Native.tui_text_input_take_failure_v1(InputPointer, &failure));

                Tui.Check(Native.tui_text_area_set_focus_v1(AreaPointer, 1));
                Tui.Check(Native.tui_text_area_set_soft_wrap_v1(AreaPointer, 1));
                Tui.Check(Native.tui_text_area_layout_v1(AreaPointer, new TuiSize { Width = 48, Height = 8 }));
                Tui.Check(Native.tui_text_area_handle_v1(AreaPointer, &inputEvent, &update));
                Tui.Check(Native.tui_text_area_copy_value_v1(AreaPointer, value, 1024, &needed));
                Tui.Check(Native.tui_text_area_take_failure_v1(AreaPointer, &failure));
            }
            finally { NativeMemory.Free(eventAllocation); }

            inputEvent.Payload = Tui.Utf8("queued", out void* queuedAllocation);
            try { Tui.Check(Native.tui_event_queue_try_push_v1(QueuePointer, &inputEvent)); }
            finally { NativeMemory.Free(queuedAllocation); }
            PopDiscard();
            TuiBytes parserInput = Tui.Utf8("p", out void* parserAllocation);
            try { Tui.Check(Native.tui_parser_feed_v1(ParserPointer, parserInput, QueuePointer)); }
            finally { NativeMemory.Free(parserAllocation); }
            PopDiscard();
            Tui.Check(Native.tui_parser_finish_v1(ParserPointer, QueuePointer));
            Tui.Check(Native.tui_parser_abort_v1(ParserPointer, QueuePointer));
            Native.tui_renderer_invalidate_terminal_v1(RendererPointer);
        }

        private void PopDiscard()
        {
            byte* payload = stackalloc byte[256];
            TuiEvent output;
            Tui.Check(Native.tui_event_queue_try_pop_v1(QueuePointer, payload, 256, &output));
        }

        private void HandleControls(ref TuiEvent inputEvent, ref int update)
        {
            void* buttonAllocation = null;
            void* checkboxAllocation = null;
            void* radioAllocation = null;
            try
            {
                TuiControlDesc button = Control("Activate", out buttonAllocation);
                TuiControlDesc checkbox = Control("Checked", out checkboxAllocation);
                TuiControlDesc radio = Control("Choice two", out radioAllocation);
                TuiEvent eventValue = inputEvent;
                int updateValue = update;
                TuiButtonState buttonState = Button;
                TuiCheckboxState checkboxState = Checkbox;
                TuiRadioState radioState = Radio;
                Tui.Check(Native.tui_button_handle_v1(&button, &buttonState, &eventValue, &updateValue));
                Tui.Check(Native.tui_checkbox_handle_v1(&checkbox, &checkboxState, &eventValue, &updateValue));
                Tui.Check(Native.tui_radio_handle_v1(&radio, &radioState, 2, &eventValue, &updateValue));
                Button = buttonState;
                Checkbox = checkboxState;
                Radio = radioState;
                update = updateValue;
            }
            finally
            {
                NativeMemory.Free(buttonAllocation);
                NativeMemory.Free(checkboxAllocation);
                NativeMemory.Free(radioAllocation);
            }
        }

        private void HandleCollections(ref TuiEvent inputEvent, ref int update)
        {
            TuiRowsProvider provider = Rows.Provider;
            TuiEvent eventValue = inputEvent;
            int updateValue = update;
            TuiScrollState scroll = Scroll;
            TuiTreeState tree = Tree;
            TuiMenuState menu = Menu;
            Tui.Check(Native.tui_scrollback_handle_v1(Rect(2, 2, 24, 4), &scroll, &provider, &eventValue, &updateValue));
            Tui.Check(Native.tui_list_handle_v1(Rect(2, 7, 24, 4), &scroll, &provider, &eventValue, &updateValue));
            Tui.Check(Native.tui_table_handle_v1(Rect(28, 2, 28, 7), &scroll, &provider, &eventValue, &updateValue));
            Tui.Check(Native.tui_tree_handle_v1(Rect(2, 12, 24, 5), &tree, &provider, &eventValue, &updateValue));
            Tui.Check(Native.tui_task_list_handle_v1(Rect(28, 10, 28, 6), &menu, &provider, &eventValue, &updateValue));
            Tui.Check(Native.tui_menu_handle_v1(Rect(2, 18, 24, 4), &menu, &provider, &eventValue, &updateValue));
            Scroll = scroll;
            Tree = tree;
            Menu = menu;
            update = updateValue;
        }

        internal byte[] DrawFrame(TuiSize size)
        {
            Tui.Check(Native.tui_renderer_resize_v1(RendererPointer, size));
            Tui.Check(Native.tui_renderer_begin_frame_v1(RendererPointer));
            DrawPanel(size, out TuiRect content);
            void* imageAllocation = null;
            try
            {
                if (size.Width < Width || size.Height < Height)
                {
                    TuiTextDesc description = Text("The showcase needs an 80x24 terminal.", out void* allocation);
                    description.Alignment = Constants.AlignCenter;
                    try { Tui.Check(Native.tui_paragraph_draw_v1(RendererPointer, content, &description)); }
                    finally { NativeMemory.Free(allocation); }
                }
                else if (Page == 0) DrawControls();
                else imageAllocation = DrawData();

                Output.Reset();
                TuiCapabilities capabilities = new()
                {
                    ColorDepth = Constants.ColorTruecolor,
                    ImageProtocol = Constants.ImageNone,
                    SynchronizedOutput = 1,
                };
                TuiOutput output = Output.Native;
                TuiFrameStats stats;
                Tui.Check(Native.tui_renderer_present_v1(RendererPointer, capabilities, output, &stats));
                return Output.Bytes();
            }
            finally { NativeMemory.Free(imageAllocation); }
        }

        private void DrawPanel(TuiSize size, out TuiRect content)
        {
            TuiPanelDesc panel = new()
            {
                Title = Tui.Utf8(Page == 0 ? " tui.zig C ABI: controls " : " tui.zig C ABI: data ", out void* allocation),
                BorderRole = Role(14, 0),
                TitleRole = Role(11, 0),
                Enabled = 1,
                Focused = 1,
            };
            try
            {
                TuiRect bounds = Rect(0, 0, size.Width, size.Height);
                Tui.Check(Native.tui_panel_draw_v1(RendererPointer, bounds, &panel));
                TuiRect output;
                Tui.Check(Native.tui_panel_content_rect_v1(bounds, &output));
                content = output;
            }
            finally { NativeMemory.Free(allocation); }
        }

        private void DrawControls()
        {
            DrawParagraph(Rect(2, 2, 76, 2), "All bindings call the same versioned C ABI. Tab changes page; q or Escape quits.");
            DrawLabel(Rect(2, 5, 44, 1), "Unicode 17: e\u0301  世界  🦀");
            TuiGaugeDesc gauge = new()
            {
                Value = 73,
                Total = 100,
                FilledRole = Role(0, 10),
                EmptyRole = Role(8, 0),
                Enabled = 1,
            };
            Tui.Check(Native.tui_gauge_draw_v1(RendererPointer, Rect(2, 7, 44, 1), &gauge));
            DrawControl(Rect(2, 10, 18, 1), "Activate", 0);
            DrawControl(Rect(2, 12, 18, 1), "Checked", 1);
            DrawControl(Rect(2, 14, 18, 1), "Choice two", 2);
            Tui.Check(Native.tui_text_input_draw_v1(InputPointer, RendererPointer, Rect(28, 10, 48, 1)));
            Tui.Check(Native.tui_text_area_layout_v1(AreaPointer, new TuiSize { Width = 48, Height = 8 }));
            Tui.Check(Native.tui_text_area_draw_v1(AreaPointer, RendererPointer, Rect(28, 13, 48, 8)));
        }

        private void DrawControl(TuiRect bounds, string label, int kind)
        {
            TuiControlDesc description = Control(label, out void* allocation);
            try
            {
                TuiButtonState button = Button;
                TuiCheckboxState checkbox = Checkbox;
                TuiRadioState radio = Radio;
                int result = kind switch
                {
                    0 => Native.tui_button_draw_v1(RendererPointer, bounds, &description, &button),
                    1 => Native.tui_checkbox_draw_v1(RendererPointer, bounds, &description, &checkbox),
                    _ => Native.tui_radio_draw_v1(RendererPointer, bounds, &description, &radio, 2),
                };
                Tui.Check(result);
                Button = button;
                Checkbox = checkbox;
                Radio = radio;
            }
            finally { NativeMemory.Free(allocation); }
        }

        private void* DrawData()
        {
            TuiCollectionDesc description = Collection();
            TuiRowsProvider provider = Rows.Provider;
            TuiScrollState scroll = Scroll;
            TuiTreeState tree = Tree;
            TuiMenuState menu = Menu;
            Tui.Check(Native.tui_scrollback_draw_v1(RendererPointer, Rect(2, 2, 24, 4), &description, &scroll, &provider));
            Tui.Check(Native.tui_list_draw_v1(RendererPointer, Rect(2, 7, 24, 4), &description, &scroll, &provider));
            Tui.Check(Native.tui_tree_draw_v1(RendererPointer, Rect(2, 12, 24, 5), &description, &tree, &provider));
            Tui.Check(Native.tui_menu_draw_v1(RendererPointer, Rect(2, 18, 24, 4), &description, &menu, &provider));
            TuiColumn* columns = stackalloc TuiColumn[2];
            void* firstTitle = null;
            void* secondTitle = null;
            try
            {
                columns[0] = new TuiColumn { Title = Tui.Utf8("component", out firstTitle), Width = 14 };
                columns[1] = new TuiColumn { Title = Tui.Utf8("state", out secondTitle), Width = 11 };
                Tui.Check(Native.tui_table_draw_v1(RendererPointer, Rect(28, 2, 28, 7), &description, &scroll, &provider, columns, 2));
            }
            finally { NativeMemory.Free(firstTitle); NativeMemory.Free(secondTitle); }
            Tui.Check(Native.tui_task_list_draw_v1(RendererPointer, Rect(28, 10, 28, 6), &description, &menu, &provider));
            Scroll = scroll;
            Tree = tree;
            Menu = menu;
            TuiSamplesProvider samples = Samples.Provider;
            Tui.Check(Native.tui_line_chart_draw_v1(ChartPointer, RendererPointer, Rect(58, 2, 20, 10), &samples, Role(10, 0)));

            void* imageAllocation = NativeMemory.Alloc((nuint)ImagePixels.Length);
            if (imageAllocation == null) throw new OutOfMemoryException();
            ImagePixels.CopyTo(new Span<byte>(imageAllocation, ImagePixels.Length));
            TuiImage image = new()
            {
                Pixels = new TuiBytes { Pointer = (byte*)imageAllocation, Length = (ulong)ImagePixels.Length },
                Width = 4,
                Height = 4,
                Format = Constants.PixelsRgb8,
            };
            TuiImageOptions options = new() { ImageId = 7, PlacementId = 1 };
            try
            {
                Tui.Check(Native.tui_renderer_put_image_v1(RendererPointer, Rect(58, 14, 4, 4), image, options));
                DrawParagraph(Rect(64, 14, 14, 4), "parser + SPSC queue\nRGB image 4x4");
                return imageAllocation;
            }
            catch
            {
                NativeMemory.Free(imageAllocation);
                throw;
            }
        }

        private void DrawLabel(TuiRect bounds, string value)
        {
            TuiTextDesc description = Text(value, out void* allocation);
            try { Tui.Check(Native.tui_label_draw_v1(RendererPointer, bounds, &description)); }
            finally { NativeMemory.Free(allocation); }
        }

        private void DrawParagraph(TuiRect bounds, string value)
        {
            TuiTextDesc description = Text(value, out void* allocation);
            try { Tui.Check(Native.tui_paragraph_draw_v1(RendererPointer, bounds, &description)); }
            finally { NativeMemory.Free(allocation); }
        }

        internal bool Dispatch(ref TuiEvent inputEvent)
        {
            if (inputEvent.Kind == Constants.EventKey && inputEvent.KeyAction != Constants.KeyRelease)
            {
                if (inputEvent.KeyKind == Constants.KeyEscape ||
                    (inputEvent.KeyKind == Constants.KeyCodepoint && inputEvent.KeyValue == 'q')) return false;
                if (inputEvent.KeyKind == Constants.KeyTab) { Page ^= 1; return true; }
            }
            int update = Constants.UpdateIgnored;
            HandleControls(ref inputEvent, ref update);
            TuiEvent eventValue = inputEvent;
            Tui.Check(Native.tui_text_input_handle_v1(InputPointer, &eventValue, &update));
            Tui.Check(Native.tui_text_area_handle_v1(AreaPointer, &eventValue, &update));
            HandleCollections(ref inputEvent, ref update);
            return true;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OutputState { internal byte* Data; internal ulong Length, Capacity; }

    private sealed class OutputBuffer : IDisposable
    {
        private OutputState* _state;
        internal OutputBuffer()
        {
            _state = (OutputState*)NativeMemory.AllocZeroed((nuint)sizeof(OutputState));
            if (_state == null) throw new OutOfMemoryException();
        }
        internal TuiOutput Native => new() { Context = _state, Write = &Write };
        internal void Reset() => _state->Length = 0;
        internal byte[] Bytes() => new ReadOnlySpan<byte>(_state->Data, checked((int)_state->Length)).ToArray();
        public void Dispose()
        {
            if (_state == null) return;
            NativeMemory.Free(_state->Data);
            NativeMemory.Free(_state);
            _state = null;
        }

        [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
        private static int Write(void* context, byte* bytes, ulong length)
        {
            try
            {
                if (context == null || (bytes == null && length != 0)) return Constants.ErrorOutput;
                OutputState* state = (OutputState*)context;
                if (length > int.MaxValue || state->Length > (ulong)int.MaxValue - length) return Constants.ErrorOutput;
                ulong needed = state->Length + length;
                if (needed > state->Capacity)
                {
                    ulong capacity = state->Capacity == 0 ? 4096 : state->Capacity;
                    while (capacity < needed)
                    {
                        if (capacity > ulong.MaxValue / 2) { capacity = needed; break; }
                        capacity *= 2;
                    }
                    if (capacity > (ulong)nuint.MaxValue) return Constants.ErrorOutput;
                    void* data = NativeMemory.Realloc(state->Data, (nuint)capacity);
                    if (data == null) return Constants.ErrorOutput;
                    state->Data = (byte*)data;
                    state->Capacity = capacity;
                }
                if (length != 0)
                {
                    int count = checked((int)length);
                    int offset = checked((int)state->Length);
                    new ReadOnlySpan<byte>(bytes, count).CopyTo(new Span<byte>(state->Data + offset, count));
                }
                state->Length = needed;
                return Constants.Ok;
            }
            catch { return Constants.ErrorOutput; }
        }
    }

    private sealed class Rows : IDisposable
    {
        private readonly List<nint> _allocations = [];
        private TuiProviderRow* _rows;
        internal TuiRowsProvider Provider => new() { Context = _rows, Count = 5, Read = &Read };

        internal Rows()
        {
            string[] labels = ["renderer", "controls", "editors", "providers", "parser"];
            string[] states = ["ready", "checked", "editing", "streaming", "bounded"];
            try
            {
                _rows = (TuiProviderRow*)NativeMemory.AllocZeroed(5, (nuint)sizeof(TuiProviderRow));
                if (_rows == null) throw new OutOfMemoryException();
                for (int index = 0; index < 5; ++index)
                {
                    _rows[index].Text = Allocate(labels[index]);
                    TuiBytes* cells = (TuiBytes*)NativeMemory.AllocZeroed(2, (nuint)sizeof(TuiBytes));
                    if (cells == null) throw new OutOfMemoryException();
                    try { _allocations.Add((nint)cells); }
                    catch { NativeMemory.Free(cells); throw; }
                    cells[0] = Allocate(labels[index]);
                    cells[1] = Allocate(states[index]);
                    _rows[index].Cells = cells;
                    _rows[index].CellCount = 2;
                    _rows[index].Depth = index is 1 or 2 ? 1u : 0u;
                    _rows[index].Status = index;
                    if (index == 0) _rows[index].Flags = Constants.RowHasChildren | Constants.RowExpanded;
                }
            }
            catch { Dispose(); throw; }
        }

        private TuiBytes Allocate(string value)
        {
            TuiBytes bytes = Tui.Utf8(value, out void* allocation);
            try { _allocations.Add((nint)allocation); }
            catch { NativeMemory.Free(allocation); throw; }
            return bytes;
        }

        public void Dispose()
        {
            foreach (nint allocation in _allocations) NativeMemory.Free((void*)allocation);
            _allocations.Clear();
            NativeMemory.Free(_rows);
            _rows = null;
        }

        [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
        private static int Read(void* context, ulong first, uint count, TuiProviderRow* rows)
        {
            try
            {
                if (context == null || rows == null || first > 5 || count > 5 - first) return Constants.ErrorProvider;
                TuiProviderRow* source = (TuiProviderRow*)context;
                for (uint index = 0; index < count; ++index) rows[index] = source[checked((int)(first + index))];
                return Constants.Ok;
            }
            catch { return Constants.ErrorProvider; }
        }
    }

    private sealed class Samples : IDisposable
    {
        private double* _samples;
        private readonly ulong _count;
        internal TuiSamplesProvider Provider => new() { Context = _samples, Count = _count, Read = &Read };
        internal Samples(double[] values)
        {
            _count = (ulong)values.Length;
            _samples = (double*)NativeMemory.Alloc((nuint)values.Length, (nuint)sizeof(double));
            if (values.Length != 0 && _samples == null) throw new OutOfMemoryException();
            values.CopyTo(new Span<double>(_samples, values.Length));
        }
        public void Dispose() { NativeMemory.Free(_samples); _samples = null; }

        [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
        private static int Read(void* context, ulong first, uint count, double* output)
        {
            try
            {
                if (context == null || output == null || first > 12 || count > 12 - first) return Constants.ErrorProvider;
                double* input = (double*)context;
                for (uint index = 0; index < count; ++index) output[index] = input[checked((int)(first + index))];
                return Constants.Ok;
            }
            catch { return Constants.ErrorProvider; }
        }
    }

    private sealed class TerminalMode : IDisposable
    {
        private readonly string _state;
        internal TerminalMode()
        {
            if (Console.IsInputRedirected || Console.IsOutputRedirected) throw new InvalidOperationException("interactive mode requires a terminal");
            _state = Run("-g", true);
            try
            {
                _ = Run("raw -echo isig", false);
                Console.OpenStandardOutput().Write("\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h"u8);
            }
            catch
            {
                try { _ = Run(_state, false); } catch { }
                try { Console.OpenStandardOutput().Write("\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l"u8); } catch { }
                throw;
            }
        }
        public void Dispose()
        {
            try { _ = Run(_state, false); } catch { }
            try { Console.OpenStandardOutput().Write("\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l"u8); } catch { }
        }
        private static string Run(string arguments, bool capture)
        {
            using Process process = new();
            process.StartInfo.FileName = "stty";
            process.StartInfo.UseShellExecute = false;
            process.StartInfo.RedirectStandardOutput = capture;
            foreach (string argument in arguments.Split(' ', StringSplitOptions.RemoveEmptyEntries)) process.StartInfo.ArgumentList.Add(argument);
            process.Start();
            string output = capture ? process.StandardOutput.ReadToEnd().Trim() : string.Empty;
            process.WaitForExit();
            if (process.ExitCode != 0) throw new InvalidOperationException("stty failed");
            return output;
        }
    }

    private static void RunInteractive(Application application)
    {
        using TerminalMode terminal = new();
        Stream input = Console.OpenStandardInput();
        Stream output = Console.OpenStandardOutput();
        byte[] buffer = new byte[64];
        byte* payload = stackalloc byte[256];
        while (true)
        {
            ushort columns = checked((ushort)Math.Clamp(Console.WindowWidth, 1, ushort.MaxValue));
            ushort rows = checked((ushort)Math.Clamp(Console.WindowHeight, 1, ushort.MaxValue));
            output.Write(application.DrawFrame(new TuiSize { Width = columns, Height = rows }));
            int count = input.Read(buffer);
            if (count == 0) return;
            fixed (byte* inputPointer = buffer)
            {
                TuiBytes bytes = new() { Pointer = inputPointer, Length = (ulong)count };
                Tui.Check(Native.tui_parser_feed_v1(application.ParserPointer, bytes, application.QueuePointer));
            }
            while (true)
            {
                TuiEvent inputEvent;
                int result = Native.tui_event_queue_try_pop_v1(application.QueuePointer, payload, 256, &inputEvent);
                if (result == Constants.ErrorQueueEmpty) break;
                Tui.Check(result);
                if (!application.Dispatch(ref inputEvent)) return;
            }
        }
    }

    private static byte[] RenderHeadless(Application application)
    {
        byte[] first = application.DrawFrame(new TuiSize { Width = Width, Height = Height });
        application.Page = 1;
        Native.tui_renderer_invalidate_terminal_v1(application.RendererPointer);
        byte[] second = application.DrawFrame(new TuiSize { Width = Width, Height = Height });
        byte[] result = new byte[first.Length + second.Length];
        first.CopyTo(result, 0);
        second.CopyTo(result, first.Length);
        return result;
    }

    private static TuiColor Indexed(byte value) => new() { Kind = Constants.ColorIndexed, Index = value };
    private static TuiStyle Style(byte foreground, byte background, byte attributes = 0) => new()
    {
        Foreground = Indexed(foreground),
        Background = Indexed(background),
        Attributes = attributes,
    };
    private static TuiRole Role(byte foreground, byte background) => new()
    {
        Normal = Style(foreground, background),
        Focused = Style(0, 14, 1),
        Disabled = Style(8, background),
        HasFocused = 1,
        HasDisabled = 1,
    };
    private static TuiTextDesc Text(string value, out void* allocation) => new()
    {
        Text = Tui.Utf8(value, out allocation),
        Role = Role(15, 0),
        Enabled = 1,
        WidthProfile = Constants.WidthNarrow,
        Alignment = Constants.AlignLeft,
    };
    private static TuiControlDesc Control(string value, out void* allocation) => new()
    {
        Label = Tui.Utf8(value, out allocation),
        Role = Role(15, 0),
        IndicatorRole = Role(10, 0),
        Enabled = 1,
        Focused = 1,
    };
    private static TuiCollectionDesc Collection() => new()
    {
        RowRole = Role(15, 0),
        SelectedRole = Role(0, 14),
        HeaderRole = Role(11, 0),
        Enabled = 1,
        Focused = 1,
        WidthProfile = Constants.WidthNarrow,
    };
    private static TuiRect Rect(ushort x, ushort y, ushort width, ushort height) => new() { X = x, Y = y, Width = width, Height = height };
    private static ulong Fnv1a(ReadOnlySpan<byte> value)
    {
        ulong hash = 14_695_981_039_346_656_037;
        foreach (byte item in value) hash = (hash ^ item) * 1_099_511_628_211;
        return hash;
    }
}
