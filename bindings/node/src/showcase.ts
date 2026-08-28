import binding, {
  type ButtonState, type CheckboxState, type CollectionDesc, type ControlDesc, type Event,
  type Handle, type MenuState, type RadioState, type Rect, type Role, type ScrollState,
  type Size, type Style, type TextDesc, type TreeState,
} from "../index.js";

const WIDTH = 80;
const HEIGHT = 24;
const EMPTY = Buffer.alloc(0);
const IMAGE_PIXELS = Buffer.from([
  230, 70, 80, 245, 155, 55, 55, 190, 145, 60, 135, 225,
  245, 155, 55, 55, 190, 145, 60, 135, 225, 230, 70, 80,
  55, 190, 145, 60, 135, 225, 230, 70, 80, 245, 155, 55,
  60, 135, 225, 230, 70, 80, 245, 155, 55, 55, 190, 145,
]);

function indexed(value: number) { return { kind: 1, index: value }; }
function style(foreground: number, background: number, attributes = 0): Style {
  return { foreground: indexed(foreground), background: indexed(background), attributes };
}
function role(foreground: number, background: number): Role {
  return {
    normal: style(foreground, background), focused: style(0, 14, 1), disabled: style(8, background),
    hasFocused: true, hasDisabled: true,
  };
}
function text(value: string): TextDesc {
  return { text: value, role: role(15, 0), enabled: true, focused: false, widthProfile: 0, alignment: 0 };
}
function control(label: string): ControlDesc {
  return { label, role: role(15, 0), indicatorRole: role(10, 0), enabled: true, focused: true };
}
function collection(): CollectionDesc {
  return { rowRole: role(15, 0), selectedRole: role(0, 14), headerRole: role(11, 0), enabled: true, focused: true, widthProfile: 0 };
}
function rect(x: number, y: number, width: number, height: number): Rect { return { x, y, width, height }; }
function event(): Event {
  return { kind: 0, keyKind: 0, keyValue: 0, modifiers: 0, keyAction: 0, mouseButton: 0, mouseAction: 0, x: 0, y: 0, replyKind: 0, replyFinal: 0, payload: EMPTY };
}

class App {
  readonly renderer: Handle;
  readonly input: Handle;
  readonly area: Handle;
  readonly chart: Handle;
  readonly queue: Handle;
  readonly parser: Handle;
  readonly rows: Handle;
  readonly samples: Handle;
  readonly button: ButtonState = { activated: false };
  readonly checkbox: CheckboxState = { checked: false };
  readonly radio: RadioState = { selected: 0, hasSelected: false };
  readonly scroll: ScrollState = { top: 0, selected: 0, hasSelected: false };
  readonly menu: MenuState = { scroll: { top: 0, selected: 0, hasSelected: false }, activated: 0, hasActivated: false };
  readonly tree: TreeState = { scroll: { top: 0, selected: 0, hasSelected: false }, toggled: 0, activated: 0, hasToggled: false, hasActivated: false };
  page = 0;

  constructor() {
    const version = binding.abiVersion();
    if (version.major !== 1) throw new Error(`unsupported tui ABI ${version.major}.${version.minor}.${version.patch}`);
    this.renderer = binding.rendererCreate({ width: WIDTH, height: HEIGHT });
    this.input = binding.textInputCreate(128, "edit me");
    this.area = binding.textAreaCreate(1024, "Unicode: e\u0301 and 世界\nSoft-wrapped editor");
    this.chart = binding.lineChartCreate(64, WIDTH * HEIGHT);
    this.queue = binding.eventQueueCreate(64);
    this.parser = binding.parserCreate();
    this.rows = binding.rowsProviderCreate([
      { text: "renderer", cells: ["renderer", "ready"], depth: 0, status: 0, flags: 3 },
      { text: "controls", cells: ["controls", "checked"], depth: 1, status: 1, flags: 0 },
      { text: "editors", cells: ["editors", "editing"], depth: 1, status: 2, flags: 0 },
      { text: "providers", cells: ["providers", "streaming"], depth: 0, status: 3, flags: 0 },
      { text: "parser", cells: ["parser", "bounded"], depth: 0, status: 4, flags: 0 },
    ]);
    this.samples = binding.samplesProviderCreate([1, 2.5, 1.5, 4, 3, 5.5, 4.5, 7, 6, 8, 7, 9]);
  }

  close() {
    binding.samplesProviderDestroy(this.samples); binding.rowsProviderDestroy(this.rows);
    binding.parserDestroy(this.parser); binding.eventQueueDestroy(this.queue); binding.lineChartDestroy(this.chart);
    binding.textAreaDestroy(this.area); binding.textInputDestroy(this.input); binding.rendererDestroy(this.renderer);
  }

  exercise() {
    const inputEvent = event(); inputEvent.kind = 1; inputEvent.keyKind = 3;
    binding.buttonHandle(control("Activate"), this.button, inputEvent);
    binding.checkboxHandle(control("Checked"), this.checkbox, inputEvent);
    binding.radioHandle(control("Choice two"), this.radio, 2, inputEvent);
    inputEvent.keyKind = 7;
    binding.scrollbackHandle(rect(2, 2, 24, 4), this.scroll, this.rows, inputEvent);
    binding.listHandle(rect(2, 7, 24, 4), this.scroll, this.rows, inputEvent);
    binding.tableHandle(rect(28, 2, 28, 7), this.scroll, this.rows, inputEvent);
    binding.treeHandle(rect(2, 12, 24, 5), this.tree, this.rows, inputEvent);
    binding.taskListHandle(rect(28, 10, 28, 6), this.menu, this.rows, inputEvent);
    binding.menuHandle(rect(2, 18, 24, 4), this.menu, this.rows, inputEvent);
    binding.textInputSetFocus(this.input, true); binding.textInputSetSelection(this.input, 0, 4);
    binding.textInputReplaceSelection(this.input, "type"); inputEvent.kind = 2; inputEvent.payload = Buffer.from("!");
    binding.textInputHandle(this.input, inputEvent); binding.textInputCopyValue(this.input); binding.textInputTakeFailure(this.input);
    binding.textAreaSetFocus(this.area, true); binding.textAreaSetSoftWrap(this.area, true); binding.textAreaLayout(this.area, { width: 48, height: 8 });
    binding.textAreaHandle(this.area, inputEvent); binding.textAreaCopyValue(this.area); binding.textAreaTakeFailure(this.area);
    inputEvent.payload = Buffer.from("queued"); binding.eventQueueTryPush(this.queue, inputEvent); binding.eventQueueTryPop(this.queue);
    binding.parserFeed(this.parser, Buffer.from("p"), this.queue); binding.eventQueueTryPop(this.queue);
    binding.parserFinish(this.parser, this.queue); binding.parserAbort(this.parser, this.queue); binding.rendererInvalidateTerminal(this.renderer);
  }

  drawFrame(size: Size): Buffer {
    binding.rendererResize(this.renderer, size); binding.rendererBeginFrame(this.renderer);
    const bounds = rect(0, 0, size.width, size.height);
    binding.panelDraw(this.renderer, bounds, {
      title: this.page === 0 ? " tui.zig C ABI: controls " : " tui.zig C ABI: data ",
      borderRole: role(14, 0), titleRole: role(11, 0), enabled: true, focused: true,
    });
    const content = binding.panelContentRect(bounds);
    if (size.width < WIDTH || size.height < HEIGHT) {
      const description = text("The showcase needs an 80x24 terminal."); description.alignment = 1;
      binding.paragraphDraw(this.renderer, content, description);
    } else if (this.page === 0) this.drawControls(); else this.drawData();
    return binding.rendererPresent(this.renderer, { colorDepth: 2, imageProtocol: 0, synchronizedOutput: true, backgroundColorErase: false }).bytes;
  }

  drawControls() {
    binding.paragraphDraw(this.renderer, rect(2, 2, 76, 2), text("All bindings call the same versioned C ABI. Tab changes page; q or Escape quits."));
    binding.labelDraw(this.renderer, rect(2, 5, 44, 1), text("Unicode 17: e\u0301  世界  🦀"));
    binding.gaugeDraw(this.renderer, rect(2, 7, 44, 1), { value: 73, total: 100, filledRole: role(0, 10), emptyRole: role(8, 0), enabled: true });
    binding.buttonDraw(this.renderer, rect(2, 10, 18, 1), control("Activate"), this.button);
    binding.checkboxDraw(this.renderer, rect(2, 12, 18, 1), control("Checked"), this.checkbox);
    binding.radioDraw(this.renderer, rect(2, 14, 18, 1), control("Choice two"), this.radio, 2);
    binding.textInputDraw(this.input, this.renderer, rect(28, 10, 48, 1));
    binding.textAreaLayout(this.area, { width: 48, height: 8 }); binding.textAreaDraw(this.area, this.renderer, rect(28, 13, 48, 8));
  }

  drawData() {
    const desc = collection();
    binding.scrollbackDraw(this.renderer, rect(2, 2, 24, 4), desc, this.scroll, this.rows);
    binding.listDraw(this.renderer, rect(2, 7, 24, 4), desc, this.scroll, this.rows);
    binding.treeDraw(this.renderer, rect(2, 12, 24, 5), desc, this.tree, this.rows);
    binding.menuDraw(this.renderer, rect(2, 18, 24, 4), desc, this.menu, this.rows);
    binding.tableDraw(this.renderer, rect(28, 2, 28, 7), desc, this.scroll, this.rows, [{ title: "component", width: 14 }, { title: "state", width: 11 }]);
    binding.taskListDraw(this.renderer, rect(28, 10, 28, 6), desc, this.menu, this.rows);
    binding.lineChartDraw(this.chart, this.renderer, rect(58, 2, 20, 10), this.samples, role(10, 0));
    binding.rendererPutImage(this.renderer, rect(58, 14, 4, 4), { pixels: IMAGE_PIXELS, width: 4, height: 4, format: 0 }, { imageId: 7, placementId: 1 });
    binding.paragraphDraw(this.renderer, rect(64, 14, 14, 4), text("parser + SPSC queue\nRGB image 4x4"));
  }

  dispatch(inputEvent: Event): boolean {
    if (inputEvent.kind === 1 && inputEvent.keyAction !== 2) {
      if (inputEvent.keyKind === 2 || (inputEvent.keyKind === 0 && inputEvent.keyValue === 113)) return false;
      if (inputEvent.keyKind === 4) { this.page ^= 1; return true; }
    }
    binding.buttonHandle(control("Activate"), this.button, inputEvent); binding.checkboxHandle(control("Checked"), this.checkbox, inputEvent);
    binding.radioHandle(control("Choice two"), this.radio, 2, inputEvent); binding.textInputHandle(this.input, inputEvent); binding.textAreaHandle(this.area, inputEvent);
    binding.scrollbackHandle(rect(2, 2, 24, 4), this.scroll, this.rows, inputEvent); binding.listHandle(rect(2, 7, 24, 4), this.scroll, this.rows, inputEvent);
    binding.tableHandle(rect(28, 2, 28, 7), this.scroll, this.rows, inputEvent); binding.treeHandle(rect(2, 12, 24, 5), this.tree, this.rows, inputEvent);
    binding.taskListHandle(rect(28, 10, 28, 6), this.menu, this.rows, inputEvent); binding.menuHandle(rect(2, 18, 24, 4), this.menu, this.rows, inputEvent);
    return true;
  }
}

function renderHeadless(app: App): Buffer {
  const first = app.drawFrame({ width: WIDTH, height: HEIGHT }); app.page = 1; binding.rendererInvalidateTerminal(app.renderer);
  return Buffer.concat([first, app.drawFrame({ width: WIDTH, height: HEIGHT })]);
}
function fnv1a(value: Buffer): bigint {
  let hash = 14695981039346656037n;
  for (const byte of value) hash = ((hash ^ BigInt(byte)) * 1099511628211n) & 0xffffffffffffffffn;
  return hash;
}
async function interactive(app: App) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error("interactive mode requires a terminal");
  let rawMode = false;
  try {
    process.stdin.setRawMode(true); rawMode = true; process.stdin.resume(); process.stdout.write("\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h");
    process.stdout.write(app.drawFrame({ width: process.stdout.columns || WIDTH, height: process.stdout.rows || HEIGHT }));
    for await (const chunk of process.stdin) {
      const bytes = Buffer.from(chunk as Buffer);
      for (let offset = 0; offset < bytes.length; offset += 64) {
        binding.parserFeed(app.parser, bytes.subarray(offset, offset + 64), app.queue);
        while (true) {
          let inputEvent: Event;
          try { inputEvent = binding.eventQueueTryPop(app.queue); }
          catch (error) { if (String(error).includes("tui error -7")) break; throw error; }
          if (!app.dispatch(inputEvent)) return;
        }
      }
      process.stdout.write(app.drawFrame({ width: process.stdout.columns || WIDTH, height: process.stdout.rows || HEIGHT }));
    }
  } finally {
    if (rawMode) process.stdin.setRawMode(false);
    process.stdout.write("\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?25h\x1b[?1049l");
  }
}

const args = process.argv.slice(2);
if (args.length > 1 || (args.length === 1 && args[0] !== "--headless" && args[0] !== "--headless-hash")) throw new Error("usage: showcase [--headless|--headless-hash]");
const app = new App();
try {
  app.exercise();
  if (args.length === 0) await interactive(app);
  else {
    const output = renderHeadless(app);
    if (args[0] === "--headless-hash") process.stdout.write(`${fnv1a(output).toString(16).padStart(16, "0")} ${output.length}\n`);
    else process.stdout.write(output);
  }
} finally { app.close(); }
