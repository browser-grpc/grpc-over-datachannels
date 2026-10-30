# Event bus over gRPC

`proto/events.proto` (`grpcdc.events.v1.EventBus`) is a
publish/subscribe event bus defined as a gRPC service and
generated — broker and clients — in every supported
language, browser and native. Publishers attach typed
routing tags (string, int64, double, bool, or any enum by
number); subscribers declare a containment filter and
receive every event whose tags contain all filter pairs.
The broker assigns a global sequence number (1-based, in
publish order) and a wall-clock timestamp to each event.

## Run a demo

```sh
python3 python/examples/eventbus_demo.py
node js/examples/eventbus_demo.js
```

Each demo starts a broker, subscribes with a topic filter,
publishes three events, and prints what the filter admits.
A git-backed broker variant (`eventbus_git`) persists the
event log to a git repository for durable, inspectable
history.

## Service surface

- `Publish(tags, payload, publisher_id)` → broker sequence.
- `Subscribe(filter)` → stream of events matching the
  containment filter (empty filter receives all events).
