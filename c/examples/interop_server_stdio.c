/* Interop harness: the generated C TestService server over
   stdio. Direction-B oracle tests spawn this and drive it with
   the official grpc-java / grpc-go interop clients through the
   bridge (oracle/bridge.mjs http2-to-dc). */
#include <stdio.h>
#include <unistd.h>

#include "interop/interop_service_impl.h"
#include "stdio_transport.h"

int main(void) {
    stdio_transport stdio;
    stdio_transport_init(&stdio, STDIN_FILENO, STDOUT_FILENO);
    grpcdc_transport transport = stdio_transport_iface(&stdio);
    grpcdc_server *server = grpcdc_server_new();
    TestServiceServer_register(server, &isvc_test_service);
    OpenRcaServiceServer_register(server, &isvc_open_rca);
    grpcdc_status st = grpcdc_server_serve(server, &transport);
    fprintf(stderr, "server exit: %d %s\n", st.code, st.message);
    grpcdc_server_free(server);
    return 0;
}
