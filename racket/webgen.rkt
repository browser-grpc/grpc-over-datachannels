#lang racket

;;; webgen.rkt — emits webapp/gen/generators.js, the browser
;;; generators for the fully client-side web app.
;;;
;;; The native protoc plugins cannot run in a browser (they are
;;; Racket programs fed CodeGeneratorRequest bytes by protoc), so
;;; metagen also stamps the same generation logic into a
;;; self-contained ES module: given FileDescriptorSet bytes from
;;; the in-page protocompile WASM compiler, it emits exactly the
;;; files protoc-gen-grpc-dc-{js,go,python} would. The descriptor
;;; walk mirrors desc.rkt and the emitters mirror
;;; template-{js,go,python}.rkt; byte parity with the native
;;; plugins is enforced by the webapp parity test. The method
;;; rename-alias table is serialized from spec.rkt below, so the
;;; browser generators can never disagree with the plugins about
;;; aliases.

(require "spec.rkt" json)

(provide emit-web-generators)

(define (alias-table-json)
  (jsexpr->string
   (map (lambda (a)
          (map (lambda (x) (if (symbol? x) (symbol->string x) x)) a))
        method-alias-table)))

(define js-part-1 #<<JS
// Browser generators for the grpc-dc web app: given the
// FileDescriptorSet bytes produced by the in-page protocompile
// WASM compiler (webapp/compiler), emit the same stub files the
// native protoc-gen-grpc-dc-{js,go,python} plugins emit. The
// descriptor walk mirrors racket/desc.rkt and the emitters
// mirror racket/template-{js,go,python}.rkt; byte parity with
// the native plugins is enforced by the webapp parity test
// (browser-test/webapp_parity.test.mjs). Do not hand-edit here:
// change the Racket templates and regenerate.

const METHOD_ALIASES = 
JS
)

(define js-part-2 #<<JS
;

// ---------------------------------------------------------------------------
// Minimal protobuf reader for descriptor.proto (field-number keyed).
// ---------------------------------------------------------------------------

function pbParse(bytes) {
  const fields = new Map();
  let i = 0;
  const readVarint = () => {
    let v = 0n;
    let shift = 0n;
    for (;;) {
      const b = bytes[i++];
      v |= BigInt(b & 0x7f) << shift;
      if (!(b & 0x80)) break;
      shift += 7n;
    }
    return v;
  };
  while (i < bytes.length) {
    const tag = readVarint();
    const num = Number(tag >> 3n);
    const wire = Number(tag & 7n);
    let entry;
    if (wire === 0) entry = { wire, varint: readVarint() };
    else if (wire === 2) {
      const len = Number(readVarint());
      entry = { wire, bytes: bytes.subarray(i, i + len) };
      i += len;
    } else if (wire === 1) { entry = { wire, bytes: bytes.subarray(i, i + 8) }; i += 8; }
    else if (wire === 5) { entry = { wire, bytes: bytes.subarray(i, i + 4) }; i += 4; }
    else throw new Error('unsupported wire type ' + wire);
    if (!fields.has(num)) fields.set(num, []);
    fields.get(num).push(entry);
  }
  return fields;
}

function getAllBytes(fields, num) {
  return (fields.get(num) || []).filter((e) => e.wire === 2).map((e) => e.bytes);
}

function firstBytes(fields, num) {
  const all = getAllBytes(fields, num);
  return all.length ? all[0] : null;
}

const utf8 = new TextDecoder();

function getString(fields, num, dflt) {
  const raw = firstBytes(fields, num);
  return raw === null ? (dflt || '') : utf8.decode(raw);
}

function getBool(fields, num) {
  const all = fields.get(num) || [];
  return all.some((e) => e.wire === 0 && e.varint !== 0n);
}

// ---------------------------------------------------------------------------
// Descriptor model (mirrors racket/desc.rkt).
// ---------------------------------------------------------------------------

function simpleTypeName(full) {
  const parts = full.replace(/^\.+|\.+$/g, '').split('.');
  return parts[parts.length - 1];
}

function methodPath(pkg, service, method) {
  return pkg ? '/' + pkg + '.' + service + '/' + method : '/' + service + '/' + method;
}

function streamingKind(client, server) {
  return client && server ? 'bidi' : client ? 'client-streaming' : server ? 'server-streaming' : 'unary';
}

function optionsDeprecated(fields, optionsField) {
  const raw = firstBytes(fields, optionsField);
  return raw !== null && getBool(pbParse(raw), 33);
}

function parseMethod(fields, pkg, serviceName) {
  const name = getString(fields, 1);
  const client = getBool(fields, 5);
  const server = getBool(fields, 6);
  return {
    name,
    path: methodPath(pkg, serviceName, name),
    input: simpleTypeName(getString(fields, 2)),
    output: simpleTypeName(getString(fields, 3)),
    kind: streamingKind(client, server),
    clientStreaming: client,
    serverStreaming: server,
    deprecated: optionsDeprecated(fields, 4),
    implName: name,
  };
}

function parseService(fields, pkg) {
  const name = getString(fields, 1);
  return {
    name,
    fullName: pkg ? pkg + '.' + name : name,
    methods: getAllBytes(fields, 2).map((m) => parseMethod(pbParse(m), pkg, name)),
  };
}

function parseFileDesc(fields) {
  const pkg = getString(fields, 2, '');
  return {
    name: getString(fields, 1),
    package: pkg,
    services: getAllBytes(fields, 6).map((s) => parseService(pbParse(s), pkg)),
  };
}

function buildModel(setBytes, entries) {
  const byName = new Map();
  for (const raw of getAllBytes(pbParse(setBytes), 1)) {
    const f = parseFileDesc(pbParse(raw));
    byName.set(f.name, f);
  }
  return entries.map((e) => {
    const f = byName.get(e);
    if (!f) throw new Error('file not in descriptor set: ' + e);
    return f;
  });
}

function aliasesFor(fullName) {
  return METHOD_ALIASES.filter((a) => a[0] === fullName);
}

function aliasClientMethods(svc) {
  const out = [];
  for (const a of aliasesFor(svc.fullName)) {
    const target = svc.methods.find((m) => m.name === a[2]);
    if (target) out.push({ ...target, name: a[1] });
  }
  return out;
}

function aliasServerMethods(svc) {
  const out = [];
  for (const a of aliasesFor(svc.fullName)) {
    const target = svc.methods.find((m) => m.name === a[2]);
    if (target) out.push({ ...target, name: a[1], path: '/' + svc.fullName + '/' + a[1], implName: target.name });
  }
  return out;
}

const q = (s) => JSON.stringify(s);

function lowerFirst(s) {
  return s ? s[0].toLowerCase() + s.slice(1) : s;
}

function baseName(name) {
  const b = name.split('/').pop();
  const i = b.lastIndexOf('.');
  return i > 0 ? b.slice(0, i) : b;
}

function parseParams(parameter) {
  const params = {};
  if (!parameter) return params;
  for (const part of parameter.split(/[,:]/)) {
    const i = part.indexOf('=');
    if (i >= 0) params[part.slice(0, i)] = part.slice(i + 1);
  }
  return params;
}

JS
)

(define js-part-3 #<<JS
// ---------------------------------------------------------------------------
// JS emitter (mirrors racket/template-js.rkt).
// ---------------------------------------------------------------------------

function jsDeprecated(m, indent) {
  return m.deprecated ? indent + '/** @deprecated deprecated in the proto schema */\n' : '';
}

function jsClientMethod(m) {
  const fn = lowerFirst(m.name);
  const depr = jsDeprecated(m, '  ');
  switch (m.kind) {
    case 'unary':
      return depr + '  async ' + fn + '(request, options) {\n    return this.#channel.unary(' + q(m.path) + ', request, ' + m.input + ', ' + m.output + ', options);\n  }\n';
    case 'server-streaming':
      return depr + '  ' + fn + '(request, options) {\n    return this.#channel.serverStream(' + q(m.path) + ', request, ' + m.input + ', ' + m.output + ', options);\n  }\n';
    case 'client-streaming':
      return depr + '  async ' + fn + '(requests, options) {\n    return this.#channel.clientStream(' + q(m.path) + ', requests, ' + m.input + ', ' + m.output + ', options);\n  }\n';
    default:
      return depr + '  ' + fn + '(requests, options) {\n    return this.#channel.bidi(' + q(m.path) + ', requests, ' + m.input + ', ' + m.output + ', options);\n  }\n';
  }
}

function jsMethodTableEntry(m) {
  return '    ' + m.name + ': { path: ' + q(m.path) + ', kind: ' + q(m.kind) + ', requestType: ' + m.input + ', responseType: ' + m.output + ', handler: handlers.' + lowerFirst(m.implName) + ' },\n';
}

function jsService(svc) {
  return 'export class ' + svc.name + 'Client {\n  #channel;\n  constructor(channel) { this.#channel = channel; }\n'
    + svc.methods.concat(aliasClientMethods(svc)).map(jsClientMethod).join('')
    + '}\n\n'
    + 'export function create' + svc.name + 'Service(handlers) {\n  return {\n    name: ' + q(svc.fullName) + ',\n    methods: {\n'
    + svc.methods.concat(aliasServerMethods(svc)).map(jsMethodTableEntry).join('')
    + '    },\n  };\n}\n';
}

function emitJsFile(model, params) {
  const base = baseName(model.name);
  const pbImport = params.pb_import || './' + base + '_pb.js';
  const types = [];
  for (const s of model.services) {
    for (const m of s.methods) {
      for (const t of [m.input, m.output]) if (!types.includes(t)) types.push(t);
    }
  }
  return {
    name: base + '_grpc_dc.js',
    content: '// @generated by protoc-gen-grpc-dc-js (Racket metaprogram). DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + (types.length ? 'import { ' + types.join(', ') + ' } from ' + q(pbImport) + ';\n\n' : '')
      + model.services.map(jsService).join(''),
  };
}

// ---------------------------------------------------------------------------
// Go emitter (mirrors racket/template-go.rkt).
// ---------------------------------------------------------------------------

function goPackage(model, params) {
  if (params.go_package) return params.go_package;
  if (!model.package) return 'proto';
  const parts = model.package.split('.');
  return parts[parts.length - 1];
}

function goDeprecated(m) {
  return m.deprecated ? '// Deprecated: marked deprecated in the proto schema.\n' : '';
}

function goClientMethod(m, svc) {
  const name = m.name;
  const req = m.input;
  const resp = m.output;
  const path = q(m.path);
  switch (m.kind) {
    case 'unary':
      return 'func (c *' + svc + 'Client) ' + name + '(ctx context.Context, req *' + req + ') (*' + resp + ', error) {\n'
        + '\tresp := new(' + resp + ')\n'
        + '\tif err := c.Channel.Unary(ctx, ' + path + ', req, resp); err != nil {\n'
        + '\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n';
    case 'server-streaming':
      return 'func (c *' + svc + 'Client) ' + name + '(ctx context.Context, req *' + req + ') (*' + svc + name + 'Stream, error) {\n'
        + '\tstream, err := c.Channel.ServerStream(ctx, ' + path + ', req)\n'
        + '\tif err != nil {\n\t\treturn nil, err\n\t}\n'
        + '\treturn &' + svc + name + 'Stream{stream: stream}, nil\n}\n\n'
        + 'type ' + svc + name + 'Stream struct{ stream *grpcdc.ClientStream }\n\n'
        + 'func (s *' + svc + name + 'Stream) Recv() (*' + resp + ', error) {\n'
        + '\tresp := new(' + resp + ')\n'
        + '\tif err := s.stream.Recv(resp); err != nil {\n\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n';
    case 'client-streaming':
      return 'func (c *' + svc + 'Client) ' + name + '(ctx context.Context, reqs ...*' + req + ') (*' + resp + ', error) {\n'
        + '\tgrpcdcReqs := make([]grpcdc.Marshaler, len(reqs))\n'
        + '\tfor i, r := range reqs {\n\t\tgrpcdcReqs[i] = r\n\t}\n'
        + '\tresp := new(' + resp + ')\n'
        + '\tif err := c.Channel.ClientStreamCall(ctx, ' + path + ', grpcdcReqs, resp); err != nil {\n'
        + '\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n';
    default:
      return 'func (c *' + svc + 'Client) ' + name + '(ctx context.Context, reqs ...*' + req + ') (*' + svc + name + 'Stream, error) {\n'
        + '\tgrpcdcReqs := make([]grpcdc.Marshaler, len(reqs))\n'
        + '\tfor i, r := range reqs {\n\t\tgrpcdcReqs[i] = r\n\t}\n'
        + '\tstream, err := c.Channel.Bidi(ctx, ' + path + ', grpcdcReqs)\n'
        + '\tif err != nil {\n\t\treturn nil, err\n\t}\n'
        + '\treturn &' + svc + name + 'Stream{stream: stream}, nil\n}\n\n'
        + 'type ' + svc + name + 'Stream struct{ stream *grpcdc.ClientStream }\n\n'
        + 'func (s *' + svc + name + 'Stream) Recv() (*' + resp + ', error) {\n'
        + '\tresp := new(' + resp + ')\n'
        + '\tif err := s.stream.Recv(resp); err != nil {\n\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n';
  }
}

function goServerIfaceMethod(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '\t' + m.name + '(context.Context, *' + m.input + ') (*' + m.output + ', error)\n';
    case 'server-streaming':
      return '\t' + m.name + '(*' + m.input + ', ' + svc + m.name + 'Server) error\n';
    default:
      return '\t' + m.name + '(' + svc + m.name + 'Server) error\n';
  }
}

function goServerIfaceMethodDepr(m, svc) {
  return (m.deprecated ? '\t// Deprecated: marked deprecated in the proto schema.\n' : '') + goServerIfaceMethod(m, svc);
}

function goStreamIfaces(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '';
    case 'server-streaming':
      return 'type ' + svc + m.name + 'Server interface {\n\tSend(*' + m.output + ') error\n\tContext() context.Context\n}\n\n';
    case 'client-streaming':
      return 'type ' + svc + m.name + 'Server interface {\n\tRecv() (*' + m.input + ', error)\n\tSendAndClose(*' + m.output + ') error\n\tContext() context.Context\n}\n\n';
    default:
      return 'type ' + svc + m.name + 'Server interface {\n\tSend(*' + m.output + ') error\n\tRecv() (*' + m.input + ', error)\n\tContext() context.Context\n}\n\n';
  }
}

function goRegisterMethod(m, svc) {
  const impl = m.implName;
  const head = '\t\t{Name: ' + q(m.name) + ', Path: ' + q(m.path) + ', Kind: grpcdc.';
  switch (m.kind) {
    case 'unary':
      return head + 'KindUnary, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n'
        + '\t\t\treq := new(' + m.input + ')\n'
        + '\t\t\tif err := reqs.RecvInto(req); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n'
        + '\t\t\tresp, err := srv.' + impl + '(ctx, req)\n'
        + '\t\t\tif err != nil {\n\t\t\t\treturn err\n\t\t\t}\n'
        + '\t\t\treturn sink.Send(resp.MarshalDC())\n\t\t}},\n';
    case 'server-streaming':
      return head + 'KindServerStreaming, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n'
        + '\t\t\treq := new(' + m.input + ')\n'
        + '\t\t\tif err := reqs.RecvInto(req); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n'
        + '\t\t\treturn srv.' + impl + '(req, &' + svc + impl + 'ServerImpl{ctx: ctx, sink: sink})\n\t\t}},\n';
    case 'client-streaming':
      return head + 'KindClientStreaming, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n'
        + '\t\t\tstream := &' + svc + impl + 'ServerImpl{ctx: ctx, reqs: reqs}\n'
        + '\t\t\tif err := srv.' + impl + '(stream); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n'
        + '\t\t\tif stream.resp == nil {\n'
        + '\t\t\t\treturn grpcdc.NewStatus(grpcdc.CodeInternal, "client-streaming handler never called SendAndClose")\n\t\t\t}\n'
        + '\t\t\treturn sink.Send(stream.resp.MarshalDC())\n\t\t}},\n';
    default:
      return head + 'KindBidi, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n'
        + '\t\t\treturn srv.' + impl + '(&' + svc + impl + 'ServerImpl{ctx: ctx, reqs: reqs, sink: sink})\n\t\t}},\n';
  }
}

function goStreamImpls(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '';
    case 'server-streaming':
      return 'type ' + svc + m.name + 'ServerImpl struct {\n\tctx  context.Context\n\tsink grpcdc.ServerSink\n}\n\n'
        + 'func (s *' + svc + m.name + 'ServerImpl) Send(resp *' + m.output + ') error {\n\treturn s.sink.Send(resp.MarshalDC())\n}\n'
        + 'func (s *' + svc + m.name + 'ServerImpl) Context() context.Context { return s.ctx }\n\n';
    case 'client-streaming':
      return 'type ' + svc + m.name + 'ServerImpl struct {\n\tctx  context.Context\n\treqs *grpcdc.RequestStream\n\tresp *' + m.output + '\n}\n\n'
        + 'func (s *' + svc + m.name + 'ServerImpl) Recv() (*' + m.input + ', error) {\n'
        + '\treq := new(' + m.input + ')\n'
        + '\tif err := s.reqs.RecvInto(req); err != nil {\n\t\treturn nil, err\n\t}\n\treturn req, nil\n}\n'
        + 'func (s *' + svc + m.name + 'ServerImpl) SendAndClose(resp *' + m.output + ') error {\n\ts.resp = resp\n\treturn nil\n}\n'
        + 'func (s *' + svc + m.name + 'ServerImpl) Context() context.Context { return s.ctx }\n\n';
    default:
      return 'type ' + svc + m.name + 'ServerImpl struct {\n\tctx  context.Context\n\treqs *grpcdc.RequestStream\n\tsink grpcdc.ServerSink\n}\n\n'
        + 'func (s *' + svc + m.name + 'ServerImpl) Send(resp *' + m.output + ') error {\n\treturn s.sink.Send(resp.MarshalDC())\n}\n'
        + 'func (s *' + svc + m.name + 'ServerImpl) Recv() (*' + m.input + ', error) {\n'
        + '\treq := new(' + m.input + ')\n'
        + '\tif err := s.reqs.RecvInto(req); err != nil {\n\t\treturn nil, err\n\t}\n\treturn req, nil\n}\n'
        + 'func (s *' + svc + m.name + 'ServerImpl) Context() context.Context { return s.ctx }\n\n';
  }
}

function goService(svc) {
  const sname = svc.name;
  return 'type ' + sname + 'Client struct {\n\tChannel *grpcdc.Channel\n}\n\n'
    + 'func New' + sname + 'Client(ch *grpcdc.Channel) *' + sname + 'Client {\n\treturn &' + sname + 'Client{Channel: ch}\n}\n\n'
    + svc.methods.concat(aliasClientMethods(svc)).map((m) => goDeprecated(m) + goClientMethod(m, sname)).join('')
    + '\n'
    + 'type ' + sname + 'Server interface {\n'
    + svc.methods.map((m) => goServerIfaceMethodDepr(m, sname)).join('')
    + '}\n\n'
    + svc.methods.map((m) => goStreamIfaces(m, sname)).join('')
    + svc.methods.map((m) => goStreamImpls(m, sname)).join('')
    + 'func Register' + sname + 'Server(s *grpcdc.Server, srv ' + sname + 'Server) {\n'
    + '\ts.RegisterService(grpcdc.ServiceDesc{\n\t\tName: ' + q(svc.fullName) + ',\n\t\tMethods: []grpcdc.Method{\n'
    + svc.methods.concat(aliasServerMethods(svc)).map((m) => goRegisterMethod(m, sname)).join('')
    + '\t\t},\n\t})\n}\n';
}

function emitGoFile(model, params) {
  const base = baseName(model.name);
  return {
    name: base + '_grpc_dc.go',
    content: '// @generated by protoc-gen-grpc-dc-go (Racket metaprogram). DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + 'package ' + goPackage(model, params) + '\n\n'
      + 'import (\n\t"context"\n\n\tgrpcdc "grpcdc"\n)\n\n'
      + model.services.map(goService).join(''),
  };
}

JS
)

(define js-part-4 #<<JS
// ---------------------------------------------------------------------------
// Python emitter (mirrors racket/template-python.rkt).
// ---------------------------------------------------------------------------

function snake(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c >= 'A' && c <= 'Z') out += (i > 0 ? '_' : '') + c.toLowerCase();
    else out += c;
  }
  return out;
}

function pyDeprecated(m) {
  return m.deprecated
    ? '        """Deprecated: marked deprecated in the proto schema."""\n        import warnings as _warnings; _warnings.warn("deprecated", DeprecationWarning, stacklevel=2)\n'
    : '';
}

function pyClientMethod(pb, m) {
  const path = q(m.path);
  const depr = pyDeprecated(m);
  switch (m.kind) {
    case 'unary':
      return '    def ' + m.name + '(self, req, metadata=None, timeout=None):\n' + depr
        + '        return self._channel.unary(' + path + ', req, ' + pb + '.' + m.output + '(), metadata, timeout)\n\n';
    case 'server-streaming':
      return '    def ' + m.name + '(self, req, metadata=None, timeout=None):\n' + depr
        + '        stream = self._channel.server_stream(' + path + ', req, metadata, timeout)\n'
        + '        return _RecvStream(stream, ' + pb + '.' + m.output + ')\n\n';
    case 'client-streaming':
      return '    def ' + m.name + '(self, reqs, metadata=None, timeout=None):\n' + depr
        + '        return self._channel.client_stream(' + path + ', reqs, ' + pb + '.' + m.output + '(), metadata, timeout)\n\n';
    default:
      return '    def ' + m.name + '(self, reqs, metadata=None, timeout=None):\n' + depr
        + '        stream = self._channel.bidi(' + path + ', reqs, metadata, timeout)\n'
        + '        return _RecvStream(stream, ' + pb + '.' + m.output + ')\n\n';
  }
}

function pyAsyncClientMethod(pb, m) {
  const path = q(m.path);
  const depr = pyDeprecated(m);
  switch (m.kind) {
    case 'unary':
      return '    async def ' + m.name + '(self, req, metadata=None, timeout=None):\n' + depr
        + '        return await self._channel.unary(' + path + ', req, ' + pb + '.' + m.output + '(), metadata, timeout)\n\n';
    case 'server-streaming':
      return '    async def ' + m.name + '(self, req, metadata=None, timeout=None):\n' + depr
        + '        stream = await self._channel.server_stream(' + path + ', req, metadata, timeout)\n'
        + '        return _AsyncRecvStream(stream, ' + pb + '.' + m.output + ')\n\n';
    case 'client-streaming':
      return '    async def ' + m.name + '(self, reqs, metadata=None, timeout=None):\n' + depr
        + '        return await self._channel.client_stream(' + path + ', reqs, ' + pb + '.' + m.output + '(), metadata, timeout)\n\n';
    default:
      return '    async def ' + m.name + '(self, reqs, metadata=None, timeout=None):\n' + depr
        + '        stream = await self._channel.bidi(' + path + ', reqs, metadata, timeout)\n'
        + '        return _AsyncRecvStream(stream, ' + pb + '.' + m.output + ')\n\n';
  }
}

function pyServerHandler(pb, m) {
  const impl = m.implName;
  switch (m.kind) {
    case 'unary':
      return '    def _' + m.name + '_handler(ctx, reqs, sink):\n'
        + '        req = reqs.recv_into(' + pb + '.' + m.input + '())\n'
        + '        resp = impl.' + impl + '(ctx, req)\n'
        + '        sink.send(resp.marshal_dc())\n\n';
    case 'server-streaming':
      return '    def _' + m.name + '_handler(ctx, reqs, sink):\n'
        + '        req = reqs.recv_into(' + pb + '.' + m.input + '())\n'
        + '        impl.' + impl + '(req, _SendStream(ctx, sink))\n\n';
    case 'client-streaming':
      return '    def _' + m.name + '_handler(ctx, reqs, sink):\n'
        + '        stream = _ClientStreamImpl(ctx, reqs, ' + pb + '.' + m.input + ')\n'
        + '        impl.' + impl + '(stream)\n'
        + '        if stream.resp is None:\n'
        + '            raise grpcdc.StatusError(grpcdc.CODE_INTERNAL, "client-streaming handler never called SendAndClose")\n'
        + '        sink.send(stream.resp.marshal_dc())\n\n';
    default:
      return '    def _' + m.name + '_handler(ctx, reqs, sink):\n'
        + '        impl.' + impl + '(_BidiStream(ctx, reqs, sink, ' + pb + '.' + m.input + '))\n\n';
  }
}

const PY_KIND_NAMES = {
  unary: 'KIND_UNARY',
  'server-streaming': 'KIND_SERVER_STREAMING',
  'client-streaming': 'KIND_CLIENT_STREAMING',
  bidi: 'KIND_BIDI',
};

function pyMethodEntry(m) {
  return '        grpcdc.Method(' + q(m.name) + ', ' + q(m.path) + ', grpcdc.' + PY_KIND_NAMES[m.kind] + ', _' + m.name + '_handler),\n';
}

const PY_STREAM_HELPERS = `class _RecvStream:
    """Client receiving stream: recv() raises EOFError at end."""

    def __init__(self, stream, resp_cls):
        self._stream = stream
        self._resp_cls = resp_cls

    def recv(self):
        return self._stream.recv(self._resp_cls())

    def __iter__(self):
        return self

    def __next__(self):
        try:
            return self.recv()
        except EOFError:
            raise StopIteration


class _SendStream:
    """Server-streaming sink passed to service implementations."""

    def __init__(self, ctx, sink):
        self.context = ctx
        self._sink = sink

    def send(self, resp):
        self._sink.send(resp.marshal_dc())


class _ClientStreamImpl:
    """Client-streaming stream passed to service implementations."""

    def __init__(self, ctx, reqs, req_cls):
        self.context = ctx
        self._reqs = reqs
        self._req_cls = req_cls
        self.resp = None

    def recv(self):
        return self._reqs.recv_into(self._req_cls())

    def send_and_close(self, resp):
        self.resp = resp


class _BidiStream:
    """Bidi stream passed to service implementations."""

    def __init__(self, ctx, reqs, sink, req_cls):
        self.context = ctx
        self._reqs = reqs
        self._sink = sink
        self._req_cls = req_cls

    def send(self, resp):
        self._sink.send(resp.marshal_dc())

    def recv(self):
        return self._reqs.recv_into(self._req_cls())


class _AsyncRecvStream:
    """Async client receiving stream: async-for or await recv()."""

    def __init__(self, stream, resp_cls):
        self._stream = stream
        self._resp_cls = resp_cls

    async def recv(self):
        return await self._stream.recv(self._resp_cls())

    def cancel(self):
        self._stream.cancel()

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            return await self.recv()
        except EOFError:
            raise StopAsyncIteration


`;

function pyService(pb, svc) {
  const sname = svc.name;
  return 'class ' + sname + 'Client:\n    def __init__(self, channel):\n        self._channel = channel\n\n'
    + svc.methods.concat(aliasClientMethods(svc)).map((m) => pyClientMethod(pb, m)).join('')
    + 'class ' + sname + 'ClientAsync:\n    """Asyncio client: wrap a grpcdc.AsyncChannel (a sync Channel is wrapped)."""\n\n    def __init__(self, channel):\n        if isinstance(channel, grpcdc.AsyncChannel):\n            self._channel = channel\n        else:\n            self._channel = grpcdc.AsyncChannel(channel=channel)\n\n'
    + svc.methods.concat(aliasClientMethods(svc)).map((m) => pyAsyncClientMethod(pb, m)).join('')
    + 'def register_' + snake(sname) + '_server(server, impl):\n'
    + svc.methods.concat(aliasServerMethods(svc)).map((m) => pyServerHandler(pb, m)).join('')
    + '    server.register_service(grpcdc.ServiceDesc(\n        ' + q(svc.fullName) + ',\n        [\n'
    + svc.methods.concat(aliasServerMethods(svc)).map(pyMethodEntry).join('')
    + '        ],\n    ))\n';
}

function emitPythonFile(model, params) {
  const base = baseName(model.name);
  const pb = base + '_pb';
  return {
    name: base + '_grpc_dc.py',
    content: '# @generated by protoc-gen-grpc-dc-python (Racket metaprogram). DO NOT EDIT.\n'
      + '# source: ' + model.name + '\n\n'
      + 'try:\n    from . import ' + pb + '\nexcept ImportError:  # direct module load\n    import ' + pb + '\n\n'
      + 'import grpcdc\n\n'
      + PY_STREAM_HELPERS
      + model.services.map((svc) => pyService(pb, svc)).join(''),
  };
}

// ---------------------------------------------------------------------------
// Entry points. generateFiles mirrors the protoc plugin contract:
// one output file per file-to-generate, stamped with the generated
// code license header exactly like racket/desc.rkt does.
// ---------------------------------------------------------------------------

function stampGeneratedHeader(file) {
  const prefix = file.name.endsWith('.py') ? '#' : '//';
  return {
    name: file.name,
    content: prefix + ' Generated code: use without restriction (see GENERATED-CODE-LICENSE.md).\n' + file.content,
  };
}

const EMITTERS = { js: emitJsFile, go: emitGoFile, python: emitPythonFile };

export const GENERATOR_LANGUAGES = Object.keys(EMITTERS);

export function describeFiles(setBytes, entries) {
  return buildModel(setBytes, entries);
}

export function generateFiles(lang, setBytes, entries, parameter) {
  const emit = EMITTERS[lang];
  if (!emit) throw new Error('unsupported generator language: ' + lang);
  const params = parseParams(parameter || '');
  return buildModel(setBytes, entries).map((model) => stampGeneratedHeader(emit(model, params)));
}
JS
)

(define (emit-web-generators)
  (cons "generators.js"
        (string-append js-part-1 (alias-table-json) js-part-2 js-part-3 js-part-4)))


