export type Handle = object;
export interface Size { width: number; height: number }
export interface Rect { x: number; y: number; width: number; height: number }
export interface Color { kind: number; index?: number; red?: number; green?: number; blue?: number }
export interface Style { foreground: Color; background: Color; attributes: number }
export interface Role { normal: Style; focused: Style; disabled: Style; hasFocused: boolean; hasDisabled: boolean }
export interface Event {
  kind: number; keyKind: number; keyValue: number; modifiers: number; keyAction: number;
  mouseButton: number; mouseAction: number; x: number; y: number; replyKind: number;
  replyFinal: number; payload: Buffer;
}
export interface TextDesc { text: string; role: Role; enabled: boolean; focused: boolean; widthProfile: number; alignment: number }
export interface PanelDesc { title: string; borderRole: Role; titleRole: Role; enabled: boolean; focused: boolean }
export interface GaugeDesc { value: number; total: number; filledRole: Role; emptyRole: Role; enabled: boolean }
export interface ControlDesc { label: string; role: Role; indicatorRole: Role; enabled: boolean; focused: boolean }
export interface ButtonState { activated: boolean }
export interface CheckboxState { checked: boolean }
export interface RadioState { selected: number; hasSelected: boolean }
export interface ScrollState { top: number; selected: number; hasSelected: boolean }
export interface MenuState { scroll: ScrollState; activated: number; hasActivated: boolean }
export interface TreeState { scroll: ScrollState; toggled: number; activated: number; hasToggled: boolean; hasActivated: boolean }
export interface CollectionDesc { rowRole: Role; selectedRole: Role; headerRole: Role; enabled: boolean; focused: boolean; widthProfile: number }
export interface Row { text: string; cells: string[]; depth: number; status: number; flags: number }
export interface Column { title: string; width: number }
export interface Image { pixels: Buffer; width: number; height: number; format: number }
export interface ImageOptions { imageId: number; placementId: number; backgroundRed?: number; backgroundGreen?: number; backgroundBlue?: number }
export interface Capabilities { colorDepth: number; imageProtocol: number; synchronizedOutput: boolean; backgroundColorErase: boolean }
export interface PresentResult { bytes: Buffer; stats: { bytes: number; cellsCompared: number; cellsChanged: number; runs: number; dirtyRows: number; fullRepaint: boolean } }

export interface NativeBinding {
  abiVersion(): { major: number; minor: number; patch: number };
  rendererCreate(size: Size): Handle; rendererDestroy(value: Handle): void; rendererResize(value: Handle, size: Size): void;
  rendererBeginFrame(value: Handle): void; rendererInvalidateTerminal(value: Handle): void;
  rendererPutImage(value: Handle, bounds: Rect, image: Image, options: ImageOptions): void;
  rendererPresent(value: Handle, capabilities: Capabilities): PresentResult;
  labelDraw(renderer: Handle, bounds: Rect, desc: TextDesc): void; paragraphDraw(renderer: Handle, bounds: Rect, desc: TextDesc): void;
  panelDraw(renderer: Handle, bounds: Rect, desc: PanelDesc): void; panelContentRect(bounds: Rect): Rect;
  gaugeDraw(renderer: Handle, bounds: Rect, desc: GaugeDesc): void;
  buttonDraw(renderer: Handle, bounds: Rect, desc: ControlDesc, state: ButtonState): void; buttonHandle(desc: ControlDesc, state: ButtonState, event: Event): number;
  checkboxDraw(renderer: Handle, bounds: Rect, desc: ControlDesc, state: CheckboxState): void; checkboxHandle(desc: ControlDesc, state: CheckboxState, event: Event): number;
  radioDraw(renderer: Handle, bounds: Rect, desc: ControlDesc, state: RadioState, value: number): void; radioHandle(desc: ControlDesc, state: RadioState, value: number, event: Event): number;
  textInputCreate(capacity: number, initial: string): Handle; textInputDestroy(value: Handle): void; textInputDraw(value: Handle, renderer: Handle, bounds: Rect): void;
  textInputHandle(value: Handle, event: Event): number; textInputSetFocus(value: Handle, focused: boolean): void;
  textInputSetSelection(value: Handle, anchor: number, cursor: number): void; textInputReplaceSelection(value: Handle, text: string): void;
  textInputCopyValue(value: Handle): Buffer; textInputTakeFailure(value: Handle): number;
  textAreaCreate(capacity: number, initial: string): Handle; textAreaDestroy(value: Handle): void; textAreaLayout(value: Handle, size: Size): void;
  textAreaDraw(value: Handle, renderer: Handle, bounds: Rect): void; textAreaHandle(value: Handle, event: Event): number;
  textAreaSetFocus(value: Handle, focused: boolean): void; textAreaSetSoftWrap(value: Handle, enabled: boolean): void;
  textAreaCopyValue(value: Handle): Buffer; textAreaTakeFailure(value: Handle): number;
  scrollbackDraw(renderer: Handle, bounds: Rect, desc: CollectionDesc, state: ScrollState, provider: Handle): void;
  scrollbackHandle(bounds: Rect, state: ScrollState, provider: Handle, event: Event): number;
  listDraw(renderer: Handle, bounds: Rect, desc: CollectionDesc, state: ScrollState, provider: Handle): void;
  listHandle(bounds: Rect, state: ScrollState, provider: Handle, event: Event): number;
  tableDraw(renderer: Handle, bounds: Rect, desc: CollectionDesc, state: ScrollState, provider: Handle, columns: Column[]): void;
  tableHandle(bounds: Rect, state: ScrollState, provider: Handle, event: Event): number;
  treeDraw(renderer: Handle, bounds: Rect, desc: CollectionDesc, state: TreeState, provider: Handle): void;
  treeHandle(bounds: Rect, state: TreeState, provider: Handle, event: Event): number;
  taskListDraw(renderer: Handle, bounds: Rect, desc: CollectionDesc, state: MenuState, provider: Handle): void;
  taskListHandle(bounds: Rect, state: MenuState, provider: Handle, event: Event): number;
  menuDraw(renderer: Handle, bounds: Rect, desc: CollectionDesc, state: MenuState, provider: Handle): void;
  menuHandle(bounds: Rect, state: MenuState, provider: Handle, event: Event): number;
  lineChartCreate(sampleCapacity: number, cellCapacity: number): Handle; lineChartDestroy(value: Handle): void;
  lineChartDraw(value: Handle, renderer: Handle, bounds: Rect, provider: Handle, role: Role): void;
  eventQueueCreate(capacity: number): Handle; eventQueueDestroy(value: Handle): void; eventQueueTryPush(value: Handle, event: Event): void; eventQueueTryPop(value: Handle): Event;
  parserCreate(): Handle; parserDestroy(value: Handle): void; parserFeed(value: Handle, input: Buffer, queue: Handle): void; parserFinish(value: Handle, queue: Handle): void; parserAbort(value: Handle, queue: Handle): void;
  rowsProviderCreate(rows: Row[]): Handle; rowsProviderDestroy(value: Handle): void;
  samplesProviderCreate(samples: number[]): Handle; samplesProviderDestroy(value: Handle): void;
}

declare const binding: NativeBinding;
export default binding;
