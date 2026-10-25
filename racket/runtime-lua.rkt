#lang racket

;;; runtime-lua.rkt — the Lua gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under lua/grpcdc/ are GENERATED from the bodies
;;; below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; Pure Lua 5.4 stdlib only — no sockets, no threads: the runtime is
;;; single-threaded and cooperative (see endpoint.lua's pump model),
;;; with a documented stdio/embedded transport caveat.

(require "spec.rkt")
(provide emit-lua-runtime-files)

(define lua-status-body
#<<GRPC_RUNTIME_EOF
local wire = require("grpcdc.wire")

--- A gRPC status (code + message), raised as a Lua error object:
--- error(Status.new(code, msg)). Mirrors StatusException in the
--- other grpcdc runtimes; pcall catches it like an exception.
local Status = {}
Status.__index = Status

function Status.new(code, message)
  return setmetatable({ code = code, message = message or "", trailers = {} }, Status)
end

function Status.ok()
  return Status.new(wire.CODE_OK, "")
end

function Status:isOk()
  return self.code == wire.CODE_OK
end

function Status:__tostring()
  return string.format("%s: %s", wire.statusName(self.code), self.message)
end

--- Unique sentinel raised at end of a receiving stream (the call
--- completed OK). Compare with ==, never construct another one.
local EndOfStream = setmetatable({}, {
  __tostring = function() return "EndOfStream" end,
})

--- Convert a caught error value to a Status (OK for nil).
local function toStatus(err)
  if err == nil then
    return Status.ok()
  end
  if type(err) == "table" and getmetatable(err) == Status then
    return err
  end
  return Status.new(wire.CODE_INTERNAL, tostring(err))
end

--- Raise a Status as an error (level 0 keeps the table intact).
local function raise(status)
  error(status, 0)
end

-- --- Homegrown tracing (W3C traceparent propagation) -------------
-- Dormant until setTracer registers an observer table with
-- onStart(kind, method, traceId, spanId, parentSpanId) and
-- onEnd(kind, method, traceId, spanId, statusName) fields.
-- Dependency-free: sampling and export are the app's problem.

local tracer = nil

local function setTracer(t)
  tracer = t
end

local function getTracer()
  return tracer
end

local traceFilter = {}

-- Restrict traced methods: ';'-separated paths, a trailing
-- '*' means prefix match ('/echo.Echo/*'). Empty = trace all.
local function setTraceFilter(patterns)
  traceFilter = {}
  for p in string.gmatch(patterns, "[^;]+") do
    traceFilter[#traceFilter + 1] = p
  end
end

local function traceAllowed(method)
  if #traceFilter == 0 then return true end
  for _, p in ipairs(traceFilter) do
    if p:sub(-1) == "*" then
      if method:sub(1, #p - 1) == p:sub(1, -2) then return true end
    elseif method == p then
      return true
    end
  end
  return false
end

local randCounter = 0
local function randomHex(nbytes)
  randCounter = randCounter + 1
  math.randomseed(os.time() + randCounter * 7919)
  local out = {}
  for i = 1, nbytes do
    out[i] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(out)
end

local function formatTraceparent(traceId, spanId)
  return "00-" .. traceId .. "-" .. spanId .. "-01"
end

local function parseTraceparent(value)
  if type(value) ~= "string" then return nil end
  local parts = {}
  for part in string.gmatch(value, "[^-]+") do
    parts[#parts + 1] = part
  end
  if #parts ~= 4 then return nil end
  local traceId, spanId = parts[2], parts[3]
  if #traceId ~= 32 or #spanId ~= 16 then return nil end
  if traceId:find("[^0-9a-f]") or spanId:find("[^0-9a-f]") then return nil end
  return { traceId = traceId, spanId = spanId }
end

local function traceStart(kind, method, parent)
  if tracer == nil or not traceAllowed(method) then return nil end
  local ctx = { spanId = randomHex(8) }
  if parent ~= nil then
    ctx.traceId = parent.traceId
    ctx.parentSpanId = parent.spanId
  else
    ctx.traceId = randomHex(16)
    ctx.parentSpanId = ""
  end
  pcall(function()
    if tracer.onStart then
      tracer.onStart(kind, method, ctx.traceId, ctx.spanId, ctx.parentSpanId)
    end
  end)
  return ctx
end

local function traceEnd(kind, method, ctx, status)
  if ctx == nil or tracer == nil then return end
  pcall(function()
    if tracer.onEnd then
      tracer.onEnd(kind, method, ctx.traceId, ctx.spanId, status)
    end
  end)
end

return {
  Status = Status,
  EndOfStream = EndOfStream,
  toStatus = toStatus,
  raise = raise,
  setTracer = setTracer,
  setTraceFilter = setTraceFilter,
  tracer = getTracer,
  formatTraceparent = formatTraceparent,
  parseTraceparent = parseTraceparent,
  traceStart = traceStart,
  traceEnd = traceEnd,
}
GRPC_RUNTIME_EOF
)

(define lua-codec-body
#<<GRPC_RUNTIME_EOF
local wire = require("grpcdc.wire")
local statusModule = require("grpcdc.status")

local Status = statusModule.Status
local raise = statusModule.raise

--- Minimal JSON encode/decode for HEADERS/TRAILERS payloads (objects
--- with string keys; string/number/boolean values). Lua's stdlib has
--- no JSON, so the codec carries this small implementation.
local json = {}

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
  ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}

function json.escapeString(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    return escapes[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

function json.encode(value)
  local t = type(value)
  if t == "string" then
    return json.escapeString(value)
  elseif t == "number" then
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
      return string.format("%d", value)
    end
    return string.format("%.17g", value)
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "table" then
    -- Objects carry the __isObject marker or string keys.
    local isArray = #value > 0
    local parts = {}
    if isArray then
      for i = 1, #value do
        parts[#parts + 1] = json.encode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = json.escapeString(k) .. ":" .. json.encode(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("cannot JSON-encode " .. t)
end

local function parseValue(s, pos)
  local function skipWs(p)
    while p <= #s do
      local c = s:sub(p, p)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then
        p = p + 1
      else
        break
      end
    end
    return p
  end

  local parse
  local function parseString(p)
    -- s:sub(p,p) == '"'
    local out = {}
    p = p + 1
    while p <= #s do
      local c = s:sub(p, p)
      if c == '"' then
        return table.concat(out), p + 1
      elseif c == "\\" then
        local e = s:sub(p + 1, p + 1)
        if e == "n" then out[#out + 1] = "\n"
        elseif e == "t" then out[#out + 1] = "\t"
        elseif e == "r" then out[#out + 1] = "\r"
        elseif e == "b" then out[#out + 1] = "\b"
        elseif e == "f" then out[#out + 1] = "\f"
        elseif e == "u" then
          local hex = s:sub(p + 2, p + 5)
          local cp = tonumber(hex, 16) or 0
          out[#out + 1] = utf8.char(cp)
          p = p + 4
        else out[#out + 1] = e end
        p = p + 2
      else
        out[#out + 1] = c
        p = p + 1
      end
    end
    error("unterminated JSON string")
  end

  parse = function(p)
    p = skipWs(p)
    local c = s:sub(p, p)
    if c == "{" then
      local obj = {}
      p = skipWs(p + 1)
      if s:sub(p, p) == "}" then return obj, p + 1 end
      while true do
        p = skipWs(p)
        local key
        key, p = parseString(p)
        p = skipWs(p)
        if s:sub(p, p) ~= ":" then error("expected ':' in JSON object") end
        local val
        val, p = parse(p + 1)
        obj[key] = val
        p = skipWs(p)
        local d = s:sub(p, p)
        if d == "}" then return obj, p + 1 end
        if d ~= "," then error("expected ',' in JSON object") end
        p = p + 1
      end
    elseif c == "[" then
      local arr = {}
      p = skipWs(p + 1)
      if s:sub(p, p) == "]" then return arr, p + 1 end
      while true do
        local val
        val, p = parse(p)
        arr[#arr + 1] = val
        p = skipWs(p)
        local d = s:sub(p, p)
        if d == "]" then return arr, p + 1 end
        if d ~= "," then error("expected ',' in JSON array") end
        p = p + 1
      end
    elseif c == '"' then
      return parseString(p)
    elseif s:sub(p, p + 3) == "true" then
      return true, p + 4
    elseif s:sub(p, p + 4) == "false" then
      return false, p + 5
    elseif s:sub(p, p + 3) == "null" then
      return nil, p + 4
    else
      local num = s:match("^%-?%d+%.?%d*[eE]?[%-+]?%d*", p)
      if not num or num == "" or num == "-" then error("bad JSON value at " .. p) end
      local n = tonumber(num)
      if n == nil then error("bad JSON number") end
      return n, p + #num
    end
  end

  return parse(pos)
end

function json.decode(s)
  local value = parseValue(s, 1)
  return value
end

local Codec = {}
Codec.HEADER_LEN = 9
Codec.MAX_DATA_PAYLOAD = 16 * 1024 * 1024
Codec.json = json

local function getU32(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  return (a << 24) | (b << 16) | (c << 8) | d
end

function Codec.getU32(data, offset) return getU32(data, offset) end

--- One parsed frame: {type, streamId, payload}.
function Codec.decodeFrame(data)
  if #data < Codec.HEADER_LEN then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT,
      "frame shorter than 9-byte header: " .. #data .. " bytes"))
  end
  local length = getU32(data, 6)
  if length ~= #data - Codec.HEADER_LEN then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT,
      "payload length " .. length .. " does not match message size " .. #data))
  end
  return {
    type = data:byte(1),
    streamId = getU32(data, 2),
    payload = data:sub(10),
  }
end

--- Build one DataChannel message: header + payload.
function Codec.encodeFrame(frameType, streamId, payload)
  if not wire.isFrameType(frameType) then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT, "unknown frame type " .. tostring(frameType)))
  end
  if frameType == wire.FRAME_DATA and #payload > Codec.MAX_DATA_PAYLOAD then
    raise(Status.new(wire.CODE_RESOURCE_EXHAUSTED, "DATA payload exceeds 16 MiB"))
  end
  return string.pack(">BI4I4", frameType, streamId, #payload) .. payload
end

--- Parse a HEADERS payload: {path=string|nil, metadata={}}.
function Codec.parseHeaders(payload)
  local ok, root = pcall(json.decode, payload)
  if not ok or type(root) ~= "table" then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT, "bad HEADERS payload"))
  end
  local metadata = {}
  if type(root.metadata) == "table" then
    for k, v in pairs(root.metadata) do
      metadata[tostring(k)] = tostring(v)
    end
  end
  return { path = root.path, metadata = metadata }
end

function Codec.headersFrame(streamId, path, metadata)
  local body = {}
  if path ~= nil then body.path = path end
  if metadata ~= nil and next(metadata) ~= nil then
    body.metadata = metadata
  end
  return Codec.encodeFrame(wire.FRAME_HEADERS, streamId, json.encode(body))
end

--- gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
--- units H/M/S/m/u/n (at most 8 digits). Encoding uses
--- milliseconds (seconds past the digit limit), rounded up.
function Codec.encodeTimeout(seconds)
  local ms = math.ceil(seconds * 1000)
  if ms <= 99999999 then
    return string.format("%dm", ms)
  end
  return string.format("%dS", math.ceil(seconds))
end

--- Decoded grpc-timeout in seconds, or nil when malformed.
function Codec.parseTimeout(text)
  if type(text) ~= "string" or #text < 2 or #text > 9 then return nil end
  local digits = text:sub(1, -2)
  if digits:match("^%d+$") == nil then return nil end
  local n = tonumber(digits)
  local unit = text:sub(-1)
  if unit == "H" then return n * 3600
  elseif unit == "M" then return n * 60
  elseif unit == "S" then return n
  elseif unit == "m" then return n / 1000
  elseif unit == "u" then return n / 1000000
  elseif unit == "n" then return n / 1000000000
  end
  return nil
end

function Codec.statusFrame(frameType, streamId, status)
  local fields = { code = status.code, message = status.message }
  if status.trailers ~= nil and next(status.trailers) ~= nil then
    fields.metadata = status.trailers
  end
  local body = json.encode(fields)
  return Codec.encodeFrame(frameType, streamId, body)
end

function Codec.parseStatus(payload)
  local ok, root = pcall(json.decode, payload)
  if ok and type(root) == "table" and type(root.code) == "number" then
    local status = Status.new(math.tointeger(root.code) or 0, tostring(root.message or ""))
    if type(root.metadata) == "table" then
      for k, v in pairs(root.metadata) do
        status.trailers[tostring(k)] = tostring(v)
      end
    end
    return status
  end
  return Status.new(wire.CODE_UNKNOWN, "malformed trailers")
end

return Codec
GRPC_RUNTIME_EOF
)

(define lua-transport-body
#<<GRPC_RUNTIME_EOF
--- Transport contract (duck-typed table):
---   send(self, bytes)          one call is one DataChannel message
---   recvMessage(self) -> bytes|nil   next message, or nil when the
---                              queue is empty (memory) / at EOF
---   close(self)
---   peerPump (optional fn)     called by client loops when the local
---                              endpoint has nothing to process, so a
---                              linked in-process peer can make
---                              progress (single-threaded runtime).
---
--- Message types implement:
---   marshalDc(self) -> string (protobuf bytes)
---   unmarshalDc(self, bytes)
return {}
GRPC_RUNTIME_EOF
)

(define lua-endpoint-body
#<<GRPC_RUNTIME_EOF
local wire = require("grpcdc.wire")
local Codec = require("grpcdc.codec")
local statusModule = require("grpcdc.status")

local Status = statusModule.Status
local raise = statusModule.raise

--- Receiving queue of one stream; closed after a terminal event.
local StreamInput = {}
StreamInput.__index = StreamInput

function StreamInput.new()
  return setmetatable({ items = {}, first = 1, last = 0, closedFlag = false }, StreamInput)
end

function StreamInput:put(event)
  if self.closedFlag then return end
  self.last = self.last + 1
  self.items[self.last] = event
end

function StreamInput:close()
  self.closedFlag = true
end

--- Next event, or nil once the stream is closed and drained. Never
--- blocks: the single-threaded runtime processes one transport
--- message per Endpoint:pump() and callers poll their queue.
function StreamInput:get()
  if self.first <= self.last then
    local event = self.items[self.first]
    self.items[self.first] = nil
    self.first = self.first + 1
    return event
  end
  return nil
end

function StreamInput:hasData()
  return self.first <= self.last
end

--- Monotonic clock in seconds: the WASM/browser host provides
--- host_now (no os library there); native Lua uses os.clock.
--- Returns nil when no clock exists (deadlines then propagate
--- but are not enforced locally).
local function nowSeconds()
  if host_now ~= nil then return host_now() end
  if os ~= nil and os.clock ~= nil then return os.clock() end
  return nil
end

--- Per-call context: metadata sent in HEADERS, plus deadline.
local function newCallContext(metadata)
  local ctx = { metadata = metadata, responseHeaders = {}, responseTrailers = {} }
  --- Record response initial metadata (sent lazily, before
  --- the first response message).
  function ctx:setHeaders(md)
    for k, v in pairs(md) do self.responseHeaders[k] = v end
  end
  --- Record response trailing metadata (rides the terminal
  --- status frame).
  function ctx:setTrailers(md)
    for k, v in pairs(md) do self.responseTrailers[k] = v end
  end
  local remaining = Codec.parseTimeout(metadata ~= nil and metadata["grpc-timeout"] or nil)
  local now = nowSeconds()
  if remaining ~= nil and now ~= nil then
    ctx.deadline = now + remaining
  end
  function ctx:timeRemaining()
    if self.deadline == nil then return nil end
    local current = nowSeconds()
    if current == nil then return nil end
    return math.max(0, self.deadline - current)
  end
  function ctx:deadlineExceeded()
    return self:timeRemaining() == 0
  end
  return ctx
end

--- Sends response payloads of one inbound call.
local ResponseSink = {}
ResponseSink.__index = ResponseSink

function ResponseSink.new(endpoint, streamId)
  return setmetatable({
    endpoint = endpoint, streamId = streamId,
    respHeaders = {}, respTrailers = {}, headersSent = false,
  }, ResponseSink)
end

function ResponseSink:send(payload)
  self:flushHeaders()
  self.endpoint:sendFrame(Codec.encodeFrame(wire.FRAME_DATA, self.streamId, payload))
end

function ResponseSink:flushHeaders()
  if not self.headersSent then
    self.headersSent = true
    self:sendHeaders(self.respHeaders)
  end
end

function ResponseSink:sendHeaders(metadata)
  self.headersSent = true
  self.endpoint:sendFrame(Codec.headersFrame(self.streamId, nil, metadata or self.respHeaders))
end

function ResponseSink:sendTrailers(status)
  if next(self.respTrailers) ~= nil then
    local merged = {}
    for k, v in pairs(self.respTrailers) do merged[k] = v end
    if status.trailers ~= nil then
      for k, v in pairs(status.trailers) do merged[k] = v end
    end
    status = Status.new(status.code, status.message)
    status.trailers = merged
  end
  self.endpoint:sendFrame(Codec.statusFrame(wire.FRAME_TRAILERS, self.streamId, status))
end

--- Multiplexes grpc-dc streams over one Transport.
---
--- The runtime is single-threaded and cooperative (pure Lua stdlib
--- has no threads): Endpoint:pump() processes at most one inbound
--- transport message, running server handlers inline. Client calls
--- loop on pump() — consulting the transport's peerPump hook when
--- idle so an in-process loopback peer makes progress. This is the
--- documented Lua transport caveat: blocking transports (stdio)
--- simply block inside recvMessage during pump().
local Endpoint = {}
Endpoint.__index = Endpoint
Endpoint.nowSeconds = nowSeconds

--- The side that created the channel allocates odd stream ids, the
--- answerer even.
function Endpoint.new(transport, creator)
  local self = setmetatable({
    transport = transport,
    dispatcher = nil, -- fn(ctx, headers, input, sink) -> Status|nil
    nextId = creator and 1 or 2,
    streams = {},
    closed = false,
  }, Endpoint)
  transport.endpoint = self
  return self
end

function Endpoint:sendFrame(frame)
  self.transport:send(frame)
end

function Endpoint:openStream()
  local id = self.nextId
  self.nextId = self.nextId + 2
  local input = StreamInput.new()
  self.streams[id] = input
  return id, input
end

function Endpoint:closeStream(id)
  self.streams[id] = nil
end

--- Abort one stream: RST towards the peer; a pending recv wakes
--- with the cancellation status (the local input is closed with
--- a synthetic RST event).
function Endpoint:cancelStream(id)
  local status = Status.new(wire.CODE_CANCELLED, "call cancelled")
  local input = self.streams[id]
  self.streams[id] = nil
  if input ~= nil then
    input:put({ kind = "rst", status = status })
    input:close()
  end
  pcall(function()
    self:sendFrame(Codec.statusFrame(wire.FRAME_RST, id, status))
  end)
end

function Endpoint:close()
  if self.closed then return end
  self.closed = true
  self.transport:close()
  self:failAll()
end

function Endpoint:failAll()
  local streams = self.streams
  self.streams = {}
  for _, input in pairs(streams) do
    input:put({ kind = "rst", status = Status.new(wire.CODE_UNAVAILABLE, "data channel closed") })
    input:close()
  end
end

--- Process at most one inbound message; returns true when one was
--- processed. Server dispatch runs inline (handlers may pump
--- reentrantly to receive their own request stream).
function Endpoint:pump()
  if self.closed then return false end
  local data = self.transport:recvMessage()
  if data == nil then return false end
  self:onBytes(data)
  return true
end

--- Pump until fn() reports progress or nothing can move.
function Endpoint:pumpWhile(fn)
  while not fn() do
    if self:pump() then
      -- progress
    elseif self.transport.peerPump and self.transport:peerPump() then
      -- peer progress
    else
      raise(Status.new(wire.CODE_UNAVAILABLE, "data channel closed"))
    end
  end
end

function Endpoint:onBytes(data)
  if self.closed then return end
  local ok, frame = pcall(Codec.decodeFrame, data)
  if not ok then return end -- malformed frame: drop, keep the channel up
@@FRAME_DISPATCH@@
end

function Endpoint:onTerminal(streamId, payload, kind)
  local input = self.streams[streamId]
  if input then
    input:put({ kind = kind, status = Codec.parseStatus(payload) })
    input:close()
    self:closeStream(streamId)
  end
end

function Endpoint:onHeaders(streamId, payload)
  local ok, headers = pcall(Codec.parseHeaders, payload)
  if not ok then
    local st = statusModule.toStatus(headers)
    pcall(function() self:sendFrame(Codec.statusFrame(wire.FRAME_RST, streamId, st)) end)
    return
  end
  if headers.path == nil then
    -- Server response headers for one of our outbound streams.
    local input = self.streams[streamId]
    if input then input:put({ kind = "headers", headers = headers }) end
    return
  end
  if self.streams[streamId] ~= nil then
    pcall(function()
      self:sendFrame(Codec.statusFrame(wire.FRAME_RST, streamId,
        Status.new(wire.CODE_INTERNAL, "HEADERS for stream already in use")))
    end)
    return
  end
  if self.dispatcher == nil then
    pcall(function()
      self:sendFrame(Codec.statusFrame(wire.FRAME_TRAILERS, streamId,
        Status.new(wire.CODE_UNIMPLEMENTED, "unknown method " .. tostring(headers.path))))
    end)
    return
  end
  local input = StreamInput.new()
  self.streams[streamId] = input
  local sink = ResponseSink.new(self, streamId)
  -- No eager HEADERS: initial metadata flushes lazily via the
  -- sink (first DATA, or below on a DATA-less success) so
  -- handlers can setHeaders first. Errors end trailers-only,
  -- as gRPC allows.
  local ctx = newCallContext(headers.metadata)
  sink.respHeaders = ctx.responseHeaders
  sink.respTrailers = ctx.responseTrailers
  local callOk, result = pcall(self.dispatcher, ctx, headers, input, sink)
  local status
  if callOk then
    status = result or Status.ok()
  else
    status = statusModule.toStatus(result)
  end
  if status:isOk() then
    pcall(function() sink:flushHeaders() end)
  end
  pcall(function() sink:sendTrailers(status) end)
  self:closeStream(streamId)
end

return {
  Endpoint = Endpoint,
  StreamInput = StreamInput,
  ResponseSink = ResponseSink,
}
GRPC_RUNTIME_EOF
)

(define lua-channel-body
#<<GRPC_RUNTIME_EOF
local wire = require("grpcdc.wire")
local Codec = require("grpcdc.codec")
local endpointModule = require("grpcdc.endpoint")
local statusModule = require("grpcdc.status")

local Status = statusModule.Status
local raise = statusModule.raise
local EndOfStream = statusModule.EndOfStream
local Endpoint = endpointModule.Endpoint

--- Receives response messages of one call.
local ClientStream = {}
ClientStream.__index = ClientStream

function ClientStream.new(endpoint, streamId, input)
  return setmetatable({
    endpoint = endpoint,
    streamId = streamId,
    input = input,
    headers = nil,
    trailers = nil,
    traceCtx = nil,
    tracePath = nil,
    traceEnded = false,
  }, ClientStream)
end

function ClientStream:endTrace(status)
  if not self.traceEnded then
    self.traceEnded = true
    statusModule.traceEnd("client", self.tracePath, self.traceCtx, status)
  end
end

--- Next raw response event; pumps the endpoint until one arrives.
function ClientStream:nextEvent()
  while true do
    local event = self.input:get()
    if event ~= nil then return event end
    if self.input.closedFlag then
      raise(Status.new(wire.CODE_UNAVAILABLE, "data channel closed"))
    end
    if self.deadline ~= nil then
      -- Deadline-aware pump loop (checks between messages; a
      -- blocking transport still blocks inside pump, the
      -- documented cooperative-runtime caveat).
      local now = Endpoint.nowSeconds()
      if now ~= nil and now >= self.deadline then
        self.endpoint:cancelStream(self.streamId)
        raise(Status.new(wire.CODE_DEADLINE_EXCEEDED, "deadline exceeded"))
      end
      if self.endpoint:pump() then
        -- progress
      elseif self.endpoint.transport.peerPump and self.endpoint.transport:peerPump() then
        -- peer progress
      elseif self.endpoint.closed then
        raise(Status.new(wire.CODE_UNAVAILABLE, "data channel closed"))
      end
      -- Otherwise idle but open: loop and re-check the deadline
      -- (cooperative busy-wait; blocking transports simply block
      -- inside pump instead).
    else
      self.endpoint:pumpWhile(function()
        return self.input:hasData() or self.input.closedFlag
      end)
    end
  end
end

--- Decode the next response into resp. Raises EndOfStream when the
--- call completed OK; raises a Status for trailers errors.
function ClientStream:recv(resp)
  while true do
    local event = self:nextEvent()
    if event.kind == "headers" then
      self.headers = event.headers
    elseif event.kind == "data" then
      resp:unmarshalDc(event.payload)
      return
    elseif event.kind == "trailers" then
      local status = event.status
      if status ~= nil then self.trailers = status.trailers end
      self:endTrace(wire.statusName(status ~= nil and status.code or wire.CODE_OK))
      if status ~= nil and status.code ~= wire.CODE_OK then
        raise(status)
      end
      error(EndOfStream, 0)
    elseif event.kind == "rst" then
      local status = event.status or Status.new(wire.CODE_UNAVAILABLE, "stream reset")
      self.trailers = status.trailers
      self:endTrace(wire.statusName(status.code))
      raise(status)
    end
    -- half_close on a client stream: ignore
  end
end

--- Channel: the client side of one Endpoint.
local Channel = {}
Channel.__index = Channel

--- Wrap a transport, allocating odd stream ids.
function Channel.new(transport)
  local self = setmetatable({ endpoint = Endpoint.new(transport, true) }, Channel)
  return self
end

--- Wrap an existing endpoint (bidirectional use).
function Channel.fromEndpoint(endpoint)
  return setmetatable({ endpoint = endpoint }, Channel)
end

function Channel:open(path, metadata, timeout)
  local deadline = nil
  local traceCtx = nil
  if timeout ~= nil or statusModule.tracer() ~= nil then
    local merged = {}
    if metadata ~= nil then
      for k, v in pairs(metadata) do merged[k] = v end
    end
    if timeout ~= nil then
      local now = Endpoint.nowSeconds()
      if now ~= nil then deadline = now + timeout end
      merged["grpc-timeout"] = Codec.encodeTimeout(timeout)
    end
    if statusModule.tracer() ~= nil then
      traceCtx = statusModule.traceStart("client", path, statusModule.parseTraceparent(merged["traceparent"]))
      if traceCtx ~= nil then
        merged["traceparent"] = statusModule.formatTraceparent(traceCtx.traceId, traceCtx.spanId)
      end
    end
    metadata = merged
  end
  local id, input = self.endpoint:openStream()
  local ok, err = pcall(function()
    self.endpoint:sendFrame(Codec.headersFrame(id, path, metadata))
  end)
  if not ok then
    self.endpoint:closeStream(id)
    statusModule.traceEnd("client", path, traceCtx, "UNAVAILABLE")
    error(err, 0)
  end
  local stream = ClientStream.new(self.endpoint, id, input)
  stream.deadline = deadline
  stream.traceCtx = traceCtx
  stream.tracePath = path
  return stream
end

function Channel:sendMessage(stream, msg)
  self.endpoint:sendFrame(Codec.encodeFrame(wire.FRAME_DATA, stream.streamId, msg:marshalDc()))
end

function Channel:halfClose(stream)
  self.endpoint:sendFrame(Codec.encodeFrame(wire.FRAME_HALF_CLOSE, stream.streamId, ""))
end

function Channel:sendAll(stream, reqs)
  for _, req in ipairs(reqs) do
    self:sendMessage(stream, req)
  end
  self:halfClose(stream)
end

function Channel:collectOne(stream, resp, what)
  local got = false
  while true do
    local ok, err = pcall(function() stream:recv(resp) end)
    if not ok then
      if err == EndOfStream then
        if not got then
          raise(Status.new(wire.CODE_INTERNAL, "call closed with no response"))
        end
        return
      end
      error(err, 0)
    end
    if got then
      raise(Status.new(wire.CODE_INTERNAL, what .. " received more than one response"))
    end
    got = true
  end
end

--- Run a unary call, decoding the single response into resp.
function Channel:unary(path, req, resp, metadata, timeout)
  local stream = self:open(path, metadata, timeout)
  local ok, err = pcall(function()
    self:sendMessage(stream, req)
    self:halfClose(stream)
    self:collectOne(stream, resp, "unary call")
  end)
  self.endpoint:closeStream(stream.streamId)
  if not ok then error(err, 0) end
end

--- Start a server-streaming call.
function Channel:serverStream(path, req, metadata, timeout)
  local stream = self:open(path, metadata, timeout)
  self:sendMessage(stream, req)
  self:halfClose(stream)
  return stream
end

--- Send all requests, then decode the one response into resp.
function Channel:clientStreamCall(path, reqs, resp, metadata, timeout)
  local stream = self:open(path, metadata, timeout)
  local ok, err = pcall(function()
    self:sendAll(stream, reqs)
    self:collectOne(stream, resp, "client-streaming call")
  end)
  self.endpoint:closeStream(stream.streamId)
  if not ok then error(err, 0) end
end

--- Start a bidi call with all requests sent up front.
function Channel:bidi(path, reqs, metadata, timeout)
  local stream = self:open(path, metadata, timeout)
  self:sendAll(stream, reqs)
  return stream
end

--- Abort an open ClientStream (sends RST, wakes a pending recv).
function ClientStream:cancel()
  self.endpoint:cancelStream(self.streamId)
end

function Channel:cancel(stream)
  stream:cancel()
end

--- Coroutine receiving stream: recv executes inside a coroutine,
--- so calls compose with coroutine-based schedulers and event
--- loops that drive grpcdc from coroutines.
local CoroutineStream = {}
CoroutineStream.__index = CoroutineStream

function CoroutineStream.new(stream)
  return setmetatable({ stream = stream }, CoroutineStream)
end

function CoroutineStream:recv(resp)
  local run = coroutine.wrap(function()
    self.stream:recv(resp)
  end)
  run()
  return resp
end

function CoroutineStream:cancel()
  self.stream:cancel()
end

--- Coroutine client facade over Channel: unary and
--- client-streaming calls run to completion inside a coroutine;
--- streaming calls return a CoroutineStream. Wrap an existing
--- Channel, or pass a transport to build one.
local CoroutineChannel = {}
CoroutineChannel.__index = CoroutineChannel

function CoroutineChannel.new(channel)
  if channel ~= nil and channel.isCoroutineChannel then
    return channel
  end
  local wrapped = channel
  if wrapped == nil or wrapped.endpoint == nil then
    wrapped = Channel.new(channel)
  end
  return setmetatable({
    channel = wrapped,
    endpoint = wrapped.endpoint,
    isCoroutineChannel = true,
  }, CoroutineChannel)
end

function CoroutineChannel:unary(path, req, resp, metadata, timeout)
  local run = coroutine.wrap(function()
    self.channel:unary(path, req, resp, metadata, timeout)
  end)
  run()
  return resp
end

function CoroutineChannel:clientStreamCall(path, reqs, resp, metadata, timeout)
  local run = coroutine.wrap(function()
    self.channel:clientStreamCall(path, reqs, resp, metadata, timeout)
  end)
  run()
  return resp
end

function CoroutineChannel:serverStream(path, req, metadata, timeout)
  return CoroutineStream.new(self.channel:serverStream(path, req, metadata, timeout))
end

function CoroutineChannel:bidi(path, reqs, metadata, timeout)
  return CoroutineStream.new(self.channel:bidi(path, reqs, metadata, timeout))
end

return {
  Channel = Channel,
  ClientStream = ClientStream,
  CoroutineChannel = CoroutineChannel,
  CoroutineStream = CoroutineStream,
}
GRPC_RUNTIME_EOF
)

(define lua-server-body
#<<GRPC_RUNTIME_EOF
local wire = require("grpcdc.wire")
local endpointModule = require("grpcdc.endpoint")
local statusModule = require("grpcdc.status")

local Status = statusModule.Status
local raise = statusModule.raise
local EndOfStream = statusModule.EndOfStream
local Endpoint = endpointModule.Endpoint

--- Reads request messages of one inbound call.
local RequestStream = {}
RequestStream.__index = RequestStream

function RequestStream.new(endpoint, input)
  return setmetatable({ endpoint = endpoint, input = input }, RequestStream)
end

--- Next request payload; raises EndOfStream at half-close. Pumps the
--- endpoint reentrantly until a message arrives (handlers run inline
--- in this single-threaded runtime).
function RequestStream:recvRaw()
  while true do
    local event = self.input:get()
    if event == nil then
      if self.input.closedFlag then
        raise(Status.new(wire.CODE_UNAVAILABLE, "data channel closed"))
      end
      self.endpoint:pumpWhile(function()
        return self.input:hasData() or self.input.closedFlag
      end)
    elseif event.kind == "data" then
      return event.payload
    elseif event.kind == "half_close" then
      error(EndOfStream, 0)
    elseif event.kind == "trailers" or event.kind == "rst" then
      raise(event.status or Status.new(wire.CODE_UNAVAILABLE, "stream closed"))
    end
    -- headers on the request side: ignore
  end
end

--- Decode the next request message into req.
function RequestStream:recvInto(req)
  req:unmarshalDc(self:recvRaw())
end

--- Server: dispatches inbound calls to registered methods.
local Server = {}
Server.__index = Server

Server.KIND_UNARY = "unary"
Server.KIND_SERVER_STREAMING = "server-streaming"
Server.KIND_CLIENT_STREAMING = "client-streaming"
Server.KIND_BIDI = "bidi"

function Server.new()
  return setmetatable({ methods = {}, endpointRef = nil }, Server)
end

--- The endpoint this server is attached to.
function Server:endpoint()
  return self.endpointRef
end

--- Adds a service's methods. desc = {name=..., methods={
--- {name=..., path=..., kind=..., handler=fn(ctx, reqs, sink)}...}}
--- (generated code calls it).
function Server:registerService(desc)
  for _, method in ipairs(desc.methods) do
    self.methods[method.path] = method
  end
end

--- Attach to a transport (even stream ids); returns the Endpoint.
function Server:serveTransport(transport)
  local endpoint = Endpoint.new(transport, false)
  self:serveEndpoint(endpoint)
  return endpoint
end

--- Attach to an existing endpoint.
function Server:serveEndpoint(endpoint)
  self.endpointRef = endpoint
  endpoint.dispatcher = function(ctx, headers, input, sink)
    return self:dispatch(endpoint, ctx, headers, input, sink)
  end
end

function Server:dispatch(endpoint, ctx, headers, input, sink)
  local method = self.methods[headers.path]
  if method == nil then
    return Status.new(wire.CODE_UNIMPLEMENTED, "unknown method " .. tostring(headers.path))
  end
  local traceCtx = statusModule.traceStart("server", headers.path, statusModule.parseTraceparent((headers.metadata or {})["traceparent"]))
  local reqs = RequestStream.new(endpoint, input)
  local ok, err = pcall(method.handler, ctx, reqs, function(payload)
    sink:send(payload)
  end)
  local result = nil
  if not ok then
    result = statusModule.toStatus(err)
  end
  statusModule.traceEnd("server", headers.path, traceCtx, result == nil and "OK" or wire.statusName(result.code))
  return result
end

return {
  Server = Server,
  RequestStream = RequestStream,
}
GRPC_RUNTIME_EOF
)

(define lua-memory-body
#<<GRPC_RUNTIME_EOF
--- In-memory transport pair for tests (one queue per direction).
--- recvMessage never blocks; client loops consult peerPump so the
--- peer endpoint makes progress in this single-threaded runtime.
local MemoryTransport = {}
MemoryTransport.__index = MemoryTransport

function MemoryTransport.new(inbox, outbox)
  return setmetatable({ inbox = inbox, outbox = outbox, closedFlag = false, peer = nil, endpoint = nil }, MemoryTransport)
end

function MemoryTransport:send(data)
  if self.closedFlag then
    error(require("grpcdc.status").EndOfStream, 0)
  end
  self.outbox[#self.outbox + 1] = data
end

function MemoryTransport:recvMessage()
  if #self.inbox > 0 then
    return table.remove(self.inbox, 1)
  end
  return nil
end

function MemoryTransport:close()
  self.closedFlag = true
  self.inbox.closedFlag = true
end

--- Pump the peer endpoint once (loopback progress hook).
function MemoryTransport:peerPump()
  if self.peer and self.peer.endpoint then
    return self.peer.endpoint:pump()
  end
  return false
end

--- Returns the two transports of a connected pair.
local function memoryTransportPair()
  local aToB, bToA = {}, {}
  local a = MemoryTransport.new(bToA, aToB)
  local b = MemoryTransport.new(aToB, bToA)
  a.peer = b
  b.peer = a
  return a, b
end

return {
  MemoryTransport = MemoryTransport,
  memoryTransportPair = memoryTransportPair,
}
GRPC_RUNTIME_EOF
)

(define lua-dynamic-body
#<<GRPC_RUNTIME_EOF
local wire = require("grpcdc.wire")
local channelModule = require("grpcdc.channel")
local serverModule = require("grpcdc.server")
local statusModule = require("grpcdc.status")

local Status = statusModule.Status
local raise = statusModule.raise
local EndOfStream = statusModule.EndOfStream
local Server = serverModule.Server

-- FieldDescriptorProto.Type values (descriptor.proto).
local TYPE_DOUBLE = 1
local TYPE_FLOAT = 2
local TYPE_INT64 = 3
local TYPE_UINT64 = 4
local TYPE_INT32 = 5
local TYPE_FIXED64 = 6
local TYPE_FIXED32 = 7
local TYPE_BOOL = 8
local TYPE_STRING = 9
local TYPE_GROUP = 10
local TYPE_MESSAGE = 11
local TYPE_BYTES = 12
local TYPE_UINT32 = 13
local TYPE_ENUM = 14
local TYPE_SFIXED32 = 15
local TYPE_SFIXED64 = 16
local TYPE_SINT32 = 17
local TYPE_SINT64 = 18

local LABEL_REPEATED = 3

--- Parsed descriptor set: messages and services by full name.
--- Message keys carry the leading dot (".echo.EchoRequest"), matching
--- FieldDescriptorProto.type_name; service keys do not ("echo.Echo").
local FileModel = {}
FileModel.__index = FileModel

function FileModel.new()
  return setmetatable({ messages = {}, services = {} }, FileModel)
end

function FileModel:message(fullName)
  local model = self.messages[fullName]
  if model == nil then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT, "unknown message " .. tostring(fullName)))
  end
  return model
end

function FileModel:service(fullName)
  local svc = self.services[fullName]
  if svc == nil then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT, "unknown service " .. tostring(fullName)))
  end
  return svc
end

--- A message as field number -> list of values.
---
--- Generic values: varint family -> integer/boolean, string ->
--- string, bytes/message -> string / GenericMessage, fixed/float ->
--- integer / number.
---
--- Fields not in the model are retained as raw encoded chunks in
--- unknown (protobuf unknown-field retention): a decode -> encode
--- round trip re-emits them after the known fields, so intermediate
--- hops do not strip newer fields.
local GenericMessage = {}
GenericMessage.__index = GenericMessage

function GenericMessage.new(model)
  return setmetatable({ model = model, values = {}, unknown = {} }, GenericMessage)
end

function GenericMessage:set(number, value)
  self.values[number] = { value }
  return self
end

function GenericMessage:add(number, value)
  local list = self.values[number]
  if list == nil then
    list = {}
    self.values[number] = list
  end
  list[#list + 1] = value
  return self
end

function GenericMessage:get(number)
  local list = self.values[number]
  if list == nil or #list == 0 then return nil end
  return list[1]
end

function GenericMessage:getString(number)
  local v = self:get(number)
  if type(v) == "string" then return v end
  return ""
end

function GenericMessage:getInt(number)
  local v = self:get(number)
  if type(v) == "boolean" then return v and 1 or 0 end
  if type(v) == "number" then return math.tointeger(v) or math.floor(v) end
  return 0
end

-- ---------------------------------------------------------------------------
-- Generic protobuf codec
-- ---------------------------------------------------------------------------

local PbReader = {}
PbReader.__index = PbReader

function PbReader.new(buf)
  return setmetatable({ buf = buf, pos = 1 }, PbReader)
end

function PbReader:varint()
  local result = 0
  local shift = 0
  while true do
    if self.pos > #self.buf then
      raise(Status.new(wire.CODE_INVALID_ARGUMENT, "truncated varint"))
    end
    local b = self.buf:byte(self.pos)
    self.pos = self.pos + 1
    result = result | ((b & 0x7f) << shift)
    if (b & 0x80) == 0 then return result end
    shift = shift + 7
    if shift >= 70 then
      raise(Status.new(wire.CODE_INVALID_ARGUMENT, "varint too long"))
    end
  end
end

function PbReader:lenBytes()
  local n = self:varint()
  if self.pos + n - 1 > #self.buf then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT, "truncated bytes field"))
  end
  local out = self.buf:sub(self.pos, self.pos + n - 1)
  self.pos = self.pos + n
  return out
end

--- Next field {number, wire, varint, bytes, chunk} or nil at end.
function PbReader:next()
  if self.pos > #self.buf then return nil end
  local start = self.pos
  local tag = self:varint()
  local field = { number = tag >> 3, wire = tag & 7, varint = 0, bytes = "" }
  if field.wire == 0 then
    field.varint = self:varint()
  elseif field.wire == 2 then
    field.bytes = self:lenBytes()
  elseif field.wire == 1 then
    if self.pos + 7 > #self.buf then
      raise(Status.new(wire.CODE_INVALID_ARGUMENT, "truncated fixed64"))
    end
    field.bytes = self.buf:sub(self.pos, self.pos + 7)
    self.pos = self.pos + 8
  elseif field.wire == 5 then
    if self.pos + 3 > #self.buf then
      raise(Status.new(wire.CODE_INVALID_ARGUMENT, "truncated fixed32"))
    end
    field.bytes = self.buf:sub(self.pos, self.pos + 3)
    self.pos = self.pos + 4
  else
    raise(Status.new(wire.CODE_INVALID_ARGUMENT, "unsupported wire type " .. field.wire))
  end
  field.chunk = self.buf:sub(start, self.pos - 1)
  return field
end

local function asString(field)
  return field.bytes
end

local function wireTypeOf(fieldType)
  if fieldType == TYPE_INT64 or fieldType == TYPE_UINT64 or fieldType == TYPE_INT32
    or fieldType == TYPE_BOOL or fieldType == TYPE_UINT32 or fieldType == TYPE_ENUM
    or fieldType == TYPE_SINT32 or fieldType == TYPE_SINT64 then
    return 0
  elseif fieldType == TYPE_FIXED64 or fieldType == TYPE_SFIXED64 or fieldType == TYPE_DOUBLE then
    return 1
  elseif fieldType == TYPE_STRING or fieldType == TYPE_BYTES or fieldType == TYPE_MESSAGE
    or fieldType == TYPE_GROUP then
    return 2
  elseif fieldType == TYPE_FIXED32 or fieldType == TYPE_SFIXED32 or fieldType == TYPE_FLOAT then
    return 5
  end
  return -1
end

local function encodeVarint(parts, value)
  local v = value
  if v < 0 then
    for _ = 1, 9 do
      parts[#parts + 1] = string.char((v & 0x7f) | 0x80)
      v = v >> 7
    end
    parts[#parts + 1] = string.char(v & 0x7f)
    return
  end
  while (v & ~0x7f) ~= 0 do
    parts[#parts + 1] = string.char((v & 0x7f) | 0x80)
    v = v >> 7
  end
  parts[#parts + 1] = string.char(v & 0xff)
end

local function zigzagEncode(v) return (v << 1) ~ (v >> 63) end
local function zigzagDecode(v) return (v >> 1) ~ -(v & 1) end

local function valueAsInt(value)
  if type(value) == "boolean" then return value and 1 or 0 end
  if type(value) == "number" then return math.tointeger(value) or math.floor(value) end
  return 0
end

local encodeValue
local function encodeGeneric(model, message, file)
  local parts = {}
  local numbers = {}
  for number in pairs(message.values) do
    numbers[#numbers + 1] = number
  end
  table.sort(numbers)
  for _, number in ipairs(numbers) do
    local field = model.fields[number]
    if field == nil then
      raise(Status.new(wire.CODE_INVALID_ARGUMENT,
        "unknown field " .. number .. " for " .. model.fullName))
    end
    local values = message.values[number]
    if field.repeated then
      for _, value in ipairs(values) do
        encodeValue(parts, field, value, file)
      end
    elseif #values > 0 then
      encodeValue(parts, field, values[1], file)
    end
  end
  for _, chunk in ipairs(message.unknown) do
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

encodeValue = function(parts, field, value, file)
  local wt = wireTypeOf(field.type)
  if wt < 0 then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT, "unsupported field type " .. field.type))
  end
  encodeVarint(parts, (field.number << 3) | wt)
  if wt == 0 then
    local v
    if field.type == TYPE_SINT32 or field.type == TYPE_SINT64 then
      v = zigzagEncode(valueAsInt(value))
      if field.type == TYPE_SINT32 then v = v & 0xffffffff end
    elseif field.type == TYPE_BOOL then
      v = valueAsInt(value) ~= 0 and 1 or 0
    else
      v = valueAsInt(value)
    end
    encodeVarint(parts, v)
  elseif wt == 1 then
    if field.type == TYPE_DOUBLE then
      local d = type(value) == "number" and value or 0.0
      parts[#parts + 1] = string.pack("<d", d)
    else
      parts[#parts + 1] = string.pack("<I8", valueAsInt(value))
    end
  elseif wt == 5 then
    if field.type == TYPE_FLOAT then
      local f = type(value) == "number" and value or 0.0
      parts[#parts + 1] = string.pack("<f", f)
    else
      parts[#parts + 1] = string.pack("<I4", valueAsInt(value) & 0xffffffff)
    end
  else
    local data
    if field.type == TYPE_STRING and type(value) == "string" then
      data = value
    elseif field.type == TYPE_MESSAGE and type(value) == "table" then
      data = encodeGeneric(file:message(field.typeName), value, file)
    elseif type(value) == "string" then
      data = value
    else
      raise(Status.new(wire.CODE_INVALID_ARGUMENT,
        "value does not match field " .. field.name .. " type " .. field.type))
    end
    encodeVarint(parts, #data)
    parts[#parts + 1] = data
  end
end

local decodeValue
local function decodeGeneric(model, data, file)
  local message = GenericMessage.new(model)
  local reader = PbReader.new(data)
  while true do
    local raw = reader:next()
    if raw == nil then break end
    local field = model.fields[raw.number]
    if field == nil then
      -- Unknown field: retain the raw encoded chunk verbatim.
      message.unknown[#message.unknown + 1] = raw.chunk
    else
      message:add(raw.number, decodeValue(field, raw, file))
    end
  end
  return message
end

decodeValue = function(field, raw, file)
  if raw.wire == 0 then
    if field.type == TYPE_BOOL then return raw.varint ~= 0 end
    if field.type == TYPE_SINT32 or field.type == TYPE_SINT64 then
      return zigzagDecode(raw.varint)
    end
    if field.type == TYPE_INT32 or field.type == TYPE_ENUM then
      local v = raw.varint & 0xffffffff
      if v >= 0x80000000 then v = v - 0x100000000 end
      return v
    end
    return raw.varint
  elseif raw.wire == 1 then
    if field.type == TYPE_DOUBLE then
      return (string.unpack("<d", raw.bytes))
    end
    return (string.unpack("<I8", raw.bytes))
  elseif raw.wire == 5 then
    if field.type == TYPE_FLOAT then
      return (string.unpack("<f", raw.bytes))
    end
    return (string.unpack("<I4", raw.bytes))
  else
    if field.type == TYPE_STRING then
      return raw.bytes
    end
    if field.type == TYPE_MESSAGE then
      return decodeGeneric(file:message(field.typeName), raw.bytes, file)
    end
    return raw.bytes
  end
end

-- ---------------------------------------------------------------------------
-- Descriptor set parsing
-- ---------------------------------------------------------------------------

local parseMessage
local parseService

--- Parse FileDescriptorSet bytes into a FileModel.
local function parseDescriptorSet(data)
  local file = FileModel.new()
  local pendingServices = {}
  local reader = PbReader.new(data)
  while true do
    local f = reader:next()
    if f == nil then break end
    if f.number == 1 then
      local pkg = ""
      local messageTypes, serviceTypes = {}, {}
      local fr = PbReader.new(f.bytes)
      while true do
        local ff = fr:next()
        if ff == nil then break end
        if ff.number == 2 then
          pkg = asString(ff)
        elseif ff.number == 4 then
          messageTypes[#messageTypes + 1] = ff.bytes
        elseif ff.number == 6 then
          serviceTypes[#serviceTypes + 1] = ff.bytes
        end
      end
      for _, m in ipairs(messageTypes) do
        parseMessage(pkg, m, file)
      end
      for _, s in ipairs(serviceTypes) do
        pendingServices[#pendingServices + 1] = { pkg = pkg, bytes = s }
      end
    end
  end
  for _, p in ipairs(pendingServices) do
    parseService(p.pkg, p.bytes, file)
  end
  return file
end

parseMessage = function(prefix, data, file)
  local name = ""
  local rawFields, nested = {}, {}
  local reader = PbReader.new(data)
  while true do
    local f = reader:next()
    if f == nil then break end
    if f.number == 1 then
      name = asString(f)
    elseif f.number == 2 then
      rawFields[#rawFields + 1] = f.bytes
    elseif f.number == 3 then
      nested[#nested + 1] = f.bytes
    end
  end
  local fullName = (prefix == "") and name or (prefix .. "." .. name)
  local model = { fullName = fullName, fields = {}, byName = {} }
  for _, fieldBytes in ipairs(rawFields) do
    local field = { number = 0, name = "", type = 0, repeated = false, typeName = "" }
    local fr = PbReader.new(fieldBytes)
    while true do
      local ff = fr:next()
      if ff == nil then break end
      if ff.number == 1 then
        field.name = asString(ff)
      elseif ff.number == 3 then
        field.number = ff.varint
      elseif ff.number == 4 then
        field.repeated = ff.varint == LABEL_REPEATED
      elseif ff.number == 5 then
        field.type = ff.varint
      elseif ff.number == 6 then
        field.typeName = asString(ff)
      end
    end
    model.byName[field.name] = field.number
    model.fields[field.number] = field
  end
  file.messages["." .. fullName] = model
  for _, nestedBytes in ipairs(nested) do
    parseMessage(fullName, nestedBytes, file)
  end
end

local function kindOf(clientStreaming, serverStreaming)
  if clientStreaming and serverStreaming then return Server.KIND_BIDI end
  if serverStreaming then return Server.KIND_SERVER_STREAMING end
  if clientStreaming then return Server.KIND_CLIENT_STREAMING end
  return Server.KIND_UNARY
end

parseService = function(pkg, data, file)
  local name = ""
  local rawMethods = {}
  local reader = PbReader.new(data)
  while true do
    local f = reader:next()
    if f == nil then break end
    if f.number == 1 then
      name = asString(f)
    elseif f.number == 2 then
      rawMethods[#rawMethods + 1] = f.bytes
    end
  end
  local fullName = (pkg == "") and name or (pkg .. "." .. name)
  local service = { fullName = fullName, methods = {} }
  for _, methodBytes in ipairs(rawMethods) do
    local mname, inputType, outputType = "", "", ""
    local clientStreaming, serverStreaming = false, false
    local mr = PbReader.new(methodBytes)
    while true do
      local mf = mr:next()
      if mf == nil then break end
      if mf.number == 1 then
        mname = asString(mf)
      elseif mf.number == 2 then
        inputType = asString(mf)
      elseif mf.number == 3 then
        outputType = asString(mf)
      elseif mf.number == 5 then
        clientStreaming = mf.varint ~= 0
      elseif mf.number == 6 then
        serverStreaming = mf.varint ~= 0
      end
    end
    service.methods[mname] = {
      name = mname,
      path = "/" .. fullName .. "/" .. mname,
      kind = kindOf(clientStreaming, serverStreaming),
      input = file:message(inputType),
      output = file:message(outputType),
    }
  end
  file.services[fullName] = service
end

-- ---------------------------------------------------------------------------
-- Client / server surfaces
-- ---------------------------------------------------------------------------

--- Adapts a (MessageModel, GenericMessage) pair to the Channel
--- marshal/unmarshal contract.
local BoundMessage = {}
BoundMessage.__index = BoundMessage

function BoundMessage.new(model, generic, file)
  return setmetatable({ model = model, file = file, generic = generic }, BoundMessage)
end

function BoundMessage:marshalDc()
  return encodeGeneric(self.model, self.generic, self.file)
end

function BoundMessage:unmarshalDc(data)
  self.generic = decodeGeneric(self.model, data, self.file)
end

--- Receiving stream of generic responses.
local DynamicStream = {}
DynamicStream.__index = DynamicStream

function DynamicStream.new(stream, output, file)
  return setmetatable({ stream = stream, output = output, file = file }, DynamicStream)
end

--- Next response; raises EndOfStream at end.
function DynamicStream:recv()
  local resp = BoundMessage.new(self.output, GenericMessage.new(self.output), self.file)
  self.stream:recv(resp)
  return resp.generic
end

--- Collect all responses (simplifies scenario drivers).
function DynamicStream:collect()
  local out = {}
  while true do
    local ok, resp = pcall(function() return self:recv() end)
    if not ok then
      if resp == EndOfStream then return out end
      error(resp, 0)
    end
    out[#out + 1] = resp
  end
end

--- Runtime-built client: methods resolve from the FileModel.
local DynamicClient = {}
DynamicClient.__index = DynamicClient

function DynamicClient.new(channel, model)
  return setmetatable({ channel = channel, model = model }, DynamicClient)
end

function DynamicClient:method(serviceName, methodName)
  local svc = self.model:service(serviceName)
  local m = svc.methods[methodName]
  if m == nil then
    raise(Status.new(wire.CODE_INVALID_ARGUMENT,
      "unknown method " .. serviceName .. "/" .. methodName))
  end
  return m
end

function DynamicClient:unary(serviceName, methodName, req, metadata, timeout)
  local m = self:method(serviceName, methodName)
  local resp = BoundMessage.new(m.output, GenericMessage.new(m.output), self.model)
  self.channel:unary(m.path, BoundMessage.new(m.input, req, self.model), resp, metadata, timeout)
  return resp.generic
end

function DynamicClient:serverStream(serviceName, methodName, req, metadata, timeout)
  local m = self:method(serviceName, methodName)
  local stream = self.channel:serverStream(m.path,
    BoundMessage.new(m.input, req, self.model), metadata, timeout)
  return DynamicStream.new(stream, m.output, self.model)
end

function DynamicClient:clientStream(serviceName, methodName, reqs, metadata, timeout)
  local m = self:method(serviceName, methodName)
  local bound = {}
  for i, r in ipairs(reqs) do
    bound[i] = BoundMessage.new(m.input, r, self.model)
  end
  local resp = BoundMessage.new(m.output, GenericMessage.new(m.output), self.model)
  self.channel:clientStreamCall(m.path, bound, resp, metadata, timeout)
  return resp.generic
end

function DynamicClient:bidi(serviceName, methodName, reqs, metadata, timeout)
  local m = self:method(serviceName, methodName)
  local bound = {}
  for i, r in ipairs(reqs) do
    bound[i] = BoundMessage.new(m.input, r, self.model)
  end
  local stream = self.channel:bidi(m.path, bound, metadata, timeout)
  return DynamicStream.new(stream, m.output, self.model)
end

--- Register a runtime-built service on a Server. The handler is a
--- table with unary/serverStream/clientStream/bidi functions taking
--- (ctx, method, req[, send]) / (ctx, method, recv[, send]).
local function registerDynamicService(server, fileModel, serviceName, handler)
  local service = fileModel:service(serviceName)
  local methods = {}
  for _, m in pairs(service.methods) do
    methods[#methods + 1] = {
      name = m.name,
      path = m.path,
      kind = m.kind,
      handler = function(ctx, reqs, sink)
        local function recv()
          return decodeGeneric(m.input, reqs:recvRaw(), fileModel)
        end
        local function send(resp)
          sink(encodeGeneric(m.output, resp, fileModel))
        end
        if m.kind == Server.KIND_UNARY then
          send(handler:unary(ctx, m, recv()))
        elseif m.kind == Server.KIND_SERVER_STREAMING then
          handler:serverStream(ctx, m, recv(), send)
        elseif m.kind == Server.KIND_CLIENT_STREAMING then
          send(handler:clientStream(ctx, m, recv))
        else
          handler:bidi(ctx, m, recv, send)
        end
      end,
    }
  end
  server:registerService({ name = service.fullName, methods = methods })
end

return {
  FileModel = FileModel,
  GenericMessage = GenericMessage,
  DynamicClient = DynamicClient,
  DynamicStream = DynamicStream,
  BoundMessage = BoundMessage,
  parseDescriptorSet = parseDescriptorSet,
  encodeGeneric = encodeGeneric,
  decodeGeneric = decodeGeneric,
  registerDynamicService = registerDynamicService,
  TYPE_DOUBLE = TYPE_DOUBLE,
  TYPE_FLOAT = TYPE_FLOAT,
  TYPE_INT64 = TYPE_INT64,
  TYPE_UINT64 = TYPE_UINT64,
  TYPE_INT32 = TYPE_INT32,
  TYPE_FIXED64 = TYPE_FIXED64,
  TYPE_FIXED32 = TYPE_FIXED32,
  TYPE_BOOL = TYPE_BOOL,
  TYPE_STRING = TYPE_STRING,
  TYPE_GROUP = TYPE_GROUP,
  TYPE_MESSAGE = TYPE_MESSAGE,
  TYPE_BYTES = TYPE_BYTES,
  TYPE_UINT32 = TYPE_UINT32,
  TYPE_ENUM = TYPE_ENUM,
  TYPE_SFIXED32 = TYPE_SFIXED32,
  TYPE_SFIXED64 = TYPE_SFIXED64,
  TYPE_SINT32 = TYPE_SINT32,
  TYPE_SINT64 = TYPE_SINT64,
}
GRPC_RUNTIME_EOF
)

;; Frame dispatch: generated from spec.rkt's frame table, one arm per
;; frame type, spliced into the endpoint body.

(define lua-dispatch-arms
  '((HEADERS . "self:onHeaders(frame.streamId, frame.payload)")
    (DATA . "local input = self.streams[frame.streamId]\n    if input then input:put({ kind = \"data\", payload = frame.payload }) end")
    (TRAILERS . "self:onTerminal(frame.streamId, frame.payload, \"trailers\")")
    (HALF-CLOSE . "local input = self.streams[frame.streamId]\n    if input then input:put({ kind = \"half_close\" }) end")
    (RST . "self:onTerminal(frame.streamId, frame.payload, \"rst\")")))

(define (screaming-lua sym) ; HALF-CLOSE -> HALF_CLOSE
  (string-replace (symbol->string sym) "-" "_"))

(define (emit-lua-dispatch)
  (define arms
    (for/list ([e (in-list frame-table)] [i (in-naturals)])
      (define arm (assoc (first e) lua-dispatch-arms))
      (unless arm (error 'runtime-lua "no Lua dispatch arm for ~a" (first e)))
      (format "~a frame.type == wire.FRAME_~a then\n    ~a\n  "
              (if (= i 0) "if" "elseif")
              (screaming-lua (first e)) (cdr arm))))
  (string-append
   (apply string-append arms)
   "else\n"
   "    -- Unknown frame type: ignore for forward compatibility.\n"
   "  end"))


(define lua-sidecar-body
#<<GRPC_RUNTIME_EOF
--- Transport over the Rust WebRTC-Direct sidecar, host-socket
--- edition. Pure Lua has no stdlib sockets, so the socket is
--- provided by the host application (an embedded interpreter's
--- bindings, a test harness, ...). The host socket contract:
---   socket:sendAll(bytes)        write all bytes
---   socket:recvExact(n) -> bytes read exactly n bytes, or nil at EOF
---   socket:close()
--- The sidecar itself (`webrtc/rust/examples/direct_sidecar.rs`)
--- owns DTLS/SCTP/TURN and bridges one datachannel to a local
--- TCP socket using u32 big-endian length-prefixed messages
--- (one prefix per DataChannel message); this transport adds
--- exactly that framing over the host socket.
---
---   -- Rust sidecar already running:
---   --   direct_sidecar dial --multiaddr /ip4/... --tcp 127.0.0.1:50051
---   local host = require("my_host_socket") -- application-provided
---   local transport = SidecarTransport.connect(
---     function(h, p) return host.connect(h, p) end, "127.0.0.1", 50051)
local statusModule = require("grpcdc.status")
local EndOfStream = statusModule.EndOfStream

local SidecarTransport = {}
SidecarTransport.__index = SidecarTransport

--- Wrap an already-connected host socket.
function SidecarTransport.new(socket)
  return setmetatable({ socket = socket, closedFlag = false }, SidecarTransport)
end

--- Connect through a host-provided connector:
--- connector(host, port) -> socket (see the contract above).
function SidecarTransport.connect(connector, host, port)
  return SidecarTransport.new(connector(host, port))
end

function SidecarTransport:send(data)
  if self.closedFlag then
    error(EndOfStream, 0)
  end
  self.socket:sendAll(string.pack(">I4", #data) .. data)
end

--- Next framed message. Blocks inside the host socket until a
--- full message arrives (real-socket transports block during
--- pump, per the endpoint contract); nil at EOF.
function SidecarTransport:recvMessage()
  local header = self.socket:recvExact(4)
  if header == nil then return nil end
  local len = string.unpack(">I4", header)
  if len == 0 then return "" end
  return self.socket:recvExact(len)
end

function SidecarTransport:close()
  self.closedFlag = true
  if self.socket then self.socket:close() end
end

return {
  SidecarTransport = SidecarTransport,
}
GRPC_RUNTIME_EOF
)

(define (emit-lua-runtime-files)
  (list
   (cons "grpcdc/status.lua" lua-status-body)
   (cons "grpcdc/codec.lua" lua-codec-body)
   (cons "grpcdc/transport.lua" lua-transport-body)
   (cons "grpcdc/endpoint.lua"
         (string-replace lua-endpoint-body "@@FRAME_DISPATCH@@" (emit-lua-dispatch)))
   (cons "grpcdc/channel.lua" lua-channel-body)
   (cons "grpcdc/server.lua" lua-server-body)
   (cons "grpcdc/memory_transport.lua" lua-memory-body)
   (cons "grpcdc/sidecar_transport.lua" lua-sidecar-body)
   (cons "grpcdc/dynamic.lua" lua-dynamic-body)))
