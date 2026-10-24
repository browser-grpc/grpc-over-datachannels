// TypeScript declarations for the grpc-dc JavaScript runtime.
// Hand-written against js/index.js + js/src/*; generated stubs
// (echo_*_grpc_dc.js etc.) are plain JS and can be wrapped with
// typed facades using the Channel generics below.

export type Metadata = Record<string, string>;

export interface CallOptions {
  metadata?: Metadata;
  timeout?: number;
}

export interface MessageType<T> {
  encode(message: T): Uint8Array;
  decode(bytes: Uint8Array): T;
}

export declare const FrameType: Record<string, number>;
export declare const StatusCode: Record<string, number>;
export declare const StatusName: Record<number, string>;

export declare class StatusError extends Error {
  code: number;
  constructor(code: number, message?: string);
  static ok(): StatusError;
  static unimplemented(message: string): StatusError;
  static internal(message: string): StatusError;
  static unavailable(message: string): StatusError;
  static invalidArgument(message: string): StatusError;
}

export declare function encodeFrame(
  type: number, streamId: number, payload?: Uint8Array): Uint8Array;
export declare function decodeFrame(
  data: Uint8Array | ArrayBuffer): { type: number; streamId: number; payload: Uint8Array };
export declare function encodeTimeout(timeoutMs: number): string;
export declare function parseTimeout(text: string): number | null;
export declare function setTracer(tracer: unknown): void;
export declare function setTraceFilter(patterns: unknown): void;
export declare function toHex(bytes: Uint8Array): string;
export declare function fromHex(hex: string): Uint8Array;

export type DataChannelLike = {
  send(data: unknown): void;
  addEventListener?: (type: string, listener: (event: unknown) => void) => void;
  binaryType?: string;
  readyState?: string;
  bufferedAmount?: number;
};

export declare class StreamInput<T = unknown> {
  push(item: T): void;
  end(): void;
  fail(error: unknown): void;
}

export declare class Endpoint {
  dispatcher: unknown;
  constructor(dc: DataChannelLike, options?: { parity?: "odd" | "even" });
  openStream(): StreamInput;
  closeStream(id: number): void;
  sendFrame(frameBytes: Uint8Array): Promise<void>;
  closeAll(): void;
}

export declare class Channel {
  readonly endpoint: Endpoint;
  constructor(dcOrEndpoint: DataChannelLike | Endpoint,
              options?: { parity?: "odd" | "even" });
  unary<Req, Res>(path: string, request: Req,
                  reqType: MessageType<Req>, resType: MessageType<Res>,
                  options?: CallOptions): Promise<Res>;
  serverStream<Req, Res>(path: string, request: Req,
                         reqType: MessageType<Req>, resType: MessageType<Res>,
                         options?: CallOptions): Promise<AsyncIterable<Res>>;
  clientStream<Req, Res>(path: string, requests: AsyncIterable<Req>,
                         reqType: MessageType<Req>, resType: MessageType<Res>,
                         options?: CallOptions): Promise<Res>;
  bidi<Req, Res>(path: string, requests: AsyncIterable<Req>,
                 reqType: MessageType<Req>, resType: MessageType<Res>,
                 options?: CallOptions): AsyncIterable<Res>;
  cancel(streamId: number): Promise<void>;
}

export interface MethodDef {
  path: string;
  kind: "unary" | "server-streaming" | "client-streaming" | "bidi";
  requestType: MessageType<unknown>;
  responseType: MessageType<unknown>;
  handler: (...args: never[]) => unknown;
}

export interface ServiceDef {
  name: string;
  methods: Record<string, MethodDef>;
}

export interface CallContext {
  path: string;
  metadata: Metadata;
  streamId: number;
  deadline: number | null;
}

export declare class Server {
  addService(definition: ServiceDef): void;
  serve(dcOrEndpoint: DataChannelLike | Endpoint,
        options?: { parity?: "odd" | "even" }): void;
}

export declare function memoryDataChannelPair(): [DataChannelLike, DataChannelLike];

export declare function createPeer(
  dc: DataChannelLike,
  options?: { parity?: "odd" | "even" },
): { endpoint: Endpoint; server: Server; channel: Channel };

export declare class GenericMessage {
  constructor(model?: unknown);
  set(number: number, value: unknown): void;
  add(number: number, value: unknown): void;
  getAll(number: number): unknown[];
  get(number: number, fallback?: unknown): unknown;
  getString(number: number, fallback?: string): string;
  getInt(number: number, fallback?: number): number;
}

export interface FileModel {
  services: Map<string, unknown>;
  messages: Map<string, unknown>;
  enums: Map<string, unknown>;
  fileName: string;
  packageName: string;
}

export declare function parseDescriptorSet(data: Uint8Array): FileModel;
export declare function createDynamicService(
  fileModel: FileModel, serviceName: string,
  handler: Record<string, (...args: never[]) => unknown>): ServiceDef;

export declare class DynamicClient {
  constructor(channel: Channel, fileModel: FileModel);
  unary(serviceName: string, methodName: string, request: GenericMessage,
        options?: CallOptions): Promise<GenericMessage>;
  serverStream(serviceName: string, methodName: string, request: GenericMessage,
               options?: CallOptions): Promise<AsyncIterable<GenericMessage>>;
  clientStream(serviceName: string, methodName: string,
               requests: AsyncIterable<GenericMessage>,
               options?: CallOptions): Promise<GenericMessage>;
  bidi(serviceName: string, methodName: string,
       requests: AsyncIterable<GenericMessage>,
       options?: CallOptions): AsyncIterable<GenericMessage>;
}

export interface GrpcDcBridge {
  unary(path: string, payload: Uint8Array,
        options?: CallOptions): Promise<Uint8Array>;
  serverStream(path: string, payload: Uint8Array,
               onMessage: (message: Uint8Array) => void,
               options?: CallOptions): Promise<void>;
  clientStream(path: string, payloads: Uint8Array[] | AsyncIterable<Uint8Array>,
               options?: CallOptions): Promise<Uint8Array>;
  bidi(path: string, payloads: Uint8Array[] | AsyncIterable<Uint8Array>,
       onMessage: (message: Uint8Array) => void,
       options?: CallOptions): Promise<void>;
}

export declare function createGrpcDcBridge(
  dcOrChannel: DataChannelLike | Channel): GrpcDcBridge;

export interface GrpcDcServerBridge {
  registerUnary(path: string,
    handler: (payload: Uint8Array, metadata: [string, string][]) => Promise<Uint8Array> | Uint8Array): void;
  registerServerStream(path: string,
    handler: (payload: Uint8Array, metadata: [string, string][],
              onMessage: (message: Uint8Array) => void) => unknown): void;
  registerClientStream(path: string,
    handler: (payloads: Uint8Array[], metadata: [string, string][]) => Promise<Uint8Array> | Uint8Array): void;
  registerBidi(path: string,
    handler: (payloads: Uint8Array[], metadata: [string, string][],
              onMessage: (message: Uint8Array) => void) => unknown): void;
  registerClientStreamInc(path: string,
    handler: (source: { next(): Promise<Uint8Array | null> },
              metadata: [string, string][]) => Promise<Uint8Array> | Uint8Array): void;
  registerBidiInc(path: string,
    handler: (source: { next(): Promise<Uint8Array | null> },
              metadata: [string, string][],
              onMessage: (message: Uint8Array) => void) => unknown): void;
  start(serviceName?: string): void;
}

export declare function createGrpcDcServerBridge(
  dcOrChannel: DataChannelLike | Channel): GrpcDcServerBridge;
