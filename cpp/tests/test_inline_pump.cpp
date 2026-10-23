// Single-threaded inline pump mode: an endpoint whose transport
// offers TryRecv runs without read/dispatch threads — stream
// waits pump the transport themselves. This is the mode the
// native WASM (wasm32-wasi, one thread) client/server use.
// The client-inline half talks to an ordinary threaded server;
// the server-inline half is driven by explicit PollOnce calls
// while a threaded client call runs in the background.

#include <chrono>
#include <condition_variable>
#include <deque>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/echo_service_impl.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/server.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

using echo::EchoGrpcDc;
using echo::EchoRequest;
using echo::EchoResponse;
using std::chrono::milliseconds;

EchoRequest Req(const std::string& message, std::int32_t count) {
  EchoRequest r; r.message = message; r.count = count; return r;
}

struct SharedQueue {
  void Add(grpcdc::Bytes data) {
    {
      std::lock_guard<std::mutex> lock(mu);
      queue.push_back(std::move(data));
    }
    cv.notify_all();
  }
  grpcdc::Bytes Take() {
    std::unique_lock<std::mutex> lock(mu);
    cv.wait(lock, [&] { return !queue.empty() || closed; });
    if (queue.empty()) throw grpcdc::EndOfStream();
    grpcdc::Bytes out = std::move(queue.front());
    queue.pop_front();
    return out;
  }
  // Bounded wait so an inline pump loop re-checks deadlines
  // instead of busy-spinning (the WASM mailbox waits 50 ms).
  grpcdc::Transport::TryRecvResult TryTake(grpcdc::Bytes& out) {
    std::unique_lock<std::mutex> lock(mu);
    if (!cv.wait_for(lock, milliseconds(2),
                     [&] { return !queue.empty() || closed; })) {
      return grpcdc::Transport::TryRecvResult::kWouldBlock;
    }
    if (queue.empty()) return grpcdc::Transport::TryRecvResult::kClosed;
    out = std::move(queue.front());
    queue.pop_front();
    return grpcdc::Transport::TryRecvResult::kMessage;
  }
  void Close() {
    {
      std::lock_guard<std::mutex> lock(mu);
      closed = true;
    }
    cv.notify_all();
  }
  std::mutex mu;
  std::condition_variable cv;
  std::deque<grpcdc::Bytes> queue;
  bool closed = false;
};

class QueueTransport : public grpcdc::Transport {
 public:
  QueueTransport(std::shared_ptr<SharedQueue> inbox,
                 std::shared_ptr<SharedQueue> outbox, bool inline_pump)
      : inbox_(std::move(inbox)),
        outbox_(std::move(outbox)),
        inline_pump_(inline_pump) {}

  void Send(const grpcdc::Bytes& data) override {
    if (closed_) throw grpcdc::EndOfStream();
    outbox_->Add(data);
  }
  grpcdc::Bytes Recv() override { return inbox_->Take(); }
  void Close() override {
    closed_ = true;
    inbox_->Close();
  }
  bool HasTryRecv() const override { return inline_pump_; }
  grpcdc::Transport::TryRecvResult TryRecv(grpcdc::Bytes& out) override {
    return inbox_->TryTake(out);
  }

 private:
  std::shared_ptr<SharedQueue> inbox_;
  std::shared_ptr<SharedQueue> outbox_;
  bool inline_pump_;
  bool closed_ = false;
};

// first: client-side transport (inline per flag), second: server side.
std::pair<std::shared_ptr<grpcdc::Transport>, std::shared_ptr<grpcdc::Transport>>
QueuePair(bool client_inline, bool server_inline) {
  auto a_to_b = std::make_shared<SharedQueue>();
  auto b_to_a = std::make_shared<SharedQueue>();
  return {std::make_shared<QueueTransport>(b_to_a, a_to_b, client_inline),
          std::make_shared<QueueTransport>(a_to_b, b_to_a, server_inline)};
}

class SlowEcho : public echo::EchoServiceImpl {
 public:
  EchoResponse Unary(grpcdc::Endpoint::CallContext& ctx, EchoRequest& req) override {
    std::this_thread::sleep_for(milliseconds(400));
    return echo::EchoServiceImpl::Unary(ctx, req);
  }
};

void RunClientInline() {
  auto pair = QueuePair(true, false);
  auto server = std::make_shared<grpcdc::Server>();
  static SlowEcho impl;
  EchoGrpcDc::RegisterEchoServer(*server, impl);
  server->ServeTransport(pair.second);
  auto channel = std::make_shared<grpcdc::Channel>(pair.first);
  Check(channel->endpoint()->inline_pump(), "client endpoint is inline");
  EchoGrpcDc::EchoClient client(channel);

  // Generous deadline first (SlowEcho sleeps 400 ms per unary).
  EchoResponse unary = client.Unary(Req("hello", 0), nullptr, std::chrono::seconds(5));
  Check(unary.message == "echo: hello", "inline unary: " + unary.message);

  auto stream = client.ServerStream(Req("tick", 3));
  std::vector<std::int32_t> indexes;
  while (true) {
    try {
      indexes.push_back(stream.Recv().index);
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
  }
  Check((indexes == std::vector<std::int32_t>{0, 1, 2}), "inline server stream");

  EchoResponse joined = client.ClientStream({Req("a", 0), Req("b", 0)});
  Check(joined.message == "a+b", "inline client stream: " + joined.message);

  auto bidi = client.Bidi({Req("x", 0), Req("y", 0)});
  std::vector<std::string> echoed;
  while (true) {
    try {
      echoed.push_back(bidi.Recv().message);
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
  }
  Check((echoed == std::vector<std::string>{"x", "y"}), "inline bidi");

  auto start = std::chrono::steady_clock::now();
  bool timed_out = false;
  try {
    (void)client.Unary(Req("hello", 0), nullptr, milliseconds(50));
  } catch (const grpcdc::StatusException& e) {
    timed_out = true;
    Check(e.code() == grpcdc::wire::kCodeDeadlineExceeded, "inline deadline code");
  }
  Check(timed_out, "inline deadline raised");
  Check(std::chrono::steady_clock::now() - start < milliseconds(350),
        "inline deadline fires fast");
}

void RunServerInline() {
  auto pair = QueuePair(false, true);
  auto server = std::make_shared<grpcdc::Server>();
  static echo::EchoServiceImpl impl;
  EchoGrpcDc::RegisterEchoServer(*server, impl);
  auto server_endpoint = server->ServeTransport(pair.second);
  Check(server_endpoint->inline_pump(), "server endpoint is inline");
  auto channel = std::make_shared<grpcdc::Channel>(pair.first);
  EchoGrpcDc::EchoClient client(channel);

  // The threaded client blocks in Recv; this thread pumps the
  // inline server endpoint until the call settles.
  auto unary = std::async(std::launch::async, [&] {
    return client.Unary(Req("hello", 0), nullptr, std::chrono::seconds(5));
  });
  while (unary.wait_for(milliseconds(0)) != std::future_status::ready) {
    server_endpoint->PollOnce();
  }
  Check(unary.get().message == "echo: hello", "inline server unary");

  auto joined = std::async(std::launch::async, [&] {
    return client.ClientStream({Req("a", 0), Req("b", 0)}, nullptr,
                                std::chrono::seconds(5));
  });
  while (joined.wait_for(milliseconds(0)) != std::future_status::ready) {
    server_endpoint->PollOnce();
  }
  Check(joined.get().message == "a+b", "inline server client stream");
}

}  // namespace

void TestInlinePump() {
  RunClientInline();
  RunServerInline();
  std::fprintf(stderr, "TestInlinePump OK\n");
}

}  // namespace tests
