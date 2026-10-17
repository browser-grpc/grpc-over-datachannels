local scriptDir = arg[0]:match("^(.*)/lua/examples/[^/]+$") or "."
package.path = scriptDir .. "/lua/?.lua;" .. package.path

local channelModule = require("grpcdc.channel")
local statusModule = require("grpcdc.status")
local wire = require("grpcdc.wire")
local stdioModule = require("examples.stdio_transport")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")

--- Interop harness: the Lua echo client over stdio. Prints one line
--- per call shape to stderr (stdout carries frames) and exits
--- non-zero on any failure.
local EchoRequest = messages.EchoRequest
local EndOfStream = statusModule.EndOfStream

local function req(message, count)
  return EchoRequest.new(message, count)
end

local function run()
  local transport = stdioModule.StdioTransport.new(io.stdin, io.stdout)
  local client = stubs.EchoClient.new(channelModule.Channel.new(transport))

  local unary = client:unary(req("hello", 0))
  io.stderr:write("unary=" .. unary.message .. "\n")

  local stream = client:serverStream(req("tick", 3))
  local ticks = {}
  while true do
    local ok, resp = pcall(function() return stream:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp, 0)
    end
    ticks[#ticks + 1] = resp.message .. "#" .. resp.index
  end
  io.stderr:write("server_stream=" .. table.concat(ticks, ",") .. "\n")

  local joined = client:clientStream({ req("a", 0), req("b", 0), req("c", 0) })
  io.stderr:write("client_stream=" .. joined.message .. "\n")

  local bidi = client:bidi({ req("x", 0), req("y", 0) })
  local echoed = {}
  while true do
    local ok, resp = pcall(function() return bidi:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp, 0)
    end
    echoed[#echoed + 1] = resp.message
  end
  io.stderr:write("bidi=" .. table.concat(echoed, ",") .. "\n")

  local md = client:unary(req("hello", 0), { ["x-echo"] = "meta" })
  io.stderr:write("metadata=" .. md.message .. "\n")

  local slowOk, slowErr = pcall(function()
    return client:unary(EchoRequest.new("slow", 0, 400), nil, 0.05)
  end)
  if slowOk then
    io.stderr:write("deadline=no error\n")
  else
    io.stderr:write("deadline=" .. tostring(slowErr.code) .. "\n")
  end

  local ok, err = pcall(function() return client:unary(req("fail", 0)) end)
  if ok then
    io.stderr:write("error_case=no error\n")
    os.exit(1)
  end
  io.stderr:write("error_case=" .. tostring(err) .. "\n")
end

local ok, err = pcall(run)
if not ok then
  io.stderr:write("error: " .. tostring(err) .. "\n")
  os.exit(1)
end
