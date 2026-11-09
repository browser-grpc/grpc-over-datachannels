/* tslint:disable */
/* eslint-disable */
/**
 * Serve the generated Echo service over the given JS transport.
 * Returns immediately; serving runs as a local task until the
 * transport closes.
 */
export function echo_server(transport: any): void;
/**
 * JSON snapshot of the matrix recorder's spans.
 */
export function echo_tracing_spans(): string;
/**
 * Run the generated Echo client over the given JS transport and
 * resolve with a JSON summary (same shape the Go WASM facade and
 * the JS client produce, so one Node test can assert all three).
 */
export function echo_client(transport: any): Promise<string>;
/**
 * One unary call over the JS transport with the recorder
 * registered; resolves with the response plus recorded spans.
 */
export function echo_client_tracing(transport: any): Promise<string>;
/**
 * Serve Echo over the JS transport with the matrix recorder
 * registered (spans readable via echo_tracing_spans).
 */
export function echo_server_tracing(transport: any): void;
/**
 * Run the nested tracing scenario and resolve with its JSON.
 */
export function echo_tracing(): Promise<string>;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
  readonly memory: WebAssembly.Memory;
  readonly echo_client: (a: any) => any;
  readonly echo_client_tracing: (a: any) => any;
  readonly echo_server: (a: any) => void;
  readonly echo_server_tracing: (a: any) => void;
  readonly echo_tracing: () => any;
  readonly echo_tracing_spans: () => [number, number];
  readonly __wbindgen_exn_store: (a: number) => void;
  readonly __externref_table_alloc: () => number;
  readonly __wbindgen_export_2: WebAssembly.Table;
  readonly __wbindgen_export_3: WebAssembly.Table;
  readonly __wbindgen_free: (a: number, b: number, c: number) => void;
  readonly __wbindgen_malloc: (a: number, b: number) => number;
  readonly _dyn_core__ops__function__FnMut__A____Output___R_as_wasm_bindgen__closure__WasmClosure___describe__invoke__hcd7e876055dfa8b3: (a: number, b: number, c: number, d: number) => void;
  readonly _dyn_core__ops__function__FnMut_____Output___R_as_wasm_bindgen__closure__WasmClosure___describe__invoke__h374acee18d084f07: (a: number, b: number) => void;
  readonly closure199_externref_shim: (a: number, b: number, c: any) => void;
  readonly closure221_externref_shim: (a: number, b: number, c: any, d: any) => void;
  readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;
/**
* Instantiates the given `module`, which can either be bytes or
* a precompiled `WebAssembly.Module`.
*
* @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
*
* @returns {InitOutput}
*/
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
* If `module_or_path` is {RequestInfo} or {URL}, makes a request and
* for everything else, calls `WebAssembly.instantiate` directly.
*
* @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
*
* @returns {Promise<InitOutput>}
*/
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
