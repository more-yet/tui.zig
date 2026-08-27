package main

import (
	"errors"
	"fmt"
	"os"

	tui "github.com/more-yet/tui.zig/bindings/go"
	"golang.org/x/term"
)

const (
	width  = 80
	height = 24
)

var (
	chartSamples = []float64{1, 2.5, 1.5, 4, 3, 5.5, 4.5, 7, 6, 8, 7, 9}
	imagePixels  = []byte{
		230, 70, 80, 245, 155, 55, 55, 190, 145, 60, 135, 225,
		245, 155, 55, 55, 190, 145, 60, 135, 225, 230, 70, 80,
		55, 190, 145, 60, 135, 225, 230, 70, 80, 245, 155, 55,
		60, 135, 225, 230, 70, 80, 245, 155, 55, 55, 190, 145,
	}
)

type app struct {
	renderer *tui.Renderer
	input    *tui.TextInput
	area     *tui.TextArea
	chart    *tui.LineChart
	queue    *tui.EventQueue
	parser   *tui.Parser
	rows     *tui.RowsProvider
	samples  *tui.SamplesProvider
	output   tui.Output
	button   tui.ButtonState
	checkbox tui.CheckboxState
	radio    tui.RadioState
	scroll   tui.ScrollState
	menu     tui.MenuState
	tree     tui.TreeState
	page     uint8
}

func newApp() (application *app, err error) {
	version := tui.ABIVersion()
	if version.Major != 1 {
		return nil, fmt.Errorf("unsupported tui ABI %d.%d.%d", version.Major, version.Minor, version.Patch)
	}
	application = &app{}
	defer func() {
		if err != nil {
			application.close()
		}
	}()
	if application.renderer, err = tui.NewRenderer(tui.Size{Width: width, Height: height}); err != nil {
		return nil, err
	}
	if application.input, err = tui.NewTextInput(128, "edit me"); err != nil {
		return nil, err
	}
	if application.area, err = tui.NewTextArea(1024, "Unicode: e\u0301 and 世界\nSoft-wrapped editor"); err != nil {
		return nil, err
	}
	if application.chart, err = tui.NewLineChart(64, width*height); err != nil {
		return nil, err
	}
	if application.queue, err = tui.NewEventQueue(64); err != nil {
		return nil, err
	}
	if application.parser, err = tui.NewParser(); err != nil {
		return nil, err
	}
	application.rows, err = tui.NewRowsProvider([]tui.Row{
		{Text: "renderer", Cells: []string{"renderer", "ready"}, Flags: tui.RowHasChildren | tui.RowExpanded},
		{Text: "controls", Cells: []string{"controls", "checked"}, Depth: 1, Status: 1},
		{Text: "editors", Cells: []string{"editors", "editing"}, Depth: 1, Status: 2},
		{Text: "providers", Cells: []string{"providers", "streaming"}, Status: 3},
		{Text: "parser", Cells: []string{"parser", "bounded"}, Status: 4},
	})
	if err != nil {
		return nil, err
	}
	application.samples = tui.NewSamplesProvider(chartSamples)
	return application, nil
}

func (application *app) close() {
	application.output.Close()
	if application.samples != nil {
		application.samples.Close()
	}
	if application.rows != nil {
		application.rows.Close()
	}
	if application.parser != nil {
		application.parser.Close()
	}
	if application.queue != nil {
		application.queue.Close()
	}
	if application.chart != nil {
		application.chart.Close()
	}
	if application.area != nil {
		application.area.Close()
	}
	if application.input != nil {
		application.input.Close()
	}
	if application.renderer != nil {
		application.renderer.Close()
	}
}

func indexed(value uint8) tui.Color {
	return tui.Color{Kind: tui.ColorIndexed, Index: value}
}

func style(foreground, background, attributes uint8) tui.Style {
	return tui.Style{
		Foreground: indexed(foreground),
		Background: indexed(background),
		Attributes: attributes,
	}
}

func role(foreground, background uint8) tui.Role {
	return tui.Role{
		Normal:      style(foreground, background, 0),
		Focused:     style(0, 14, 1),
		Disabled:    style(8, background, 0),
		HasFocused:  true,
		HasDisabled: true,
	}
}

func text(value string) tui.TextDesc {
	return tui.TextDesc{
		Text:         value,
		Role:         role(15, 0),
		Enabled:      true,
		WidthProfile: tui.WidthNarrow,
		Alignment:    tui.AlignLeft,
	}
}

func control(value string) tui.ControlDesc {
	return tui.ControlDesc{
		Label:         value,
		Role:          role(15, 0),
		IndicatorRole: role(10, 0),
		Enabled:       true,
		Focused:       true,
	}
}

func collection() tui.CollectionDesc {
	return tui.CollectionDesc{
		RowRole:      role(15, 0),
		SelectedRole: role(0, 14),
		HeaderRole:   role(11, 0),
		Enabled:      true,
		Focused:      true,
		WidthProfile: tui.WidthNarrow,
	}
}

func rectangle(x, y, width, height uint16) tui.Rect {
	return tui.Rect{X: x, Y: y, Width: width, Height: height}
}

func (application *app) exercise() error {
	event := tui.Event{Kind: tui.EventKey, KeyKind: tui.KeyEnter, KeyAction: tui.KeyPress}
	if _, err := tui.HandleButton(control("Activate"), &application.button, event); err != nil {
		return err
	}
	if _, err := tui.HandleCheckbox(control("Checked"), &application.checkbox, event); err != nil {
		return err
	}
	if _, err := tui.HandleRadio(control("Choice two"), &application.radio, 2, event); err != nil {
		return err
	}
	event.KeyKind = tui.KeyDown
	if _, err := tui.HandleScrollback(rectangle(2, 2, 24, 4), &application.scroll, application.rows, event); err != nil {
		return err
	}
	if _, err := tui.HandleList(rectangle(2, 7, 24, 4), &application.scroll, application.rows, event); err != nil {
		return err
	}
	if _, err := tui.HandleTable(rectangle(28, 2, 28, 7), &application.scroll, application.rows, event); err != nil {
		return err
	}
	if _, err := tui.HandleTree(rectangle(2, 12, 24, 5), &application.tree, application.rows, event); err != nil {
		return err
	}
	if _, err := tui.HandleTaskList(rectangle(28, 10, 28, 6), &application.menu, application.rows, event); err != nil {
		return err
	}
	if _, err := tui.HandleMenu(rectangle(2, 18, 24, 4), &application.menu, application.rows, event); err != nil {
		return err
	}
	if err := application.input.SetFocus(true); err != nil {
		return err
	}
	if err := application.input.SetSelection(0, 4); err != nil {
		return err
	}
	if err := application.input.ReplaceSelection("type"); err != nil {
		return err
	}
	event.Kind, event.Payload = tui.EventText, []byte("!")
	if _, err := application.input.Handle(event); err != nil {
		return err
	}
	if _, err := application.input.Value(); err != nil {
		return err
	}
	if _, err := application.input.TakeFailure(); err != nil {
		return err
	}
	if err := application.area.SetFocus(true); err != nil {
		return err
	}
	if err := application.area.SetSoftWrap(true); err != nil {
		return err
	}
	if err := application.area.Layout(tui.Size{Width: 48, Height: 8}); err != nil {
		return err
	}
	if _, err := application.area.Handle(event); err != nil {
		return err
	}
	if _, err := application.area.Value(); err != nil {
		return err
	}
	if _, err := application.area.TakeFailure(); err != nil {
		return err
	}
	event.Payload = []byte("queued")
	if err := application.queue.TryPush(event); err != nil {
		return err
	}
	if _, err := application.queue.TryPop(); err != nil {
		return err
	}
	if err := application.parser.Feed([]byte("p"), application.queue); err != nil {
		return err
	}
	if _, err := application.queue.TryPop(); err != nil {
		return err
	}
	if err := application.parser.Finish(application.queue); err != nil {
		return err
	}
	if err := application.parser.Abort(application.queue); err != nil {
		return err
	}
	application.renderer.InvalidateTerminal()
	return nil
}

func (application *app) drawFrame(size tui.Size) ([]byte, error) {
	if err := application.renderer.Resize(size); err != nil {
		return nil, err
	}
	if err := application.renderer.BeginFrame(); err != nil {
		return nil, err
	}
	title := " tui.zig C ABI: controls "
	if application.page != 0 {
		title = " tui.zig C ABI: data "
	}
	bounds := rectangle(0, 0, size.Width, size.Height)
	if err := application.renderer.DrawPanel(bounds, tui.PanelDesc{
		Title: title, BorderRole: role(14, 0), TitleRole: role(11, 0), Enabled: true, Focused: true,
	}); err != nil {
		return nil, err
	}
	content, err := tui.PanelContentRect(bounds)
	if err != nil {
		return nil, err
	}
	if size.Width < width || size.Height < height {
		description := text("The showcase needs an 80x24 terminal.")
		description.Alignment = tui.AlignCenter
		err = application.renderer.DrawParagraph(content, description)
	} else if application.page == 0 {
		err = application.drawControls()
	} else {
		err = application.drawData()
	}
	if err != nil {
		return nil, err
	}
	application.output.Reset()
	_, err = application.renderer.Present(tui.Capabilities{
		ColorDepth: tui.ColorTruecolor, ImageProtocol: tui.ImageNone, SynchronizedOutput: true,
	}, &application.output)
	if err != nil {
		return nil, err
	}
	return application.output.Bytes()
}

func (application *app) drawControls() error {
	if err := application.renderer.DrawParagraph(
		rectangle(2, 2, 76, 2),
		text("All bindings call the same versioned C ABI. Tab changes page; q or Escape quits."),
	); err != nil {
		return err
	}
	if err := application.renderer.DrawLabel(rectangle(2, 5, 44, 1), text("Unicode 17: e\u0301  世界  🦀")); err != nil {
		return err
	}
	if err := application.renderer.DrawGauge(rectangle(2, 7, 44, 1), tui.GaugeDesc{
		Value: 73, Total: 100, FilledRole: role(0, 10), EmptyRole: role(8, 0), Enabled: true,
	}); err != nil {
		return err
	}
	if err := application.renderer.DrawButton(rectangle(2, 10, 18, 1), control("Activate"), &application.button); err != nil {
		return err
	}
	if err := application.renderer.DrawCheckbox(rectangle(2, 12, 18, 1), control("Checked"), &application.checkbox); err != nil {
		return err
	}
	if err := application.renderer.DrawRadio(rectangle(2, 14, 18, 1), control("Choice two"), &application.radio, 2); err != nil {
		return err
	}
	if err := application.input.Draw(application.renderer, rectangle(28, 10, 48, 1)); err != nil {
		return err
	}
	if err := application.area.Layout(tui.Size{Width: 48, Height: 8}); err != nil {
		return err
	}
	return application.area.Draw(application.renderer, rectangle(28, 13, 48, 8))
}

func (application *app) drawData() error {
	description := collection()
	if err := application.renderer.DrawScrollback(rectangle(2, 2, 24, 4), description, &application.scroll, application.rows); err != nil {
		return err
	}
	if err := application.renderer.DrawList(rectangle(2, 7, 24, 4), description, &application.scroll, application.rows); err != nil {
		return err
	}
	if err := application.renderer.DrawTree(rectangle(2, 12, 24, 5), description, &application.tree, application.rows); err != nil {
		return err
	}
	if err := application.renderer.DrawMenu(rectangle(2, 18, 24, 4), description, &application.menu, application.rows); err != nil {
		return err
	}
	if err := application.renderer.DrawTable(
		rectangle(28, 2, 28, 7), description, &application.scroll, application.rows,
		[]tui.Column{{Title: "component", Width: 14}, {Title: "state", Width: 11}},
	); err != nil {
		return err
	}
	if err := application.renderer.DrawTaskList(rectangle(28, 10, 28, 6), description, &application.menu, application.rows); err != nil {
		return err
	}
	if err := application.chart.Draw(application.renderer, rectangle(58, 2, 20, 10), application.samples, role(10, 0)); err != nil {
		return err
	}
	if err := application.renderer.PutImage(rectangle(58, 14, 4, 4), tui.Image{
		Pixels: imagePixels, Width: 4, Height: 4, Format: tui.PixelsRGB8,
	}, tui.ImageOptions{ImageID: 7, PlacementID: 1}); err != nil {
		return err
	}
	return application.renderer.DrawParagraph(rectangle(64, 14, 14, 4), text("parser + SPSC queue\nRGB image 4x4"))
}

func (application *app) dispatch(event tui.Event) (bool, error) {
	if event.Kind == tui.EventKey && event.KeyAction != tui.KeyRelease {
		if event.KeyKind == tui.KeyEscape || (event.KeyKind == tui.KeyCodepoint && event.KeyValue == 'q') {
			return false, nil
		}
		if event.KeyKind == tui.KeyTab {
			application.page ^= 1
			return true, nil
		}
	}
	if _, err := tui.HandleButton(control("Activate"), &application.button, event); err != nil {
		return false, err
	}
	if _, err := tui.HandleCheckbox(control("Checked"), &application.checkbox, event); err != nil {
		return false, err
	}
	if _, err := tui.HandleRadio(control("Choice two"), &application.radio, 2, event); err != nil {
		return false, err
	}
	if _, err := application.input.Handle(event); err != nil {
		return false, err
	}
	if _, err := application.area.Handle(event); err != nil {
		return false, err
	}
	if _, err := tui.HandleScrollback(rectangle(2, 2, 24, 4), &application.scroll, application.rows, event); err != nil {
		return false, err
	}
	if _, err := tui.HandleList(rectangle(2, 7, 24, 4), &application.scroll, application.rows, event); err != nil {
		return false, err
	}
	if _, err := tui.HandleTable(rectangle(28, 2, 28, 7), &application.scroll, application.rows, event); err != nil {
		return false, err
	}
	if _, err := tui.HandleTree(rectangle(2, 12, 24, 5), &application.tree, application.rows, event); err != nil {
		return false, err
	}
	if _, err := tui.HandleTaskList(rectangle(28, 10, 28, 6), &application.menu, application.rows, event); err != nil {
		return false, err
	}
	if _, err := tui.HandleMenu(rectangle(2, 18, 24, 4), &application.menu, application.rows, event); err != nil {
		return false, err
	}
	return true, nil
}

func renderHeadless(application *app) ([]byte, error) {
	first, err := application.drawFrame(tui.Size{Width: width, Height: height})
	if err != nil {
		return nil, err
	}
	output := append([]byte(nil), first...)
	application.page = 1
	application.renderer.InvalidateTerminal()
	second, err := application.drawFrame(tui.Size{Width: width, Height: height})
	if err != nil {
		return nil, err
	}
	return append(output, second...), nil
}

func fnv1a(input []byte) uint64 {
	hash := uint64(14_695_981_039_346_656_037)
	for _, value := range input {
		hash = (hash ^ uint64(value)) * 1_099_511_628_211
	}
	return hash
}

func runInteractive(application *app) error {
	inputFD, outputFD := int(os.Stdin.Fd()), int(os.Stdout.Fd())
	if !term.IsTerminal(inputFD) || !term.IsTerminal(outputFD) {
		return errors.New("interactive mode requires a terminal")
	}
	state, err := term.MakeRaw(inputFD)
	if err != nil {
		return err
	}
	defer func() {
		_ = term.Restore(inputFD, state)
		_, _ = os.Stdout.Write([]byte("\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l"))
	}()
	if _, err := os.Stdout.Write([]byte("\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h")); err != nil {
		return err
	}
	input := make([]byte, 64)
	for {
		columns, rows, err := term.GetSize(outputFD)
		if err != nil {
			columns, rows = width, height
		}
		frame, err := application.drawFrame(tui.Size{Width: uint16(columns), Height: uint16(rows)})
		if err != nil {
			return err
		}
		if _, err := os.Stdout.Write(frame); err != nil {
			return err
		}
		count, err := os.Stdin.Read(input)
		if err != nil {
			return err
		}
		if count == 0 {
			return nil
		}
		if err := application.parser.Feed(input[:count], application.queue); err != nil {
			return err
		}
		for {
			event, err := application.queue.TryPop()
			if tui.IsError(err, tui.ErrorQueueEmpty) {
				break
			}
			if err != nil {
				return err
			}
			keepRunning, err := application.dispatch(event)
			if err != nil {
				return err
			}
			if !keepRunning {
				return nil
			}
		}
	}
}

func run() error {
	arguments := os.Args[1:]
	if len(arguments) > 1 || (len(arguments) == 1 && arguments[0] != "--headless" && arguments[0] != "--headless-hash") {
		return errors.New("usage: showcase [--headless|--headless-hash]")
	}
	application, err := newApp()
	if err != nil {
		return err
	}
	defer application.close()
	if err := application.exercise(); err != nil {
		return err
	}
	if len(arguments) == 0 {
		return runInteractive(application)
	}
	output, err := renderHeadless(application)
	if err != nil {
		return err
	}
	if arguments[0] == "--headless-hash" {
		_, err = fmt.Printf("%016x %d\n", fnv1a(output), len(output))
		return err
	}
	_, err = os.Stdout.Write(output)
	return err
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
