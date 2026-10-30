// Shared fake TURN server as a standalone process, so the
// cross-stack webrtc matrix can point native harnesses (Go,
// Rust) and in-process JS peers at one allocation service.
// Prints the server address ("127.0.0.1:port") on stdout and
// serves until killed. Test-only; not a TURN implementation
// for anything else.

import { fakeTurnServer } from "../webrtc/js/test/fake_turn.js";

const turn = await fakeTurnServer();
console.log(turn.server);
process.on("SIGTERM", () => turn.close());
process.on("SIGINT", () => turn.close());
