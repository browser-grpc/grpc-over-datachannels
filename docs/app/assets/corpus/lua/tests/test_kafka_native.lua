-- Kafka native end-to-end: generated Lua messages ->
-- libkafka_native in-process (no proxy, no gRPC hop).
--
-- Env-gated: set KAFKA_E2E_BROKER=host:port of a broker and
-- LUA_CPATH including kafka_native_core.so. Skipped otherwise.
local KafkaNative = require("grpcdc.kafka_native")
local M = require("examples.kafka_messages")
local util = require("test_util")

return function()
  local broker = os.getenv("KAFKA_E2E_BROKER")
  if broker == nil or broker == "" then
    print("TestKafkaNative SKIP (KAFKA_E2E_BROKER not set)")
    return
  end
  local client = KafkaNative.new(broker, "grpc-dc-kafka-native-lua", M)
  local topic = string.format("lua-kafka-native-%x", os.time())
  local ok, err = pcall(function()
    local created = client:createTopics(M.CreateTopicsRequest.new(
      { M.NewTopic.new(topic, 1, 1) }, 15000))
    util.check(#created.results == 1 and created.results[1].errorCode == 0, "create topic")

    local deadline = os.time() + 15
    while true do
      local meta = client:metadata(M.MetadataRequest.new({ topic }))
      local found = false
      for _, t in ipairs(meta.topics) do
        if t.name == topic and #t.partitions > 0 then found = true end
      end
      if found then break end
      util.check(os.time() <= deadline, "topic not visible")
      util.sleep(0.25)
    end

    local produced = client:produce(M.ProduceRequest.new(topic, 0, {
      M.Record.new("", "one"),
      M.Record.new("", "two"),
      M.Record.new("", "three"),
    }))
    util.check(produced.errorCode == 0, "produce: " .. tostring(produced.errorCode))

    local values = {}
    local nextChunk = client:consume(M.ConsumeRequest.new(topic, 0, -2, 10, 2000))
    while #values < 3 do
      local chunk = nextChunk()
      if chunk == nil then break end
      util.check(chunk.errorCode == 0, "consume error: " .. tostring(chunk.errorCode))
      for _, r in ipairs(chunk.records) do
        values[#values + 1] = r.value
      end
    end
    util.check(#values == 3 and values[1] == "one" and values[2] == "two" and values[3] == "three",
      "values: " .. table.concat(values, ","))

    local latest = client:listOffsets(M.ListOffsetsRequest.new(topic, 0, -1))
    util.check(latest.errorCode == 0 and latest.offset == 3,
      "listOffsets: " .. tostring(latest.errorCode) .. " " .. tostring(latest.offset))
    print("TestKafkaNative OK")
  end)
  pcall(function()
    client:deleteTopics(M.DeleteTopicsRequest.new({ topic }))
  end)
  client:close()
  if not ok then error(err) end
end
