use core::ffi::c_void;
use std::{
    io::{self, Read, Write},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
};
use tui_zig::{EventQueue, LineChart, Parser, Renderer, TextArea, TextInput, check, raw, utf8};

const WIDTH: u16 = 80;
const HEIGHT: u16 = 24;
const ROW_LABELS: [&str; 5] = ["renderer", "controls", "editors", "providers", "parser"];
const ROW_STATES: [&str; 5] = ["ready", "checked", "editing", "streaming", "bounded"];
const CHART_SAMPLES: [f64; 12] = [1.0, 2.5, 1.5, 4.0, 3.0, 5.5, 4.5, 7.0, 6.0, 8.0, 7.0, 9.0];
const IMAGE_PIXELS: [u8; 48] = [
    230, 70, 80, 245, 155, 55, 55, 190, 145, 60, 135, 225, 245, 155, 55, 55, 190, 145, 60, 135,
    225, 230, 70, 80, 55, 190, 145, 60, 135, 225, 230, 70, 80, 245, 155, 55, 60, 135, 225, 230, 70,
    80, 245, 155, 55, 55, 190, 145,
];

struct RowsData {
    cells: [[raw::tui_bytes_v1; 2]; 5],
}

impl RowsData {
    fn new() -> Self {
        Self {
            cells: [[raw::tui_bytes_v1 {
                ptr: ptr::null(),
                len: 0,
            }; 2]; 5],
        }
    }

    fn provider(&mut self) -> raw::tui_rows_provider_v1 {
        raw::tui_rows_provider_v1 {
            context: ptr::from_mut(self).cast(),
            count: ROW_LABELS.len() as u64,
            read: Some(read_rows),
        }
    }
}

unsafe extern "C" fn read_rows(
    context: *mut c_void,
    first: u64,
    count: u32,
    rows: *mut raw::tui_provider_row_v1,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(first) = usize::try_from(first) else {
            return raw::TUI_ERROR_PROVIDER_V1;
        };
        let Ok(count) = usize::try_from(count) else {
            return raw::TUI_ERROR_PROVIDER_V1;
        };
        let Some(end) = first.checked_add(count) else {
            return raw::TUI_ERROR_PROVIDER_V1;
        };
        if context.is_null() || rows.is_null() || end > ROW_LABELS.len() {
            return raw::TUI_ERROR_PROVIDER_V1;
        }
        let data = unsafe { &mut *context.cast::<RowsData>() };
        for offset in 0..count {
            let index = first + offset;
            data.cells[index][0] = utf8(ROW_LABELS[index]);
            data.cells[index][1] = utf8(ROW_STATES[index]);
            unsafe {
                rows.add(offset).write(raw::tui_provider_row_v1 {
                    text: utf8(ROW_LABELS[index]),
                    cells: data.cells[index].as_ptr(),
                    cell_count: 2,
                    depth: u32::from(index == 1 || index == 2),
                    status: (index % 5) as i32,
                    flags: if index == 0 {
                        raw::TUI_ROW_HAS_CHILDREN_V1 | raw::TUI_ROW_EXPANDED_V1
                    } else {
                        0
                    },
                });
            }
        }
        raw::TUI_OK_V1
    }))
    .unwrap_or(raw::TUI_ERROR_PROVIDER_V1)
}

unsafe extern "C" fn read_samples(
    _: *mut c_void,
    first: u64,
    count: u32,
    samples: *mut f64,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Ok(first), Ok(count)) = (usize::try_from(first), usize::try_from(count)) else {
            return raw::TUI_ERROR_PROVIDER_V1;
        };
        let Some(end) = first.checked_add(count) else {
            return raw::TUI_ERROR_PROVIDER_V1;
        };
        if samples.is_null() || end > CHART_SAMPLES.len() {
            return raw::TUI_ERROR_PROVIDER_V1;
        }
        unsafe { ptr::copy_nonoverlapping(CHART_SAMPLES.as_ptr().add(first), samples, count) };
        raw::TUI_OK_V1
    }))
    .unwrap_or(raw::TUI_ERROR_PROVIDER_V1)
}

unsafe extern "C" fn write_output(context: *mut c_void, bytes: *const u8, len: u64) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(len) = usize::try_from(len) else {
            return raw::TUI_ERROR_OUTPUT_V1;
        };
        if context.is_null() || (bytes.is_null() && len != 0) {
            return raw::TUI_ERROR_OUTPUT_V1;
        }
        let output = unsafe { &mut *context.cast::<Vec<u8>>() };
        if output.try_reserve(len).is_err() {
            return raw::TUI_ERROR_OUTPUT_V1;
        }
        output.extend_from_slice(unsafe { std::slice::from_raw_parts(bytes, len) });
        raw::TUI_OK_V1
    }))
    .unwrap_or(raw::TUI_ERROR_OUTPUT_V1)
}

struct App {
    renderer: Renderer,
    input: TextInput,
    area: TextArea,
    chart: LineChart,
    queue: EventQueue,
    parser: Parser,
    button: raw::tui_button_state_v1,
    checkbox: raw::tui_checkbox_state_v1,
    radio: raw::tui_radio_state_v1,
    scroll: raw::tui_scroll_state_v1,
    menu: raw::tui_menu_state_v1,
    tree: raw::tui_tree_state_v1,
    page: u8,
}

impl App {
    fn new() -> tui_zig::Result<Self> {
        let version = unsafe { raw::tui_abi_version_v1() };
        if version.major != 1 {
            return Err(tui_zig::Error(raw::TUI_ERROR_UNSUPPORTED_V1));
        }
        Ok(Self {
            renderer: Renderer::new(size(WIDTH, HEIGHT))?,
            input: TextInput::new(128, "edit me")?,
            area: TextArea::new(1024, "Unicode: e\u{301} and 世界\nSoft-wrapped editor")?,
            chart: LineChart::new(64, u64::from(WIDTH) * u64::from(HEIGHT))?,
            queue: EventQueue::new(64)?,
            parser: Parser::new()?,
            button: zeroed(),
            checkbox: zeroed(),
            radio: zeroed(),
            scroll: zeroed(),
            menu: zeroed(),
            tree: zeroed(),
            page: 0,
        })
    }

    fn exercise(&mut self) -> tui_zig::Result<()> {
        let mut rows_data = RowsData::new();
        let rows = rows_data.provider();
        let mut event: raw::tui_event_v1 = zeroed();
        let mut update = raw::TUI_UPDATE_IGNORED_V1;
        let mut value = [0u8; 1024];
        let mut needed = 0;
        let mut failure = 0;

        event.kind = raw::TUI_EVENT_KEY_V1;
        event.key_kind = raw::TUI_KEY_ENTER_V1;
        event.key_action = raw::TUI_KEY_PRESS_V1;
        unsafe {
            check(raw::tui_button_handle_v1(
                &control("Activate", true),
                &mut self.button,
                &event,
                &mut update,
            ))?;
            check(raw::tui_checkbox_handle_v1(
                &control("Checked", true),
                &mut self.checkbox,
                &event,
                &mut update,
            ))?;
            check(raw::tui_radio_handle_v1(
                &control("Choice two", true),
                &mut self.radio,
                2,
                &event,
                &mut update,
            ))?;
        }

        event.key_kind = raw::TUI_KEY_DOWN_V1;
        unsafe {
            check(raw::tui_scrollback_handle_v1(
                rect(2, 2, 24, 4),
                &mut self.scroll,
                &rows,
                &event,
                &mut update,
            ))?;
            check(raw::tui_list_handle_v1(
                rect(2, 7, 24, 4),
                &mut self.scroll,
                &rows,
                &event,
                &mut update,
            ))?;
            check(raw::tui_table_handle_v1(
                rect(28, 2, 28, 7),
                &mut self.scroll,
                &rows,
                &event,
                &mut update,
            ))?;
            check(raw::tui_tree_handle_v1(
                rect(2, 12, 24, 5),
                &mut self.tree,
                &rows,
                &event,
                &mut update,
            ))?;
            check(raw::tui_task_list_handle_v1(
                rect(28, 10, 28, 6),
                &mut self.menu,
                &rows,
                &event,
                &mut update,
            ))?;
            check(raw::tui_menu_handle_v1(
                rect(2, 18, 24, 4),
                &mut self.menu,
                &rows,
                &event,
                &mut update,
            ))?;

            check(raw::tui_text_input_set_focus_v1(self.input.as_ptr(), 1))?;
            check(raw::tui_text_input_set_selection_v1(
                self.input.as_ptr(),
                0,
                4,
            ))?;
            check(raw::tui_text_input_replace_selection_v1(
                self.input.as_ptr(),
                utf8("type"),
            ))?;
            event.kind = raw::TUI_EVENT_TEXT_V1;
            event.payload = utf8("!");
            check(raw::tui_text_input_handle_v1(
                self.input.as_ptr(),
                &event,
                &mut update,
            ))?;
            check(raw::tui_text_input_copy_value_v1(
                self.input.as_ptr(),
                value.as_mut_ptr(),
                value.len() as u64,
                &mut needed,
            ))?;
            check(raw::tui_text_input_take_failure_v1(
                self.input.as_ptr(),
                &mut failure,
            ))?;

            check(raw::tui_text_area_set_focus_v1(self.area.as_ptr(), 1))?;
            check(raw::tui_text_area_set_soft_wrap_v1(self.area.as_ptr(), 1))?;
            check(raw::tui_text_area_layout_v1(
                self.area.as_ptr(),
                size(48, 8),
            ))?;
            check(raw::tui_text_area_handle_v1(
                self.area.as_ptr(),
                &event,
                &mut update,
            ))?;
            check(raw::tui_text_area_copy_value_v1(
                self.area.as_ptr(),
                value.as_mut_ptr(),
                value.len() as u64,
                &mut needed,
            ))?;
            check(raw::tui_text_area_take_failure_v1(
                self.area.as_ptr(),
                &mut failure,
            ))?;

            event.payload = utf8("queued");
            check(raw::tui_event_queue_try_push_v1(
                self.queue.as_ptr(),
                &event,
            ))?;
            self.pop_discard()?;
            check(raw::tui_parser_feed_v1(
                self.parser.as_ptr(),
                utf8("p"),
                self.queue.as_ptr(),
            ))?;
            self.pop_discard()?;
            check(raw::tui_parser_finish_v1(
                self.parser.as_ptr(),
                self.queue.as_ptr(),
            ))?;
            check(raw::tui_parser_abort_v1(
                self.parser.as_ptr(),
                self.queue.as_ptr(),
            ))?;
            raw::tui_renderer_invalidate_terminal_v1(self.renderer.as_ptr());
        }
        Ok(())
    }

    fn pop_discard(&self) -> tui_zig::Result<()> {
        let mut payload = [0u8; 256];
        let mut event = zeroed();
        check(unsafe {
            raw::tui_event_queue_try_pop_v1(
                self.queue.as_ptr(),
                payload.as_mut_ptr(),
                payload.len() as u64,
                &mut event,
            )
        })
    }

    fn draw_frame(
        &mut self,
        dimensions: raw::tui_size_v1,
        output: &mut Vec<u8>,
    ) -> tui_zig::Result<()> {
        check(unsafe { raw::tui_renderer_resize_v1(self.renderer.as_ptr(), dimensions) })?;
        check(unsafe { raw::tui_renderer_begin_frame_v1(self.renderer.as_ptr()) })?;
        let outer = raw::tui_panel_desc_v1 {
            title: utf8(if self.page == 0 {
                " tui.zig C ABI: controls "
            } else {
                " tui.zig C ABI: data "
            }),
            border_role: role(14, 0),
            title_role: role(11, 0),
            enabled: 1,
            focused: 1,
            reserved: [0; 2],
        };
        let bounds = rect(0, 0, dimensions.width, dimensions.height);
        check(unsafe { raw::tui_panel_draw_v1(self.renderer.as_ptr(), bounds, &outer) })?;
        let mut content = zeroed();
        check(unsafe { raw::tui_panel_content_rect_v1(bounds, &mut content) })?;

        if dimensions.width < WIDTH || dimensions.height < HEIGHT {
            let mut desc = text("The showcase needs an 80x24 terminal.");
            desc.alignment = raw::TUI_ALIGN_CENTER_V1;
            check(unsafe { raw::tui_paragraph_draw_v1(self.renderer.as_ptr(), content, &desc) })?;
        } else if self.page == 0 {
            self.draw_controls()?;
        } else {
            self.draw_data()?;
        }

        let capabilities = raw::tui_capabilities_v1 {
            color_depth: raw::TUI_COLOR_TRUECOLOR_V1,
            image_protocol: raw::TUI_IMAGE_NONE_V1,
            synchronized_output: 1,
            background_color_erase: 0,
            reserved: [0; 6],
        };
        let sink = raw::tui_output_v1 {
            context: ptr::from_mut(output).cast(),
            write: Some(write_output),
        };
        let mut stats: raw::tui_frame_stats_v1 = Default::default();
        check(unsafe {
            raw::tui_renderer_present_v1(self.renderer.as_ptr(), capabilities, sink, &mut stats)
        })
    }

    fn draw_controls(&mut self) -> tui_zig::Result<()> {
        let paragraph = text(
            "All bindings call the same versioned C ABI. Tab changes page; q or Escape quits.",
        );
        check(unsafe {
            raw::tui_paragraph_draw_v1(self.renderer.as_ptr(), rect(2, 2, 76, 2), &paragraph)
        })?;
        let label = text("Unicode 17: e\u{301}  世界  🦀");
        check(unsafe {
            raw::tui_label_draw_v1(self.renderer.as_ptr(), rect(2, 5, 44, 1), &label)
        })?;
        let gauge = raw::tui_gauge_desc_v1 {
            value: 73,
            total: 100,
            filled_role: role(0, 10),
            empty_role: role(8, 0),
            enabled: 1,
            reserved: [0; 7],
        };
        check(unsafe {
            raw::tui_gauge_draw_v1(self.renderer.as_ptr(), rect(2, 7, 44, 1), &gauge)
        })?;
        check(unsafe {
            raw::tui_button_draw_v1(
                self.renderer.as_ptr(),
                rect(2, 10, 18, 1),
                &control("Activate", true),
                &mut self.button,
            )
        })?;
        check(unsafe {
            raw::tui_checkbox_draw_v1(
                self.renderer.as_ptr(),
                rect(2, 12, 18, 1),
                &control("Checked", true),
                &mut self.checkbox,
            )
        })?;
        check(unsafe {
            raw::tui_radio_draw_v1(
                self.renderer.as_ptr(),
                rect(2, 14, 18, 1),
                &control("Choice two", true),
                &mut self.radio,
                2,
            )
        })?;
        check(unsafe {
            raw::tui_text_input_draw_v1(
                self.input.as_ptr(),
                self.renderer.as_ptr(),
                rect(28, 10, 48, 1),
            )
        })?;
        check(unsafe { raw::tui_text_area_layout_v1(self.area.as_ptr(), size(48, 8)) })?;
        check(unsafe {
            raw::tui_text_area_draw_v1(
                self.area.as_ptr(),
                self.renderer.as_ptr(),
                rect(28, 13, 48, 8),
            )
        })
    }

    fn draw_data(&mut self) -> tui_zig::Result<()> {
        let mut rows_data = RowsData::new();
        let rows = rows_data.provider();
        let desc = collection();
        check(unsafe {
            raw::tui_scrollback_draw_v1(
                self.renderer.as_ptr(),
                rect(2, 2, 24, 4),
                &desc,
                &mut self.scroll,
                &rows,
            )
        })?;
        check(unsafe {
            raw::tui_list_draw_v1(
                self.renderer.as_ptr(),
                rect(2, 7, 24, 4),
                &desc,
                &mut self.scroll,
                &rows,
            )
        })?;
        check(unsafe {
            raw::tui_tree_draw_v1(
                self.renderer.as_ptr(),
                rect(2, 12, 24, 5),
                &desc,
                &mut self.tree,
                &rows,
            )
        })?;
        check(unsafe {
            raw::tui_menu_draw_v1(
                self.renderer.as_ptr(),
                rect(2, 18, 24, 4),
                &desc,
                &mut self.menu,
                &rows,
            )
        })?;
        let columns = [
            raw::tui_column_v1 {
                title: utf8("component"),
                width: 14,
                reserved: 0,
            },
            raw::tui_column_v1 {
                title: utf8("state"),
                width: 11,
                reserved: 0,
            },
        ];
        check(unsafe {
            raw::tui_table_draw_v1(
                self.renderer.as_ptr(),
                rect(28, 2, 28, 7),
                &desc,
                &mut self.scroll,
                &rows,
                columns.as_ptr(),
                columns.len() as u32,
            )
        })?;
        check(unsafe {
            raw::tui_task_list_draw_v1(
                self.renderer.as_ptr(),
                rect(28, 10, 28, 6),
                &desc,
                &mut self.menu,
                &rows,
            )
        })?;
        let samples = raw::tui_samples_provider_v1 {
            context: ptr::null_mut(),
            count: CHART_SAMPLES.len() as u64,
            read: Some(read_samples),
        };
        check(unsafe {
            raw::tui_line_chart_draw_v1(
                self.chart.as_ptr(),
                self.renderer.as_ptr(),
                rect(58, 2, 20, 10),
                &samples,
                role(10, 0),
            )
        })?;
        let image = raw::tui_image_v1 {
            pixels: tui_zig::bytes(&IMAGE_PIXELS),
            width: 4,
            height: 4,
            format: raw::TUI_PIXELS_RGB8_V1,
        };
        let options = raw::tui_image_options_v1 {
            image_id: 7,
            placement_id: 1,
            background_red: 0,
            background_green: 0,
            background_blue: 0,
            reserved: 0,
        };
        check(unsafe {
            raw::tui_renderer_put_image_v1(
                self.renderer.as_ptr(),
                rect(58, 14, 4, 4),
                image,
                options,
            )
        })?;
        let diagnostics = text("parser + SPSC queue\nRGB image 4x4");
        check(unsafe {
            raw::tui_paragraph_draw_v1(self.renderer.as_ptr(), rect(64, 14, 14, 4), &diagnostics)
        })
    }

    fn dispatch(&mut self, event: &raw::tui_event_v1) -> tui_zig::Result<bool> {
        if event.kind == raw::TUI_EVENT_KEY_V1 && event.key_action != 2 {
            if event.key_kind == raw::TUI_KEY_ESCAPE_V1
                || (event.key_kind == raw::TUI_KEY_CODEPOINT_V1
                    && event.key_value == u32::from('q'))
            {
                return Ok(false);
            }
            if event.key_kind == raw::TUI_KEY_TAB_V1 {
                self.page ^= 1;
                return Ok(true);
            }
        }
        let mut rows_data = RowsData::new();
        let rows = rows_data.provider();
        let mut update = raw::TUI_UPDATE_IGNORED_V1;
        unsafe {
            check(raw::tui_button_handle_v1(
                &control("Activate", true),
                &mut self.button,
                event,
                &mut update,
            ))?;
            check(raw::tui_checkbox_handle_v1(
                &control("Checked", true),
                &mut self.checkbox,
                event,
                &mut update,
            ))?;
            check(raw::tui_radio_handle_v1(
                &control("Choice two", true),
                &mut self.radio,
                2,
                event,
                &mut update,
            ))?;
            check(raw::tui_text_input_handle_v1(
                self.input.as_ptr(),
                event,
                &mut update,
            ))?;
            check(raw::tui_text_area_handle_v1(
                self.area.as_ptr(),
                event,
                &mut update,
            ))?;
            check(raw::tui_scrollback_handle_v1(
                rect(2, 2, 24, 4),
                &mut self.scroll,
                &rows,
                event,
                &mut update,
            ))?;
            check(raw::tui_list_handle_v1(
                rect(2, 7, 24, 4),
                &mut self.scroll,
                &rows,
                event,
                &mut update,
            ))?;
            check(raw::tui_table_handle_v1(
                rect(28, 2, 28, 7),
                &mut self.scroll,
                &rows,
                event,
                &mut update,
            ))?;
            check(raw::tui_tree_handle_v1(
                rect(2, 12, 24, 5),
                &mut self.tree,
                &rows,
                event,
                &mut update,
            ))?;
            check(raw::tui_task_list_handle_v1(
                rect(28, 10, 28, 6),
                &mut self.menu,
                &rows,
                event,
                &mut update,
            ))?;
            check(raw::tui_menu_handle_v1(
                rect(2, 18, 24, 4),
                &mut self.menu,
                &rows,
                event,
                &mut update,
            ))?;
        }
        Ok(true)
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mode = std::env::args().nth(1);
    if mode
        .as_deref()
        .is_some_and(|value| value != "--headless" && value != "--headless-hash")
        || std::env::args().count() > 2
    {
        eprintln!("usage: showcase [--headless|--headless-hash]");
        std::process::exit(2);
    }
    let mut app = App::new()?;
    app.exercise()?;
    match mode.as_deref() {
        Some("--headless") => {
            let bytes = render_headless(&mut app)?;
            io::stdout().write_all(&bytes)?;
        }
        Some("--headless-hash") => {
            let bytes = render_headless(&mut app)?;
            println!("{:016x} {}", fnv1a(&bytes), bytes.len());
        }
        None => run_interactive(&mut app)?,
        _ => unreachable!(),
    }
    Ok(())
}

fn render_headless(app: &mut App) -> tui_zig::Result<Vec<u8>> {
    let mut output = Vec::with_capacity(8192);
    app.draw_frame(size(WIDTH, HEIGHT), &mut output)?;
    app.page = 1;
    unsafe { raw::tui_renderer_invalidate_terminal_v1(app.renderer.as_ptr()) };
    app.draw_frame(size(WIDTH, HEIGHT), &mut output)?;
    Ok(output)
}

fn run_interactive(app: &mut App) -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = Terminal::enter()?;
    loop {
        let mut output = Vec::with_capacity(4096);
        app.draw_frame(terminal.size(), &mut output)?;
        terminal.write(&output)?;
        let mut input = [0u8; 64];
        let count = terminal.read(&mut input)?;
        if count == 0 {
            return Ok(());
        }
        check(unsafe {
            raw::tui_parser_feed_v1(
                app.parser.as_ptr(),
                tui_zig::bytes(&input[..count]),
                app.queue.as_ptr(),
            )
        })?;
        let mut payload = [0u8; 256];
        loop {
            let mut event = zeroed();
            let result = unsafe {
                raw::tui_event_queue_try_pop_v1(
                    app.queue.as_ptr(),
                    payload.as_mut_ptr(),
                    payload.len() as u64,
                    &mut event,
                )
            };
            if result == raw::TUI_ERROR_QUEUE_EMPTY_V1 {
                break;
            }
            check(result)?;
            if !app.dispatch(&event)? {
                return Ok(());
            }
        }
    }
}

fn zeroed<T>() -> T {
    unsafe { std::mem::zeroed() }
}

fn size(width: u16, height: u16) -> raw::tui_size_v1 {
    raw::tui_size_v1 { width, height }
}

fn rect(x: u16, y: u16, width: u16, height: u16) -> raw::tui_rect_v1 {
    raw::tui_rect_v1 {
        x,
        y,
        width,
        height,
    }
}

fn color(kind: i32, index: u8, red: u8, green: u8, blue: u8) -> raw::tui_color_v1 {
    raw::tui_color_v1 {
        kind,
        index,
        red,
        green,
        blue,
        reserved: [0; 3],
    }
}

fn style(foreground: u8, background: u8, attributes: u8) -> raw::tui_style_v1 {
    raw::tui_style_v1 {
        foreground: color(raw::TUI_COLOR_INDEXED_V1, foreground, 0, 0, 0),
        background: color(raw::TUI_COLOR_INDEXED_V1, background, 0, 0, 0),
        attributes,
        reserved: [0; 3],
    }
}

fn role(foreground: u8, background: u8) -> raw::tui_role_v1 {
    raw::tui_role_v1 {
        normal: style(foreground, background, 0),
        focused: style(0, 14, 1),
        disabled: style(8, background, 0),
        has_focused: 1,
        has_disabled: 1,
        reserved: [0; 2],
    }
}

fn text(value: &str) -> raw::tui_text_desc_v1 {
    raw::tui_text_desc_v1 {
        text: utf8(value),
        role: role(15, 0),
        enabled: 1,
        focused: 0,
        width_profile: raw::TUI_WIDTH_NARROW_V1,
        alignment: raw::TUI_ALIGN_LEFT_V1,
    }
}

fn control(label: &str, focused: bool) -> raw::tui_control_desc_v1 {
    raw::tui_control_desc_v1 {
        label: utf8(label),
        role: role(15, 0),
        indicator_role: role(10, 0),
        enabled: 1,
        focused: u8::from(focused),
        reserved: [0; 2],
    }
}

fn collection() -> raw::tui_collection_desc_v1 {
    raw::tui_collection_desc_v1 {
        row_role: role(15, 0),
        selected_role: role(0, 14),
        header_role: role(11, 0),
        enabled: 1,
        focused: 1,
        width_profile: raw::TUI_WIDTH_NARROW_V1,
        reserved: 0,
    }
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(14_695_981_039_346_656_037, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(1_099_511_628_211)
    })
}

struct Terminal {
    original: libc::termios,
}

impl Terminal {
    fn enter() -> io::Result<Self> {
        if unsafe { libc::isatty(libc::STDIN_FILENO) } != 1
            || unsafe { libc::isatty(libc::STDOUT_FILENO) } != 1
        {
            return Err(io::Error::other("interactive mode requires a terminal"));
        }
        let mut original = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut raw = original;
        unsafe { libc::cfmakeraw(&mut raw) };
        raw.c_lflag |= libc::ISIG;
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &raw) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let terminal = Self { original };
        let mut output = io::stdout().lock();
        output.write_all(b"\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h")?;
        output.flush()?;
        Ok(terminal)
    }

    fn size(&self) -> raw::tui_size_v1 {
        let mut dimensions: libc::winsize = unsafe { std::mem::zeroed() };
        if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut dimensions) } == 0
            && dimensions.ws_col != 0
            && dimensions.ws_row != 0
        {
            size(dimensions.ws_col, dimensions.ws_row)
        } else {
            size(WIDTH, HEIGHT)
        }
    }

    fn write(&mut self, bytes: &[u8]) -> io::Result<()> {
        let mut output = io::stdout().lock();
        output.write_all(bytes)?;
        output.flush()
    }

    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        io::stdin().lock().read(bytes)
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &self.original) };
        let _ = io::stdout()
            .write_all(b"\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l");
        let _ = io::stdout().flush();
    }
}
