#pragma once

#include <memory>

#include "examples/echo_grpc_dc.hpp"
#include "grpcdc/channel.hpp"

namespace tests {

// Runs the generated BDD scenario table (tests::BddCases) over an
// arbitrary transport-derived channel/client pair. Defined in
// test_bdd.cpp; used by TestBdd (loopback) and TestBddSidecar.
void RunBddScenarios(std::shared_ptr<grpcdc::Channel> channel,
                     echo::EchoGrpcDc::EchoClient& client);

}  // namespace tests
