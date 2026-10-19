/* Interop harness: the C echo server over stdio. Stdout carries
   frames; diagnostics go to stderr. */
#include <stdio.h>
#include <unistd.h>

#include "echo_service_impl.h"
#include "stdio_transport.h"

int main(void) {
    stdio_transport stdio;
    stdio_transport_init(&stdio, STDIN_FILENO, STDOUT_FILENO);
    grpcdc_transport transport = stdio_transport_iface(&stdio);
    grpcdc_server *server = grpcdc_server_new();
    EchoServer_register(server, &echo_server_impl);
    grpcdc_status st = grpcdc_server_serve(server, &transport);
    fprintf(stderr, "server exit: %d %s\n", st.code, st.message);
    grpcdc_server_free(server);
    return 0;
}
