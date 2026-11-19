// Shared loader for the Rust cores (SCTP/DTLS/ICE
// compiled to Wasm): peer.js and direct.js both default
// to them. Loading is async, cached, and resolves the
// generated glue under browser-test/dc_*_gen (wasm-pack
// output, gitignored build artifacts).
import { readFileSync } from "node:fs";

let rustCoresPromise = null;

export function loadRustCores() {
  if (!rustCoresPromise) {
    rustCoresPromise = (async () => {
      const [{ loadSctpWasm }, { loadDtlsWasm }, { loadIceWasm }] = await Promise.all([
        import("./sctp_wasm.js"),
        import("./dtls_wasm.js"),
        import("./ice_wasm.js"),
      ]);
      const bytes = (rel) => readFileSync(new URL(rel, import.meta.url));
      const [sctp, dtls, ice] = await Promise.all([
        loadSctpWasm(bytes("../../browser-test/dc_sctp_gen/dc_sctp_wasm_bg.wasm")),
        loadDtlsWasm(bytes("../../browser-test/dc_dtls_gen/dc_dtls_wasm_bg.wasm")),
        loadIceWasm(bytes("../../browser-test/dc_ice_gen/dc_ice_wasm_bg.wasm")),
      ]);
      return {
        Association: sctp.Association,
        DtlsConnection: dtls.DtlsConnection,
        IceAgent: ice.IceAgent,
        assocFactory: (role, localPort) =>
          role === "client"
            ? sctp.Association.newClient(localPort)
            : sctp.Association.newServer(localPort),
        dtlsFactory: (io, config, role) =>
          role === "client"
            ? dtls.DtlsConnection.connect(io, config)
            : dtls.DtlsConnection.accept(io, config),
        iceAgentFactory: (controlling) => new ice.IceAgent(controlling),
      };
    })();
  }
  return rustCoresPromise;
}
