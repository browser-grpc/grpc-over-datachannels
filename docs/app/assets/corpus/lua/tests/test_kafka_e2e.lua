-- Kafka proxy end-to-end: generated Lua client -> Rust
-- kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
--
-- Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
-- kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
-- Skipped otherwise, so the plain `make test-lua` run stays
-- broker-free.
local channelModule = require("grpcdc.channel")
local sidecarModule = require("grpcdc.sidecar_transport")
local stubs = require("examples.kafka_grpc_dc")
local messages = require("examples.kafka_messages")
local hostSocket = require("host_socket")
local util = require("test_util")

local M = messages

local function values(records)
  local out = {}
  for i, r in ipairs(records) do
    out[i] = r.value
  end
  return out
end

local function eqList(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

return function()
  local addr = os.getenv("KAFKA_E2E_PROXY_ADDR")
  if addr == nil or addr == "" then
    print("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)")
    return
  end
  local host, port = addr:match("^(.*):(%d+)$")
  local transport = sidecarModule.SidecarTransport.connect(
    function(h, p) return hostSocket.connect(h, p) end, host, tonumber(port))
  local client = stubs.KafkaClient.new(channelModule.Channel.new(transport))

  local counter = 0
  local function createTopic()
    counter = counter + 1
    local topic = string.format("lua-kafka-e2e-%x-%d", os.time(), counter)
    local created = client:createTopics(M.CreateTopicsRequest.new(
      { M.NewTopic.new(topic, 1, 1) }, 15000))
    util.check(#created.results == 1 and created.results[1].errorCode == 0, "create topic")
    local deadline = os.time() + 15
    while true do
      local latest = client:listOffsets(M.ListOffsetsRequest.new(topic, 0, -1))
      if latest.errorCode == 0 then
        break
      end
      util.check(os.time() <= deadline, "topic not visible")
      util.sleep(0.25)
    end
    return topic
  end

  local function produce(topic, vals)
    local offsets = {}
    for i, value in ipairs(vals) do
      local resp = client:produce(M.ProduceRequest.new(topic, 0,
        { M.Record.new("k-" .. value, value) }))
      util.check(resp.errorCode == 0, "produce error " .. tostring(resp.errorCode))
      offsets[i] = resp.baseOffset
    end
    return offsets
  end

  local function consume(topic, offset, count)
    local got = {}
    local stream = client:consume(M.ConsumeRequest.new(topic, 0, offset, count))
    while #got < count do
      local chunk = stream:recv()
      util.check(chunk.errorCode == 0, "consume error " .. tostring(chunk.errorCode))
      for _, rec in ipairs(chunk.records) do
        got[#got + 1] = rec
      end
    end
    stream:close()
    return got
  end

  local topic = createTopic()
  util.check(eqList(produce(topic, { "v0", "v1", "v2" }), { 0, 1, 2 }), "roundtrip offsets")
  local latest = client:listOffsets(M.ListOffsetsRequest.new(topic, 0, -1))
  util.check(latest.offset == 3 and latest.errorCode == 0, "latest offset")
  local got = consume(topic, 0, 3)
  util.check(eqList(values(got), { "v0", "v1", "v2" }), "roundtrip values")
  local keys = {}
  for i, r in ipairs(got) do
    keys[i] = r.key
  end
  util.check(eqList(keys, { "k-v0", "k-v1", "k-v2" }), "roundtrip keys")
  client:deleteTopics(M.DeleteTopicsRequest.new({ topic }))

  topic = createTopic()
  local want = {}
  for i = 0, 9 do
    want[#want + 1] = string.format("seq-%02d", i)
  end
  util.check(eqList(produce(topic, want), { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }), "ordering offsets")
  util.check(eqList(values(consume(topic, 0, 10)), want), "ordering values")
  client:deleteTopics(M.DeleteTopicsRequest.new({ topic }))

  topic = createTopic()
  produce(topic, { "a", "b", "c", "d" })
  util.check(eqList(values(consume(topic, 0, 2)), { "a", "b" }), "resume first")
  util.check(eqList(values(consume(topic, 2, 2)), { "c", "d" }), "resume rest")
  client:deleteTopics(M.DeleteTopicsRequest.new({ topic }))
  print("TestKafkaE2E OK")
end
