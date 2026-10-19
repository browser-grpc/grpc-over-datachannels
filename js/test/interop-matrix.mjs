// Cross-language interop matrix: every language's stdio Echo
// client against every language's stdio Echo server (15 x 15
// ordered pairs), connected by a raw byte pump. Both harnesses
// speak the same length-prefixed stdio transport and print one
// stderr line per call shape (stdout carries frames), so a pair
// passes when the client exits 0 with the canonical lines:
//   unary=echo: hello
//   server_stream=tick#0,tick#1,tick#2
//   client_stream=a+b+c
//   bidi=x,y
// Builds each harness once (same commands as the per-language
// Makefile recipes). Focus with MATRIX_CLIENTS / MATRIX_SERVERS
// (comma-separated language names). Run via `make
// test-interop-matrix`.

import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const SWIFTC = process.env.SWIFTC || "swiftc";
const KOTLINC = process.env.KOTLINC || "kotlinc";
const DART = process.env.DART || "dart";
const LUA = process.env.LUA || "lua";
const RUBY = process.env.RUBY || "ruby";
const PHP = process.env.PHP || "php";
const SCALAC = process.env.SCALAC || "scalac";
const SCALA3_HOME = process.env.SCALA3_HOME || "/usr/local/scala3";
const SCALA_LIBS = `${SCALA3_HOME}/lib/scala3-library_3-3.3.6.jar:${SCALA3_HOME}/lib/scala-library-2.13.16.jar`;
const CXX = process.env.CXX || "g++";

const LANGS = {
  go: {
    build: "cd go && mkdir -p build && go build -o build/echo_server_stdio ./examples/echo_server_stdio && go build -o build/echo_client_stdio ./examples/echo_client_stdio",
    client: ["go/build/echo_client_stdio"],
    server: ["go/build/echo_server_stdio"],
  },
  rust: {
    build: "cd rust && cargo build --examples",
    client: ["rust/target/debug/examples/echo_client_stdio"],
    server: ["rust/target/debug/examples/echo_server_stdio"],
  },
  python: {
    build: null,
    client: ["python3", "python/examples/echo_client_stdio.py"],
    server: ["python3", "python/examples/echo_server_stdio.py"],
  },
  java: {
    build: "cd java && mkdir -p build && javac -encoding UTF-8 -d build $(find grpcdc examples -name '*.java')",
    client: ["java", "-cp", "java/build", "echo.EchoClientStdio"],
    server: ["java", "-cp", "java/build", "echo.EchoServerStdio"],
  },
  csharp: {
    build: "cd csharp && dotnet build examples/EchoServerStdio/EchoServerStdio.csproj --nologo -v q && dotnet build examples/EchoClientStdio/EchoClientStdio.csproj --nologo -v q",
    client: ["dotnet", "csharp/examples/EchoClientStdio/bin/Debug/net8.0/EchoClientStdio.dll"],
    server: ["dotnet", "csharp/examples/EchoServerStdio/bin/Debug/net8.0/EchoServerStdio.dll"],
  },
  cpp: {
    build: `mkdir -p cpp/build && ${CXX} -std=c++17 -pthread -O1 -Icpp -I. cpp/examples/echo_server_stdio.cpp -o cpp/build/echo_server_stdio && ${CXX} -std=c++17 -pthread -O1 -Icpp -I. cpp/examples/echo_client_stdio.cpp -o cpp/build/echo_client_stdio`,
    client: ["cpp/build/echo_client_stdio"],
    server: ["cpp/build/echo_server_stdio"],
  },
  swift: {
    build: `mkdir -p swift/build && ${SWIFTC} -swift-version 5 -O swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/EchoServerStdio/main.swift -o swift/build/echo_server_stdio && ${SWIFTC} -swift-version 5 -O swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/EchoClientStdio/main.swift -o swift/build/echo_client_stdio`,
    client: ["swift/build/echo_client_stdio"],
    server: ["swift/build/echo_server_stdio"],
  },
  kotlin: {
    build: `${KOTLINC} -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/EchoServerStdio/Main.kt -d kotlin/build/echo_server_stdio.jar && ${KOTLINC} -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/EchoClientStdio/Main.kt -d kotlin/build/echo_client_stdio.jar`,
    client: ["java", "-jar", "kotlin/build/echo_client_stdio.jar"],
    server: ["java", "-jar", "kotlin/build/echo_server_stdio.jar"],
  },
  dart: {
    build: `mkdir -p dart/build && ${DART} compile exe dart/examples/EchoServerStdio/main.dart -o dart/build/echo_server_stdio && ${DART} compile exe dart/examples/EchoClientStdio/main.dart -o dart/build/echo_client_stdio`,
    client: ["dart/build/echo_client_stdio"],
    server: ["dart/build/echo_server_stdio"],
  },
  zig: {
    build: `cd zig && ${process.env.ZIG || "zig"} build --prefix build`,
    client: ["zig/build/bin/echo_client_stdio"],
    server: ["zig/build/bin/echo_server_stdio"],
  },
  c: {
    build: "mkdir -p c/build && gcc -std=c99 -Wall -Wextra -pthread -O1 -Ic -Ic/examples c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/examples/stdio_transport.c c/examples/echo_server_stdio.c -o c/build/echo_server_stdio && gcc -std=c99 -Wall -Wextra -pthread -O1 -Ic -Ic/examples c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/examples/stdio_transport.c c/examples/echo_client_stdio.c -o c/build/echo_client_stdio",
    client: ["c/build/echo_client_stdio"],
    server: ["c/build/echo_server_stdio"],
  },
  lua: {
    build: null,
    client: [LUA, "lua/examples/echo_client_stdio.lua"],
    server: [LUA, "lua/examples/echo_server_stdio.lua"],
  },
  ruby: {
    build: null,
    client: [RUBY, "ruby/examples/echo_client_stdio.rb"],
    server: [RUBY, "ruby/examples/echo_server_stdio.rb"],
  },
  php: {
    build: null,
    client: [PHP, "php/examples/echo_client_stdio.php"],
    server: [PHP, "php/examples/echo_server_stdio.php"],
  },
  scala: {
    build: `mkdir -p scala/build && ${SCALAC} -d scala/build/echo_server_stdio.jar scala/grpcdc/*.scala scala/examples/EchoMessages.scala scala/examples/EchoGrpcDc.scala scala/examples/EchoServiceImpl.scala scala/examples/StdioTransport.scala scala/examples/EchoServerStdio/Main.scala && ${SCALAC} -d scala/build/echo_client_stdio.jar scala/grpcdc/*.scala scala/examples/EchoMessages.scala scala/examples/EchoGrpcDc.scala scala/examples/StdioTransport.scala scala/examples/EchoClientStdio/Main.scala`,
    client: ["java", "-cp", "scala/build/echo_client_stdio.jar:" + SCALA_LIBS, "echo.EchoClientStdio"],
    server: ["java", "-cp", "scala/build/echo_server_stdio.jar:" + SCALA_LIBS, "echo.EchoServerStdio"],
  },
};

const EXPECTED = [
  "unary=echo: hello",
  "server_stream=tick#0,tick#1,tick#2",
  "client_stream=a+b+c",
  "bidi=x,y",
  "metadata=echo: hello [meta]",
];

// Deadline waiver: the Lua and PHP clients' stdio transports
// block inside recvMessage, and their deadlines are only
// checked between messages (the documented cooperative-
// transport caveat in SPEC.md), so a slow-call deadline cannot
// fire mid-wait over stdio. Lua and PHP clients may report
// "deadline=no error"; every other client must report 4.
const DEADLINE_WAIVED = new Set(["lua", "php"]);

function hasDeadline(lines, clientLang) {
  if (lines.includes("deadline=4")) return true;
  return DEADLINE_WAIVED.has(clientLang) && lines.includes("deadline=no error");
}

// The fail call's line format varies per language (status
// name vs exception text); any error_case line carrying the
// INVALID_ARGUMENT name or the canonical message counts.
function hasErrorCase(lines) {
  return lines.some(
    (line) =>
      line.startsWith("error_case=") &&
      (line.includes("INVALID") || line.includes("asked to fail")),
  );
}

function runPair(clientLang, serverLang) {
  return new Promise((resolve) => {
    const clientCmd = LANGS[clientLang].client;
    const serverCmd = LANGS[serverLang].server;
    const server = spawn(serverCmd[0], serverCmd.slice(1), { cwd: ROOT });
    const client = spawn(clientCmd[0], clientCmd.slice(1), { cwd: ROOT });
    let stderr = "";
    let finishing = false;
    const linesComplete = () => {
      const lines = stderr.split("\n").map((s) => s.trim());
      return EXPECTED.every((line) => lines.includes(line)) && hasErrorCase(lines) && hasDeadline(lines, clientLang);
    };
    client.stderr.on("data", (d) => {
      stderr += d;
      // Once every call shape has reported, EOF both pipes so
      // the harnesses' reader threads can shut down (the Python
      // client otherwise aborts at interpreter finalization).
      if (!finishing && linesComplete()) {
        finishing = true;
        client.stdout.unpipe(server.stdin);
        server.stdout.unpipe(client.stdin);
        client.stdin.end();
        server.stdin.end();
        setTimeout(() => { client.kill("SIGKILL"); server.kill("SIGKILL"); }, 5000).unref();
      }
    });
    server.stderr.on("data", () => {});
    client.stdout.pipe(server.stdin);
    server.stdout.pipe(client.stdin);
    const timer = setTimeout(() => {
      client.kill("SIGKILL");
      server.kill("SIGKILL");
      resolve({ ok: false, why: "timeout" });
    }, 60000);
    client.on("error", (err) => {
      clearTimeout(timer);
      server.kill("SIGKILL");
      resolve({ ok: false, why: String(err) });
    });
    client.on("exit", (code) => {
      clearTimeout(timer);
      server.kill("SIGKILL");
      const lines = stderr.split("\n").map((s) => s.trim()).filter(Boolean);
      const missing = EXPECTED.filter((line) => !lines.includes(line));
      if (!hasErrorCase(lines)) missing.push("error_case=<INVALID_ARGUMENT>");
      if (!hasDeadline(lines, clientLang)) missing.push("deadline=4");
      if (missing.length) resolve({ ok: false, why: `missing ${missing.join(", ")} in: ${lines.join(" | ")}` });
      else if (code !== 0 && !finishing) resolve({ ok: false, why: `client exit ${code}: ${lines.join(" | ")}` });
      else resolve({ ok: true });
    });
  });
}

const pick = (env, all) =>
  env ? env.split(",").map((s) => s.trim()).filter((s) => all.includes(s)) : all;
const names = Object.keys(LANGS);
const clients = pick(process.env.MATRIX_CLIENTS, names);
const servers = pick(process.env.MATRIX_SERVERS, names);

for (const name of new Set([...clients, ...servers])) {
  const { build } = LANGS[name];
  if (build) {
    console.log(`building ${name} stdio harnesses`);
    execSync(build, { cwd: ROOT, stdio: "inherit", shell: "/bin/bash" });
  }
  const exe = LANGS[name].client[0];
  if (!exe.includes("/") || existsSync(join(ROOT, exe))) continue;
  if (exe.includes("/")) throw new Error(`${name} client binary missing after build: ${exe}`);
}

let failures = 0;
for (const clientLang of clients) {
  for (const serverLang of servers) {
    const result = await runPair(clientLang, serverLang);
    if (result.ok) {
      console.log(`ok ${clientLang} -> ${serverLang}`);
    } else {
      failures++;
      console.log(`FAIL ${clientLang} -> ${serverLang}: ${result.why}`);
    }
  }
}
console.log(`interop matrix: ${clients.length * servers.length - failures}/${clients.length * servers.length} pairs passed`);
if (failures) process.exit(1);
