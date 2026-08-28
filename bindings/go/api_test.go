package tui

import "testing"

func TestVersionAndOwnedHandles(t *testing.T) {
	if version := ABIVersion(); version != (Version{Major: 1, Minor: 0, Patch: 0}) {
		t.Fatalf("unexpected ABI version: %+v", version)
	}
	renderer, err := NewRenderer(Size{Width: 8, Height: 2})
	if err != nil {
		t.Fatal(err)
	}
	input, err := NewTextInput(32, "ready")
	if err != nil {
		t.Fatal(err)
	}
	area, err := NewTextArea(64, "one\ntwo")
	if err != nil {
		t.Fatal(err)
	}
	chart, err := NewLineChart(8, 8)
	if err != nil {
		t.Fatal(err)
	}
	queue, err := NewEventQueue(4)
	if err != nil {
		t.Fatal(err)
	}
	parser, err := NewParser()
	if err != nil {
		t.Fatal(err)
	}
	parser.Close()
	queue.Close()
	chart.Close()
	area.Close()
	input.Close()
	renderer.Close()
	parser.Close()
	queue.Close()
}
