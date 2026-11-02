#!/usr/bin/env racket
#lang racket

;; Public release exporter: materializes the browser-grpc
;; public tree (generated runtimes, stubs, docs, and the
;; JS-fallback browser app) from this private repo.
;;
;; The Racket/recursive-metaprogramming sources never cross:
;; the export is built only from `git ls-files` under the
;; allowlisted prefixes below (so build output, which is
;; untracked, is excluded by construction), the Racket
;; webapp path (plugins/*.rkt, racket-web) is dropped, and a
;; leak gate fails the export if any Racket source slips in.
;;
;; Usage:
;;   racket racket/releasegen.rkt [--version vX.Y.Z] [--out DIR]
;; Defaults: version from `git describe --tags --abbrev=0`,
;; out = release/browser-grpc.

(require racket/file
         racket/string)

(define args (vector->list (current-command-line-arguments)))
(define (arg-value flag default)
  (define idx (index-of args flag))
  (if idx (list-ref args (add1 idx)) default))

(define (sh cmd)
  (define out (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port (open-output-nowhere)])
    (unless (system cmd) (error 'releasegen "command failed: ~a" cmd)))
  (string-trim (get-output-string out)))

(define version
  (arg-value "--version" (sh "git describe --tags --abbrev=0")))
(define out-dir (arg-value "--out" "release/browser-grpc"))
(define kafka-proxy-out (arg-value "--kafka-proxy-out" ""))
(define eventbus-out (arg-value "--eventbus-out" ""))
(define examples-out (arg-value "--examples-out" ""))
(define source-commit (sh "git rev-parse HEAD"))

;; ---------------------------------------------------------------------------
;; Manifest: the only repo paths that may cross, and the
;; language table for the generated README.
;; ---------------------------------------------------------------------------

(define languages
  '(("C" . "c") ("C++" . "cpp") ("C#" . "csharp") ("Dart" . "dart")
    ("Go" . "go") ("Java" . "java") ("JavaScript" . "js")
    ("Kotlin" . "kotlin") ("Lua" . "lua") ("PHP" . "php")
    ("Python" . "python") ("Ruby" . "ruby") ("Rust" . "rust")
    ("Scala" . "scala") ("Swift" . "swift") ("Zig" . "zig")))

(define allow-prefixes
  (append (map cdr languages)
          '("webrtc" "wasm" "proto" "fixtures" "examples")))

;; QUICKSTART step 2 lives in browser-test/, which is otherwise
;; private test tooling (and carries built wasm/binaries); export
;; just the sample so the public quickstart command runs as-is.
(define allow-files-extra '("browser-test/native_step2.mjs"))

(define allow-files
  '("LICENSE" "NOTICE" "GENERATED-CODE-LICENSE.md" "CHANGELOG.md"
    "BDD.md" "SPEC.md"))

;; Never exported even under an allowed prefix.
(define (denied? rel)
  (or (string-suffix? rel ".rkt")
      (regexp-match? #rx"(^|/)(target|build|node_modules)(/|$)" rel)
      (regexp-match? #rx"^wasm/(kotlin/build|swift/build)" rel)))

(define (allowed? rel)
  (and (not (denied? rel))
       (or (member rel allow-files)
           (member rel allow-files-extra)
           (for/or ([p (in-list allow-prefixes)])
             (string-prefix? rel (string-append p "/"))))))

;; ---------------------------------------------------------------------------
;; Copy the tracked tree.
;; ---------------------------------------------------------------------------

(when (directory-exists? out-dir) (delete-directory/files out-dir))
(make-directory* out-dir)

(define tracked
  (filter (lambda (s) (not (string=? s "")))
          (string-split (sh "git ls-files") "\n")))

(define (copy-in rel)
  (define dest (build-path out-dir rel))
  (make-directory* (path-only dest))
  (copy-file rel dest #t))

(define exported
  (for/list ([rel (in-list tracked)] #:when (allowed? rel))
    (copy-in rel)
    rel))

;; Go modules: the private tree keeps a `replace` pointing at
;; the sibling webrtc module (monorepo layout). The published
;; export must require it by version instead — module proxy
;; resolution honors no replace directives. release-push.sh
;; tags go/<version> and webrtc/go/<version> on the export so
;; both module paths resolve at this release (pkg.go.dev).
(let ([mod (build-path out-dir "go/go.mod")])
  (when (file-exists? mod)
    (define kept
      (for/list ([line (in-list (string-split (file->string mod) "\n"))]
                 #:unless (or (string-prefix? line "replace ")
                              (string=? line "")))
        (string-replace line " v0.0.0" (string-append " " version))))
    (call-with-output-file mod #:exists 'replace
      (lambda (out)
        (display (string-join kept "\n") out)
        (newline out)))))

;; Go workspace for in-repo builds: with the replace removed,
;; building inside a clone (browser-test's Go harness, the
;; docker images' tidy step) would resolve webrtc/go from the
;; module proxy at this version, which races the release's
;; own go/ tags. A workspace pins both modules to the tree.
(call-with-output-file (build-path out-dir "go.work")
  #:exists 'replace
  (lambda (out)
    (display "go 1.24\n\nuse ./go\n\nuse ./webrtc/go\n" out)))

;; NuGet: the C# runtime's PackageId/metadata live in the source
;; Grpcdc.csproj, but the package version tracks the release.
;; Inject it (plus a package readme, copied from the generated
;; per-language readme) into the exported project only, so the
;; private tree keeps building without release state.
(let ([csproj (build-path out-dir "csharp/grpcdc/Grpcdc.csproj")]
      [readme-dst (build-path out-dir "csharp/grpcdc/README.md")]
      [pkg-version (regexp-replace #rx"^v" version "")])
  (when (file-exists? csproj)
    ;; Minimal package readme (the full per-language readme is
    ;; generated later in this run, too late to copy here).
    (call-with-output-file readme-dst #:exists 'replace
      (lambda (out)
        (display
         "# GrpcDc\n\ngRPC over WebRTC DataChannels for .NET — dependency-free generated gRPC clients and servers.\n\nSee https://browser-grpc.github.io/grpc-over-datachannels/ and the `csharp/README.md` in the repository.\n"
         out)))
    (define text (file->string csproj))
    (call-with-output-file csproj #:exists 'replace
      (lambda (out)
        (display
         (string-replace
          text
          "  </PropertyGroup>"
          (string-append
           "    <Version>" pkg-version "</Version>\n"
           "    <PackageReadmeFile>README.md</PackageReadmeFile>\n"
           "  </PropertyGroup>\n"
           "  <ItemGroup>\n"
           "    <None Include=\"README.md\" Pack=\"true\" PackagePath=\"\\\" />\n"
           "  </ItemGroup>"))
         out)))))

;; ---------------------------------------------------------------------------
;; Browser app (docs/app): fallback mode only — no .rkt
;; plugins, no racket-web assets. The app engages its
;; byte-identical JS fallback generators automatically when
;; cross-origin isolation is absent (GitHub Pages).
;; ---------------------------------------------------------------------------

(define app-files
  '("index.html" "app.js" "starters.mjs" "style.css" "protoc-gen-grpc-dc.mjs"
    "favicon.ico" "favicon-32.png" "favicon-16.png"
    "apple-touch-icon.png"))

;; Generated by `make webapp-assets` (a release-public
;; prerequisite): copied from the working tree, not git.
(define app-dirs
  '("webapp/gen" "webapp/assets/runtime" "webapp/assets/corpus"
    "webapp/assets/testdata"))

(define app-assets
  '("webapp/assets/echo.proto" "webapp/assets/protocompile.wasm"
    "webapp/assets/wasm_exec.js"))

(define (copy-app rel)
  (define dest (build-path out-dir "docs/app" rel))
  (make-directory* (path-only dest))
  (copy-file (build-path "webapp" rel) dest #t))

(for ([rel (in-list app-files)]) (copy-app rel))
(for ([rel (in-list app-assets)])
  (copy-app (build-path "assets" (path->string (file-name-from-path rel)))))
(for ([dir (in-list app-dirs)])
  (for ([p (in-list (find-files file-exists? dir))])
    (copy-app (path->string (find-relative-path "webapp" p)))))

;; ---------------------------------------------------------------------------
;; Browser test harness (trimmed): the Playwright suites that
;; run against the exported sources, minus build outputs
;; (node_modules, staged .wasm/.js bundles — those rebuild
;; from the exported wasm/ trees). Users: npm ci + playwright
;; install, see README "Verify the browser story".
;; ---------------------------------------------------------------------------

(for ([rel (in-list tracked)]
      #:when (and (string-prefix? rel "browser-test/")
                  (regexp-match? #rx"[.](mjs|html|json)$" rel)
                  (not (string-contains? rel "node_modules"))))
  (copy-in rel))
(for ([rel (in-list '("browser-test/package-lock.json"
                      "browser-test/test.mjs"
                      "browser-test/bdd_runner.mjs"
                      "browser-test/bdd_scenarios.generated.mjs"
                      "browser-test/bdd_wasm_manifest.generated.mjs"))])
  (when (file-exists? rel) (copy-in rel)))

;; Prebuilt Wasm client bundles for the browser examples index
;; (examples/browser/): build outputs in the private tree
;; (make artifacts), shipped so a public clone runs the
;; examples with no language toolchains. Missing bundles fail
;; the export loudly rather than shipping a broken index.
(define browser-example-bundles
  '("browser-test/echo.wasm"
    "browser-test/echo_zig.wasm"
    "browser-test/echo_cpp.wasm"
    "browser-test/echo_swift.wasm"
    "browser-test/echo_lua.wasm"
    "browser-test/echo_dart_wasm.wasm"
    "browser-test/echo_dart_wasm.mjs"
    "browser-test/echo_dart_wasm.support.js"
    "browser-test/wasm_exec.js"
    "browser-test/wasm_lua_worker.js"))
(for ([rel (in-list browser-example-bundles)])
  (unless (file-exists? rel)
    (eprintf "releasegen: missing browser-example bundle ~a (run: make artifacts)\n" rel)
    (exit 1))
  (copy-in rel))
(define browser-example-bundle-dirs
  '("browser-test/kotlin_wasm_gen"
    "browser-test/scalajs_gen"
    "browser-test/wasm_rust_gen"))
(for ([dir (in-list browser-example-bundle-dirs)])
  (unless (directory-exists? dir)
    (eprintf "releasegen: missing browser-example bundle dir ~a (run: make artifacts)\n" dir)
    (exit 1))
  (for ([p (in-list (find-files file-exists? dir))])
    (copy-in (path->string (find-relative-path (current-directory) p)))))

;; ---------------------------------------------------------------------------
;; protoc plugin wrappers (bin/): tiny shims that run the
;; published Node plugin per language, so the exported
;; languages' protoc-driven tests (BDD schemas, PB messages)
;; run from this tree with only Node + protoc installed.
;; Also stage webapp/testdata at the path those tests use.
;; ---------------------------------------------------------------------------

(define plugin-langs
  '("js" "c" "go" "python" "rust" "java" "csharp" "cpp" "swift"
    "kotlin" "dart" "zig" "lua" "ruby" "php" "scala" "wasm-go"
    "wasm-zig" "wasm-cpp" "wasm-swift" "wasm-kotlin" "wasm-scala"
    "kotlin-native"))

(make-directory* (build-path out-dir "bin"))
(for ([lang (in-list plugin-langs)])
  (define path
    (build-path out-dir "bin" (string-append "protoc-gen-grpc-dc-" lang)))
  (call-with-output-file path #:exists 'replace
    (lambda (out)
      (display
       (string-append
        "#!/bin/sh\n"
        "# " lang " protoc plugin (Node, dependency-free) — generated by\n"
        "# grpc-dc release generator. Drives the published JS generators in\n"
        "# docs/app; output is byte-identical to the project's plugins.\n"
        "GRPC_DC_LANG=" lang
        " exec node \"$(dirname \"$0\")/../docs/app/protoc-gen-grpc-dc.mjs\" \"$@\"\n")
       out)))
  (file-or-directory-permissions path #o755))

(call-with-output-file (build-path out-dir "docs/app/gen/package.json")
  #:exists 'replace
  (lambda (out) (display "{\"type\": \"module\"}\n" out)))

;; ---------------------------------------------------------------------------
;; Plugin distribution (PLUGINS.md + npm plugin staging).
;; Three install channels for the same dependency-free plugins:
;; a release zip (bin/ + docs/app layout, assembled by
;; scripts/release-push.sh), the npm package (bin entries below),
;; and a protoc container image (docker/protoc-plugins.Dockerfile).
;; The npm staging copies the single-file plugin runtime next to
;; per-language wrappers that pin GRPC_DC_LANG, so
;; `node_modules/.bin/protoc-gen-grpc-dc-<lang>` just works.
;; ---------------------------------------------------------------------------

(call-with-output-file (build-path out-dir "PLUGINS.md")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# protoc plugins: install\n\n"
      "grpc-dc ships one dependency-free `protoc` plugin per\n"
      "language. The only requirements are `protoc` itself and\n"
      "Node.js 18+. Pick whichever channel fits your workflow:\n\n"
      "## 1. Release zip (any platform)\n\n"
      "Download `grpc-dc-" version ".zip` and `SHA256SUMS` from\n"
      "the [" version " release](https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/" version "), verify, and unzip:\n\n"
      "    sha256sum -c SHA256SUMS\n"
      "    unzip grpc-dc-" version ".zip\n"
      "    export PATH=\"$PWD/grpc-dc-" version "/bin:$PATH\"\n"
      "    protoc -I. --grpc-dc-rust_out=gen echo.proto\n\n"
      "With `bin/` on your `PATH`, `protoc` finds each plugin by\n"
      "name (`protoc-gen-grpc-dc-rust`, `-go`, `-python`, ...).\n"
      "Or name a wrapper explicitly:\n\n"
      "    protoc -I. --plugin=protoc-gen-grpc-dc-rust=$PWD/grpc-dc-" version "/bin/protoc-gen-grpc-dc-rust \\\n"
      "      --grpc-dc-rust_out=gen echo.proto\n\n"
      "## 2. npm (JS/web tooling)\n\n"
      "The `grpc-dc` npm package ships the same plugins as bin\n"
      "entries:\n\n"
      "    npm install --save-dev grpc-dc\n"
      "    protoc -I. --plugin=protoc-gen-grpc-dc-rust=node_modules/.bin/protoc-gen-grpc-dc-rust \\\n"
      "      --grpc-dc-rust_out=gen echo.proto\n\n"
      "## 3. Container (no host Node)\n\n"
      "`protoc` and all plugins, preinstalled on `PATH`:\n\n"
      "    docker run --rm -v \"$PWD\":/work ghcr.io/browser-grpc/protoc-plugins:" version " \\\n"
      "      -I. --grpc-dc-rust_out=gen echo.proto\n\n"
      "## From a clone of this repo\n\n"
      "The `bin/` wrappers in the repo root work in place; see\n"
      "the per-language READMEs (e.g. `rust/README.md`) for the\n"
      "exact `protoc` invocation per language. The example\n"
      "schema used above is `proto/echo.proto` in this repo.\n\n"
      "Languages: "
      (string-join
       (for/list ([lang (in-list plugin-langs)])
         (string-append "`" lang "`"))
       ", ")
      ".\n")
     out)))

(make-directory* (build-path out-dir "js/plugin/gen"))
(copy-file "webapp/protoc-gen-grpc-dc.mjs"
           (build-path out-dir "js/plugin/protoc-gen-grpc-dc.mjs") #t)
(copy-file "webapp/gen/generators.js"
           (build-path out-dir "js/plugin/gen/generators.js") #t)
(for ([lang (in-list plugin-langs)])
  (define path
    (build-path out-dir "js/plugin"
                (string-append "protoc-gen-grpc-dc-" lang ".mjs")))
  (call-with-output-file path #:exists 'replace
    (lambda (out)
      (display
       (string-append
        "#!/usr/bin/env node\n"
        "// " lang " protoc plugin (Node, dependency-free) — generated by\n"
        "// grpc-dc release generator. npm bin entry; pins the language\n"
        "// and runs the published plugin runtime beside it.\n"
        "process.env.GRPC_DC_LANG = \"" lang "\";\n"
        "await import(\"./protoc-gen-grpc-dc.mjs\");\n")
       out)))
  (file-or-directory-permissions path #o755))

;; Social preview card (1280x640). Text-rendered PNG from the
;; same size every release via Pillow in Dockerfile.ci; the
;; generator is scripts/render-social.py (private tooling,
;; never crosses the leak gate).
(call-with-output-file (build-path out-dir "docs/social-preview.png")
  #:exists 'replace
  (lambda (out)
    (define rendered
      (and (file-exists? "docs/social-preview.png")
           (file->bytes "docs/social-preview.png")))
    (display (or rendered #"") out)))

;; Honey badger mascot: derived resolutions + favicon from
;; scripts/render-badger.py (private tooling), copied verbatim
;; to docs/badger/; favicon.ico also lands at docs/ so the
;; landing page and site root have icons. Org/repo avatars on
;; GitHub are uploaded manually from honey-badger-512.png
;; (no API); the repo social preview uses social-preview.png,
;; which now carries the badger.
(make-directory* (build-path out-dir "docs/badger"))
(for ([file (in-list (directory-list "docs/badger"))])
  (define src (build-path "docs/badger" file))
  (when (file-exists? src)
    (copy-file src (build-path out-dir "docs/badger" file) #t)))
(when (file-exists? "docs/badger/favicon.ico")
  (copy-file "docs/badger/favicon.ico"
             (build-path out-dir "docs/favicon.ico") #t))

;; Supported proxy (public): the Node grpc-dc-proxy process
;; plus its HTTP/2 bridge, with imports rewritten to the
;; export layout (oracle/bridge.mjs -> proxy/bridge.mjs).
;; The Rust sidecar spikes stay private (they link external
;; crates; the export keeps its dependency-free story).
(make-directory* (build-path out-dir "proxy"))
(define proxy-process-src (file->string "proxy/grpc-dc-proxy.mjs"))
(call-with-output-file (build-path out-dir "proxy/grpc-dc-proxy.mjs")
  #:exists 'replace
  (lambda (out)
    (display (regexp-replace* #rx"\\.\\./oracle/bridge\\.mjs"
                              proxy-process-src "./bridge.mjs")
             out)))
(file-or-directory-permissions (build-path out-dir "proxy/grpc-dc-proxy.mjs") #o755)
(copy-file "oracle/bridge.mjs" (build-path out-dir "proxy/bridge.mjs") #t)
(copy-file "proxy/grpc-dc-agent.mjs" (build-path out-dir "proxy/grpc-dc-agent.mjs") #t)
(copy-file "proxy/README.md" (build-path out-dir "proxy/README.md") #t)
(copy-file "proxy/proxy_modes.generated.json"
           (build-path out-dir "proxy/proxy_modes.generated.json") #t)

;; Guided first-run motion card (Playwright-recorded from the
;; live app, encoded with Pillow; docs/first-run.gif in the
;; private repo, copied verbatim like the social card).
(call-with-output-file (build-path out-dir "docs/first-run.gif")
  #:exists 'replace
  (lambda (out)
    (define rendered
      (and (file-exists? "docs/first-run.gif")
           (file->bytes "docs/first-run.gif")))
    (display (or rendered #"") out)))

(for ([proto (in-list (directory-list "webapp/testdata"))])
  (when (string-suffix? (path->string proto) ".proto")
    (define dest (build-path out-dir "webapp/testdata" proto))
    (make-directory* (path-only dest))
    (copy-file (build-path "webapp/testdata" proto) dest #t)))

;; ---------------------------------------------------------------------------
;; npm trusted publishing (future-proofing). npm retires
;; token-based direct publish bypasses in January 2027, so the
;; public export ships a manually dispatched GitHub Actions
;; workflow that publishes js/ via OIDC (no stored token) once
;; the package's Trusted Publisher is configured on npmjs.com.
;; Until then the local token publish in release-push.sh stays
;; the active path. NPM-PUBLISHING.md documents both.
;; ---------------------------------------------------------------------------

(make-directory* (build-path out-dir ".github/workflows"))
(call-with-output-file (build-path out-dir ".github/workflows/publish-npm.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish the grpc-dc npm package via Trusted Publishing\n"
      "# (OIDC). Manual dispatch only; see NPM-PUBLISHING.md.\n"
      "# Requires the Trusted Publisher configured for grpc-dc\n"
      "# on npmjs.com (this repo + this workflow file).\n"
      "name: publish-npm\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: read\n"
      "  id-token: write\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: actions/setup-node@v4\n"
      "        with:\n"
      "          node-version: 22\n"
      "          registry-url: https://registry.npmjs.org\n"
      "      - run: npm install -g npm@latest\n"
      "      - working-directory: js\n"
      "        run: npm publish --provenance --access public\n")
     out)))

;; NuGet Trusted Publishing: same OIDC pattern as npm above.
;; Manual dispatch only; packs csharp/grpcdc and pushes with
;; the short-lived key NuGet/login mints from the workflow's
;; OIDC identity — no stored API key. Requires a Trusted
;; Publisher policy on nuget.org naming this repo + workflow.
(call-with-output-file (build-path out-dir ".github/workflows/publish-nuget.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish the GrpcDc NuGet package via Trusted Publishing\n"
      "# (OIDC). Manual dispatch only. Requires the Trusted\n"
      "# Publisher configured for GrpcDc on nuget.org (the\n"
      "# browser-grpc/grpc-over-datachannels repo, workflow\n"
      "# file publish-nuget.yml, user unicomp21).\n"
      "name: publish-nuget\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: read\n"
      "  id-token: write\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: actions/setup-dotnet@v4\n"
      "        with:\n"
      "          dotnet-version: 8.0.x\n"
      "      - name: NuGet login (OIDC -> short-lived API key)\n"
      "        uses: NuGet/login@v1\n"
      "        id: login\n"
      "        with:\n"
      "          user: unicomp21\n"
      "      - name: Pack GrpcDc\n"
      "        run: dotnet pack csharp/grpcdc/Grpcdc.csproj -c Release -o /tmp/nuget\n"
      "      - name: Push to nuget.org\n"
      "        run: dotnet nuget push /tmp/nuget/*.nupkg --api-key ${{ steps.login.outputs.NUGET_API_KEY }} --source https://api.nuget.org/v3/index.json --skip-duplicate\n")
     out)))

;; Maven Central (Java): a generated pom for the runtime in
;; java/ (the tree predates Maven; sources stay in place and
;; the compiler is scoped to grpcdc/**), plus a manual-dispatch
;; workflow that deploys via the Central Portal. Central has
;; no OIDC trusted publishing, so the workflow uses repo
;; secrets: CENTRAL_USERNAME / CENTRAL_PASSWORD (portal user
;; token) and MAVEN_GPG_PRIVATE_KEY / MAVEN_GPG_PASSPHRASE.
(call-with-output-file (build-path out-dir "java/pom.xml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<!-- Generated. DO NOT EDIT. -->\n"
      "<project xmlns=\"http://maven.apache.org/POM/4.0.0\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd\">\n"
      "  <modelVersion>4.0.0</modelVersion>\n"
      "  <groupId>io.github.browser-grpc</groupId>\n"
      "  <artifactId>grpc-dc</artifactId>\n"
      "  <version>" (regexp-replace #rx"^v" version "") "</version>\n"
      "  <packaging>jar</packaging>\n"
      "  <name>grpc-dc</name>\n"
      "  <description>gRPC over WebRTC DataChannels for Java - dependency-free generated gRPC clients and servers, no grpc-web proxy</description>\n"
      "  <url>https://browser-grpc.github.io/grpc-over-datachannels/</url>\n"
      "  <licenses>\n"
      "    <license>\n"
      "      <name>Apache License, Version 2.0</name>\n"
      "      <url>https://www.apache.org/licenses/LICENSE-2.0.txt</url>\n"
      "    </license>\n"
      "  </licenses>\n"
      "  <developers>\n"
      "    <developer>\n"
      "      <id>unicomp21</id>\n"
      "      <name>John Davis</name>\n"
      "      <email>jdavis@pcprogramming.com</email>\n"
      "    </developer>\n"
      "  </developers>\n"
      "  <scm>\n"
      "    <connection>scm:git:https://github.com/browser-grpc/grpc-over-datachannels.git</connection>\n"
      "    <developerConnection>scm:git:https://github.com/browser-grpc/grpc-over-datachannels.git</developerConnection>\n"
      "    <url>https://github.com/browser-grpc/grpc-over-datachannels</url>\n"
      "  </scm>\n"
      "  <properties>\n"
      "    <maven.compiler.release>17</maven.compiler.release>\n"
      "    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\n"
      "  </properties>\n"
      "  <build>\n"
      "    <sourceDirectory>${project.basedir}</sourceDirectory>\n"
      "    <plugins>\n"
      "      <plugin>\n"
      "        <artifactId>maven-compiler-plugin</artifactId>\n"
      "        <version>3.13.0</version>\n"
      "        <configuration>\n"
      "          <includes><include>grpcdc/**</include></includes>\n"
      "        </configuration>\n"
      "      </plugin>\n"
      "      <plugin>\n"
      "        <artifactId>maven-source-plugin</artifactId>\n"
      "        <version>3.3.1</version>\n"
      "        <executions><execution><id>attach-sources</id><goals><goal>jar-no-fork</goal></goals></execution></executions>\n"
      "      </plugin>\n"
      "      <plugin>\n"
      "        <artifactId>maven-javadoc-plugin</artifactId>\n"
      "        <version>3.10.0</version>\n"
      "        <configuration>\n"
      "          <additionalOptions><additionalOption>-Xdoclint:none</additionalOption></additionalOptions>\n"
      "          <quiet>true</quiet>\n"
      "        </configuration>\n"
      "        <executions><execution><id>attach-javadocs</id><goals><goal>jar</goal></goals></execution></executions>\n"
      "      </plugin>\n"
      "      <plugin>\n"
      "        <groupId>org.sonatype.central</groupId>\n"
      "        <artifactId>central-publishing-maven-plugin</artifactId>\n"
      "        <version>0.8.0</version>\n"
      "        <extensions>true</extensions>\n"
      "        <configuration>\n"
      "          <publishingServerId>central</publishingServerId>\n"
      "          <autoPublish>true</autoPublish>\n"
      "          <waitUntil>published</waitUntil>\n"
      "        </configuration>\n"
      "      </plugin>\n"
      "    </plugins>\n"
      "  </build>\n"
      "  <profiles>\n"
      "    <profile>\n"
      "      <id>release</id>\n"
      "      <build><plugins>\n"
      "        <plugin>\n"
      "          <artifactId>maven-gpg-plugin</artifactId>\n"
      "          <version>3.2.7</version>\n"
      "          <executions><execution><id>sign-artifacts</id><phase>verify</phase><goals><goal>sign</goal></goals></execution></executions>\n"
      "          <configuration><gpgArguments><arg>--pinentry-mode</arg><arg>loopback</arg></gpgArguments></configuration>\n"
      "        </plugin>\n"
      "      </plugins></build>\n"
      "    </profile>\n"
      "  </profiles>\n"
      "</project>\n")
     out)))

(call-with-output-file (build-path out-dir ".github/workflows/publish-maven.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish the Java runtime to Maven Central via the\n"
      "# Central Portal API. Manual dispatch only. The\n"
      "# central-publishing plugin's own upload fails Portal\n"
      "# bundle validation while the identical bundle zip\n"
      "# validates via the API, so the workflow builds the\n"
      "# signed bundle with the plugin and uploads it by API.\n"
      "# Requires repo\n"
      "# secrets CENTRAL_USERNAME / CENTRAL_PASSWORD (portal\n"
      "# user token) and MAVEN_GPG_PRIVATE_KEY /\n"
      "# MAVEN_GPG_PASSPHRASE (artifact signing).\n"
      "name: publish-maven\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: read\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: actions/setup-java@v4\n"
      "        with:\n"
      "          distribution: temurin\n"
      "          java-version: 17\n"
      "          server-id: central\n"
      "          server-username: MAVEN_USERNAME\n"
      "          server-password: MAVEN_PASSWORD\n"
      "          gpg-private-key: ${{ secrets.MAVEN_GPG_PRIVATE_KEY }}\n"
      "          gpg-passphrase: MAVEN_GPG_PASSPHRASE\n"
      "      - name: Build signed bundle (plugin upload step is bypassed)\n"
      "        run: mvn -B -f java/pom.xml deploy -Prelease -DcentralBaseUrl=http://127.0.0.1:9/nope || test -f java/target/central-publishing/central-bundle.zip\n"
      "        env:\n"
      "          MAVEN_USERNAME: ${{ secrets.CENTRAL_USERNAME }}\n"
      "          MAVEN_PASSWORD: ${{ secrets.CENTRAL_PASSWORD }}\n"
      "          MAVEN_GPG_PASSPHRASE: ${{ secrets.MAVEN_GPG_PASSPHRASE }}\n"
      "      - name: Upload + publish via Central Portal API\n"
      "        shell: bash\n"
      "        run: |\n"
      "          set -euo pipefail\n"
      "          TOKEN=$(printf '%s:%s' \"${{ secrets.CENTRAL_USERNAME }}\" \"${{ secrets.CENTRAL_PASSWORD }}\" | base64 -w0)\n"
      "          zip -d java/target/central-publishing/central-bundle.zip '*/_remote.repositories*' '*/maven-metadata-local.xml*' || true\n"
      "          ID=$(curl -sf -X POST -H \"Authorization: Bearer $TOKEN\" -F \"bundle=@java/target/central-publishing/central-bundle.zip\" \"https://central.sonatype.com/api/v1/publisher/upload?name=grpc-dc&publishingType=USER_MANAGED\")\n"
      "          echo \"deployment: $ID\"\n"
      "          for i in $(seq 1 40); do\n"
      "            STATE=$(curl -sf -X POST -H \"Authorization: Bearer $TOKEN\" \"https://central.sonatype.com/api/v1/publisher/status?id=$ID\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"deploymentState\"])')\n"
      "            echo \"state: $STATE\"\n"
      "            [ \"$STATE\" = VALIDATED ] && break\n"
      "            [ \"$STATE\" = FAILED ] && exit 1\n"
      "            sleep 15\n"
      "          done\n"
      "          curl -sf -X POST -H \"Authorization: Bearer $TOKEN\" \"https://central.sonatype.com/api/v1/publisher/deployment/$ID\"\n"
      "          for i in $(seq 1 120); do\n"
      "            STATE=$(curl -sf -X POST -H \"Authorization: Bearer $TOKEN\" \"https://central.sonatype.com/api/v1/publisher/status?id=$ID\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"deploymentState\"])')\n"
      "            echo \"state: $STATE\"\n"
      "            [ \"$STATE\" = PUBLISHED ] && exit 0\n"
      "            [ \"$STATE\" = FAILED ] && exit 1\n"
      "            sleep 15\n"
      "          done\n"
      "          echo 'timed out waiting for PUBLISHED' >&2; exit 1\n"
      "      - name: Build signed kafka-grpc bundle\n"
      "        run: mvn -B -f packages/kafka-java/pom.xml deploy -Prelease -DcentralBaseUrl=http://127.0.0.1:9/nope || test -f packages/kafka-java/target/central-publishing/central-bundle.zip\n"
      "        env:\n"
      "          MAVEN_USERNAME: ${{ secrets.CENTRAL_USERNAME }}\n"
      "          MAVEN_PASSWORD: ${{ secrets.CENTRAL_PASSWORD }}\n"
      "          MAVEN_GPG_PASSPHRASE: ${{ secrets.MAVEN_GPG_PASSPHRASE }}\n"
      "      - name: Upload kafka-grpc via Central Portal API\n"
      "        shell: bash\n"
      "        run: |\n"
      "          set -euo pipefail\n"
      "          TOKEN=$(printf '%s:%s' \"${{ secrets.CENTRAL_USERNAME }}\" \"${{ secrets.CENTRAL_PASSWORD }}\" | base64 -w0)\n"
      "          zip -d packages/kafka-java/target/central-publishing/central-bundle.zip '*/_remote.repositories*' '*/maven-metadata-local.xml*' || true\n"
      "          ID=$(curl -sf -X POST -H \"Authorization: Bearer $TOKEN\" -F \"bundle=@packages/kafka-java/target/central-publishing/central-bundle.zip\" \"https://central.sonatype.com/api/v1/publisher/upload?name=kafka-grpc&publishingType=USER_MANAGED\")\n"
      "          echo \"deployment: $ID\"\n"
      "          for i in $(seq 1 120); do\n"
      "            STATE=$(curl -sf -X POST -H \"Authorization: Bearer $TOKEN\" \"https://central.sonatype.com/api/v1/publisher/status?id=$ID\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"deploymentState\"])')\n"
      "            echo \"state: $STATE\"\n"
      "            [ \"$STATE\" = PUBLISHED ] && exit 0\n"
      "            [ \"$STATE\" = FAILED ] && exit 1\n"
      "            sleep 15\n"
      "          done\n"
      "          echo 'timed out waiting for PUBLISHED' >&2; exit 1\n")
     out)))

;; GitHub-hosted Maven channel (fallback / cadence relief for
;; Maven Central): a static Maven repository committed under
;; docs/maven/ in this repo. GitHub Pages serves docs/ from the
;; default branch (legacy mode), so consumers resolve
;; io.github.browser-grpc:grpc-dc anonymously from
;; https://browser-grpc.github.io/grpc-over-datachannels/maven/
;; with no token and no Sonatype deployment count. Central
;; stays the discovery channel; this one ships with every
;; release. The workflow lays the freshly built artifacts into
;; the existing tree (prior versions are kept) and commits the
;; result; scripts/release-push.sh excludes docs/maven/ from
;; its rsync --delete so the tree survives export refreshes.
(call-with-output-file (build-path out-dir ".github/workflows/publish-maven-github.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish the Java runtime to the GitHub-hosted Maven\n"
      "# repository (docs/maven/, served by GitHub Pages).\n"
      "# Manual dispatch only; no secrets required. Unlike\n"
      "# Maven Central there is no deployment-count limit, so\n"
      "# this channel ships with every release. Consumers:\n"
      "#   <repository><id>github-pages</id>\n"
      "#   <url>https://browser-grpc.github.io/grpc-over-datachannels/maven/</url></repository>\n"
      "# and depend on io.github.browser-grpc:grpc-dc as usual.\n"
      "name: publish-maven-github\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: write\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: actions/setup-java@v4\n"
      "        with:\n"
      "          distribution: temurin\n"
      "          java-version: 17\n"
      "      - name: Build jars\n"
      "        run: mvn -B -f java/pom.xml package -DskipTests\n"
      "      - name: Lay out the Maven repository under docs/maven\n"
      "        shell: bash\n"
      "        run: |\n"
      "          set -euo pipefail\n"
      "          V=$(grep -m1 '<version>' java/pom.xml | sed -E 's/<[^>]+>//g; s/^ *//; s/ *$//')\n"
      "          DEST=\"docs/maven/io/github/browser-grpc/grpc-dc/$V\"\n"
      "          mkdir -p \"$DEST\"\n"
      "          cp java/pom.xml \"$DEST/grpc-dc-$V.pom\"\n"
      "          cp \"java/target/grpc-dc-$V.jar\" \"$DEST/\"\n"
      "          cp \"java/target/grpc-dc-$V-sources.jar\" \"$DEST/\"\n"
      "          cp \"java/target/grpc-dc-$V-javadoc.jar\" \"$DEST/\"\n"
      "          for f in \"$DEST\"/*; do\n"
      "            md5sum \"$f\" | cut -d' ' -f1 > \"$f.md5\"\n"
      "            sha1sum \"$f\" | cut -d' ' -f1 > \"$f.sha1\"\n"
      "          done\n"
      "          BASE=docs/maven/io/github/browser-grpc/grpc-dc\n"
      "          python3 - \"$BASE\" \"$V\" <<'PYEOF'\n"
      "          import os, sys, datetime\n"
      "          import xml.etree.ElementTree as ET\n"
      "          base, ver = sys.argv[1], sys.argv[2]\n"
      "          path = os.path.join(base, 'maven-metadata.xml')\n"
      "          versions = []\n"
      "          if os.path.exists(path):\n"
      "              vs = ET.parse(path).getroot().find('./versioning/versions')\n"
      "              versions = [v.text for v in vs.findall('version')] if vs is not None else []\n"
      "          if ver not in versions:\n"
      "              versions.append(ver)\n"
      "          now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d%H%M%S')\n"
      "          lines = ['<?xml version=\"1.0\" encoding=\"UTF-8\"?>', '<metadata>',\n"
      "                   '  <groupId>io.github.browser-grpc</groupId>',\n"
      "                   '  <artifactId>grpc-dc</artifactId>', '  <versioning>',\n"
      "                   f'    <latest>{versions[-1]}</latest>', f'    <release>{versions[-1]}</release>',\n"
      "                   '    <versions>']\n"
      "          lines += [f'      <version>{v}</version>' for v in versions]\n"
      "          lines += ['    </versions>', f'    <lastUpdated>{now}</lastUpdated>',\n"
      "                    '  </versioning>', '</metadata>', '']\n"
      "          open(path, 'w').write('\\n'.join(lines))\n"
      "          for algo in ('md5', 'sha1'):\n"
      "              import hashlib\n"
      "              h = hashlib.new(algo, open(path, 'rb').read()).hexdigest()\n"
      "              open(f'{path}.{algo}', 'w').write(h)\n"
      "          PYEOF\n"
      "      - name: Build kafka-grpc jar and lay out its Maven repository\n"
      "        shell: bash\n"
      "        run: |\n"
      "          set -euo pipefail\n"
      "          mvn -B -f packages/kafka-java/pom.xml package -DskipTests\n"
      "          V=$(grep -m1 '<version>' packages/kafka-java/pom.xml | sed -E 's/<[^>]+>//g; s/^ *//; s/ *$//')\n"
      "          DEST=\"docs/maven/io/github/browser-grpc/kafka-grpc/$V\"\n"
      "          mkdir -p \"$DEST\"\n"
      "          cp packages/kafka-java/pom.xml \"$DEST/kafka-grpc-$V.pom\"\n"
      "          cp \"packages/kafka-java/target/kafka-grpc-$V.jar\" \"$DEST/\"\n"
      "          cp \"packages/kafka-java/target/kafka-grpc-$V-sources.jar\" \"$DEST/\"\n"
      "          cp \"packages/kafka-java/target/kafka-grpc-$V-javadoc.jar\" \"$DEST/\"\n"
      "          for f in \"$DEST\"/*; do\n"
      "            md5sum \"$f\" | cut -d' ' -f1 > \"$f.md5\"\n"
      "            sha1sum \"$f\" | cut -d' ' -f1 > \"$f.sha1\"\n"
      "          done\n"
      "          BASE=docs/maven/io/github/browser-grpc/kafka-grpc\n"
      "          python3 - \"$BASE\" \"$V\" <<'PYEOF'\n"
      "          import os, sys, datetime\n"
      "          import xml.etree.ElementTree as ET\n"
      "          base, ver = sys.argv[1], sys.argv[2]\n"
      "          path = os.path.join(base, 'maven-metadata.xml')\n"
      "          versions = []\n"
      "          if os.path.exists(path):\n"
      "              vs = ET.parse(path).getroot().find('./versioning/versions')\n"
      "              versions = [v.text for v in vs.findall('version')] if vs is not None else []\n"
      "          if ver not in versions:\n"
      "              versions.append(ver)\n"
      "          now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d%H%M%S')\n"
      "          lines = ['<?xml version=\"1.0\" encoding=\"UTF-8\"?>', '<metadata>',\n"
      "                   '  <groupId>io.github.browser-grpc</groupId>',\n"
      "                   '  <artifactId>kafka-grpc</artifactId>', '  <versioning>',\n"
      "                   f'    <latest>{versions[-1]}</latest>', f'    <release>{versions[-1]}</release>',\n"
      "                   '    <versions>']\n"
      "          lines += [f'      <version>{v}</version>' for v in versions]\n"
      "          lines += ['    </versions>', f'    <lastUpdated>{now}</lastUpdated>',\n"
      "                    '  </versioning>', '</metadata>', '']\n"
      "          open(path, 'w').write('\\n'.join(lines))\n"
      "          for algo in ('md5', 'sha1'):\n"
      "              import hashlib\n"
      "              h = hashlib.new(algo, open(path, 'rb').read()).hexdigest()\n"
      "              open(f'{path}.{algo}', 'w').write(h)\n"
      "          PYEOF\n"
      "      - name: Commit the repository tree\n"
      "        shell: bash\n"
      "        run: |\n"
      "          set -euo pipefail\n"
      "          git config user.name \"John Davis\"\n"
      "          git config user.email \"jdavis@pcprogramming.com\"\n"
      "          git add docs/maven\n"
      "          if git diff --cached --quiet; then\n"
      "            echo 'maven tree unchanged; nothing to publish'\n"
      "          else\n"
      "            V=$(grep -m1 '<version>' java/pom.xml | sed -E 's/<[^>]+>//g; s/^ *//; s/ *$//')\n"
      "            git commit -m \"maven-repo: grpc-dc $V (GitHub Pages channel)\"\n"
      "            git push\n"
      "          fi\n")
     out)))

(call-with-output-file (build-path out-dir "MAVEN-PUBLISHING.md")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publishing grpc-dc for Java (maintainers)\n\n"
      "Two channels publish the same artifact\n"
      "(`io.github.browser-grpc:grpc-dc`, same version):\n\n"
      "## Maven Central (discovery channel)\n\n"
      "`.github/workflows/publish-maven.yml` (manual dispatch)\n"
      "uploads the signed bundle to Maven Central via the\n"
      "Central Portal API. Sonatype counts deployments per\n"
      "organization per month, so Central is synced in a\n"
      "batched weekly slot, not on every release.\n\n"
      "## GitHub-hosted Maven repo (every release)\n\n"
      "`.github/workflows/publish-maven-github.yml` (manual\n"
      "dispatch) commits a static Maven repository under\n"
      "`docs/maven/`; GitHub Pages serves it at\n"
      "`https://browser-grpc.github.io/grpc-over-datachannels/maven/`.\n"
      "No deployment-count limit and no credentials, so this\n"
      "channel ships with every release. Consumers add:\n\n"
      "```xml\n"
      "<repository>\n"
      "  <id>github-pages</id>\n"
      "  <url>https://browser-grpc.github.io/grpc-over-datachannels/maven/</url>\n"
      "</repository>\n"
      "```\n\n"
      "and depend on `io.github.browser-grpc:grpc-dc` as usual.\n"
      "Anonymous reads; Gradle uses\n"
      "`maven { url 'https://browser-grpc.github.io/grpc-over-datachannels/maven/' }`.\n")
     out)))

(call-with-output-file (build-path out-dir "NPM-PUBLISHING.md")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publishing grpc-dc to npm (maintainers)\n\n"
      "Two paths exist. Path 1 is active today; path 2 replaces\n"
      "it before npm retires token-based direct publishing in\n"
      "January 2027 (the current granular token also expires\n"
      "2027-01-22).\n\n"
      "## Path 1: local token (current)\n\n"
      "`scripts/release-push.sh` in the private source repo\n"
      "publishes `js/` from the generated export during a\n"
      "release, using the maintainer's granular access token\n"
      "(scope: the `grpc-dc` package only). No action is needed\n"
      "per release beyond being logged in.\n\n"
      "## Path 2: Trusted Publishing via GitHub Actions\n\n"
      "This export ships `.github/workflows/publish-npm.yml`\n"
      "(manual dispatch only). It publishes `js/` with\n"
      "`npm publish --provenance` using the workflow's OIDC\n"
      "identity — no token is stored anywhere.\n\n"
      "One-time setup on npmjs.com (package owner, passkey\n"
      "required):\n\n"
      "1. Open the `grpc-dc` package settings, Trusted Publisher.\n"
      "2. Add GitHub Actions: repository\n"
      "   `browser-grpc/grpc-over-datachannels`, workflow\n"
      "   filename `publish-npm.yml`, no environment.\n"
      "3. Recommended: set the package Publishing access to\n"
      "   require two-factor authentication and disallow tokens\n"
      "   once this path is verified.\n\n"
      "Per release after setup: publish the GitHub release as\n"
      "usual, then run Actions > publish-npm > Run workflow.\n"
      "The version comes from `js/package.json` in the export,\n"
      "already aligned with the release tag. Verify with\n"
      "`npm view grpc-dc version`.\n\n"
      "Fallback if OIDC is unavailable: staged publishing\n"
      "(`npm stage publish` from `js/`, then approve the staged\n"
      "package on npmjs.com with a passkey).\n")
     out)))

;; ---------------------------------------------------------------------------
;; Per-language Docker images + interop demo + compose,
;; generated from this one table (base image, test command).
;; ---------------------------------------------------------------------------

(define (test-loop cmd-template tests)
  (string-join
   (for/list ([t (in-list tests)]) (format cmd-template t))
   " && "))

(define docker-specs
  (list
   (list "rust" "rust:1-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY rust ./rust" "COPY webrtc/rust ./webrtc/rust" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN cd rust && cargo fetch --locked && cargo test --locked --no-run")
         "cd rust && cargo test --locked -- --skip official_clients_call_rust_server")
   (list "go" "golang:1.24-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY go ./go" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto" "COPY webrtc/go ./webrtc/go" "RUN cd go && go mod edit -replace=github.com/browser-grpc/grpc-over-datachannels/webrtc/go=../webrtc/go && go mod tidy && go build ./...")
         "cd go && go test -race -skip 'Sidecar|TestInteropOfficialClientsCallGoServer' ./...")
   (list "js" "node:24-bookworm-slim"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs git && rm -rf /var/lib/apt/lists/*" "COPY js ./js" "COPY webrtc/js ./webrtc/js" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto")
         "cd js && node --test $(ls test/*.test.js | grep -v -e dynamic.test -e oracle.test -e interop.test -e plugin_parity.test)")
   (list "python" "python:3.13-slim"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs git && rm -rf /var/lib/apt/lists/*" "COPY python ./python" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto")
         "cd python && python3 -m unittest $(ls tests/test_*.py | grep -v -e sidecar -e interop_server_oracle | sed -e 's|tests/||' -e 's|[.]py$||' -e 's|^|tests.|')")
   (list "java" "eclipse-temurin:21-jdk"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY java ./java" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN cd java && mkdir -p build && javac -encoding UTF-8 -d build $(find grpcdc examples tests -name '*.java')")
         (string-append "cd java && "
                        (test-loop "java -cp build tests.~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestBddSchemas" "TestPbMessages"))))
   (list "csharp" "mcr.microsoft.com/dotnet/sdk:8.0"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY csharp ./csharp" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN cd csharp && dotnet build tests/Tests.csproj --nologo -v q && dotnet build examples/EchoServerStdio/EchoServerStdio.csproj --nologo -v q && dotnet build examples/EchoClientStdio/EchoClientStdio.csproj --nologo -v q && dotnet build examples/DynamicEchoServerStdio/DynamicEchoServerStdio.csproj --nologo -v q")
         (string-append "cd csharp && "
                        (test-loop "dotnet run --project tests --no-build -- ~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestBddSchemas" "TestPbMessages"))))
   (list "cpp" "gcc:14-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY cpp ./cpp" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p cpp/build && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/tests/main.cpp cpp/tests/test_codec.cpp cpp/tests/test_echo.cpp cpp/tests/test_interop.cpp cpp/tests/test_interop_oracle.cpp cpp/tests/test_interop_server_oracle.cpp cpp/tests/test_oracle.cpp cpp/tests/test_dynamic.cpp cpp/tests/test_bdd.cpp cpp/tests/test_deadline.cpp cpp/tests/test_inline_pump.cpp cpp/tests/test_pb_messages.cpp cpp/tests/test_bdd_schemas.cpp cpp/tests/test_sidecar.cpp cpp/tests/test_bdd_sidecar.cpp cpp/tests/test_eventbus.cpp cpp/tests/test_kafka_e2e.cpp -o cpp/build/tests && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/examples/echo_server_stdio.cpp -o cpp/build/echo_server_stdio && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/examples/echo_client_stdio.cpp -o cpp/build/echo_client_stdio && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/examples/dynamic_echo_server_stdio.cpp -o cpp/build/dynamic_echo_server_stdio && g++ -std=c++20 -pthread -O1 -Icpp -I. cpp/tests/test_async.cpp -o cpp/build/test_async")
         (string-append "cd cpp && "
                        (test-loop "./build/tests ~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestDeadline" "TestBddSchemas" "TestPbMessages"))
                        " && ./build/test_async"))
   (list "swift" "swift:6.2-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY swift ./swift" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p swift/build && swiftc -swift-version 5 -O swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/DynamicEchoService.swift swift/examples/interop/*.swift swift/tests/*.swift -o swift/build/tests && swiftc -swift-version 5 -O swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/EchoServerStdio/main.swift -o swift/build/echo_server_stdio && swiftc -swift-version 5 -O swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/EchoClientStdio/main.swift -o swift/build/echo_client_stdio && swiftc -swift-version 5 -O swift/grpcdc/*.swift swift/examples/StdioTransport.swift swift/examples/DynamicEchoService.swift swift/examples/DynamicEchoServerStdio/main.swift -o swift/build/dynamic_echo_server_stdio")
         (string-append "cd swift && "
                        (test-loop "./build/tests ~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestDeadline" "TestBddSchemas" "TestPbMessages"))))
   (list "kotlin" "eclipse-temurin:21-jdk"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "RUN apt-get update && apt-get install -y curl unzip && curl -fsSL https://github.com/JetBrains/kotlin/releases/download/v2.4.0/kotlin-compiler-2.4.0.zip -o /tmp/kotlin.zip && unzip -q /tmp/kotlin.zip -d /opt && rm /tmp/kotlin.zip"
           "ENV PATH=\"/opt/kotlinc/bin:${PATH}\""
           "COPY kotlin ./kotlin" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p kotlin/build && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/DynamicEchoService.kt kotlin/examples/interop/*.kt kotlin/tests/*.kt -d kotlin/build/tests.jar && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/EchoServerStdio/Main.kt -d kotlin/build/echo_server_stdio.jar && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/EchoClientStdio/Main.kt -d kotlin/build/echo_client_stdio.jar && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/StdioTransport.kt kotlin/examples/DynamicEchoService.kt kotlin/examples/DynamicEchoServerStdio/Main.kt -d kotlin/build/dynamic_echo_server_stdio.jar")
         (test-loop "java -jar kotlin/build/tests.jar ~a"
                    '("TestCodec" "TestEcho" "TestBdd" "TestDeadline" "TestBddSchemas" "TestPbMessages")))
   (list "dart" "dart:stable"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY dart ./dart" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p dart/build && dart compile exe dart/tests/main.dart -o dart/build/tests && dart compile exe dart/examples/EchoServerStdio/main.dart -o dart/build/echo_server_stdio && dart compile exe dart/examples/EchoClientStdio/main.dart -o dart/build/echo_client_stdio && dart compile exe dart/examples/DynamicEchoServerStdio/main.dart -o dart/build/dynamic_echo_server_stdio")
         (string-append "cd dart && "
                        (test-loop "./build/tests ~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestBddSchemas" "TestPbMessages"))))
   (list "zig" "debian:bookworm-slim"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "RUN apt-get update && apt-get install -y curl xz-utils ca-certificates && case \"$(uname -m)\" in x86_64) A=x86_64 ;; aarch64) A=aarch64 ;; esac && curl -fsSL \"https://ziglang.org/download/0.15.1/zig-${A}-linux-0.15.1.tar.xz\" -o /tmp/zig.tar.xz && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz"
           "ENV PATH=\"/opt/zig:${PATH}\""
           "COPY zig ./zig" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN cd zig && zig build --prefix build")
         (string-append "cd zig && "
                        (test-loop "./build/bin/tests ~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestBddSchemas" "TestPbMessages"))))
   (list "c" "gcc:14-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY c ./c" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p c/build && gcc -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -pthread -O1 -Ic -Ic/examples -Ic/tests c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/grpcdc/sidecar_transport.c c/grpcdc/dynamic.c c/examples/stdio_transport.c c/tests/main.c -o c/build/tests && gcc -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -pthread -O1 -Ic -Ic/examples -Ic/tests c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/examples/stdio_transport.c c/examples/echo_server_stdio.c -o c/build/echo_server_stdio && gcc -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -pthread -O1 -Ic -Ic/examples -Ic/tests c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/examples/stdio_transport.c c/examples/echo_client_stdio.c -o c/build/echo_client_stdio")
         (test-loop "./c/build/tests ~a"
                    '("TestCodec" "TestEcho" "TestBdd" "TestBddSchemas" "TestPbMessages")))
   (list "lua" "debian:bookworm-slim"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "RUN apt-get update && apt-get install -y build-essential curl ca-certificates libreadline-dev && curl -fsSL https://www.lua.org/ftp/lua-5.4.8.tar.gz -o /tmp/lua.tar.gz && tar -xzf /tmp/lua.tar.gz -C /tmp && make -C /tmp/lua-5.4.8 linux && cp /tmp/lua-5.4.8/src/lua /usr/local/bin/lua"
           "COPY lua ./lua" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto")
         (test-loop "lua lua/tests/main.lua ~a"
                    '("TestCodec" "TestEcho" "TestBdd" "TestCoro" "TestBddSchemas" "TestPbMessages")))
   (list "ruby" "ruby:3.4-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY ruby ./ruby" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto")
         (test-loop "ruby ruby/tests/main.rb ~a"
                    '("TestCodec" "TestEcho" "TestBdd" "TestFiber" "TestBddSchemas" "TestPbMessages")))
   (list "php" "php:8.4-cli-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY php ./php" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto")
         (test-loop "php php/tests/main.php ~a"
                    '("TestCodec" "TestEcho" "TestBdd" "TestFiber" "TestBddSchemas" "TestPbMessages")))
   (list "scala" "eclipse-temurin:21-jdk"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "RUN apt-get update && apt-get install -y curl && curl -fsSL https://github.com/scala/scala3/releases/download/3.3.6/scala3-3.3.6.tar.gz -o /tmp/scala3.tar.gz && mkdir -p /usr/local/scala3 && tar -xzf /tmp/scala3.tar.gz -C /usr/local/scala3 --strip-components=1 && rm /tmp/scala3.tar.gz"
           "ENV PATH=\"/usr/local/scala3/bin:${PATH}\""
           "COPY scala ./scala" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p scala/build && scalac -d scala/build/tests.jar scala/grpcdc/*.scala scala/examples/EchoMessages.scala scala/examples/EchoGrpcDc.scala scala/examples/EchoServiceImpl.scala scala/examples/StdioTransport.scala scala/examples/DynamicEchoService.scala scala/examples/interop/*.scala scala/tests/*.scala && scalac -d scala/build/echo_server_stdio.jar scala/grpcdc/*.scala scala/examples/EchoMessages.scala scala/examples/EchoGrpcDc.scala scala/examples/EchoServiceImpl.scala scala/examples/StdioTransport.scala scala/examples/EchoServerStdio/Main.scala && scalac -d scala/build/echo_client_stdio.jar scala/grpcdc/*.scala scala/examples/EchoMessages.scala scala/examples/EchoGrpcDc.scala scala/examples/StdioTransport.scala scala/examples/EchoClientStdio/Main.scala && scalac -d scala/build/dynamic_echo_server_stdio.jar scala/grpcdc/*.scala scala/examples/StdioTransport.scala scala/examples/DynamicEchoService.scala scala/examples/DynamicEchoServerStdio/Main.scala")
         (test-loop "java -cp scala/build/tests.jar:/usr/local/scala3/lib/scala3-library_3-3.3.6.jar:/usr/local/scala3/lib/scala-library-2.13.16.jar tests.Main ~a"
                    '("TestCodec" "TestEcho" "TestBdd" "TestBddSchemas" "TestPbMessages")))))

(define (emit-dockerfile spec)
  (define key (first spec))
  (string-append
   "# " key " — generated by grpc-dc codegen. DO NOT EDIT.\n"
   "# Run this language's test suite (no toolchain install).\n"
   "# Cross-language sidecar cases are excluded\n"
   "# (they need other toolchains / the code generator); see\n"
   "# docker/interop.Dockerfile for cross-language runs.\n"
   "#   docker build -f docker/" key ".Dockerfile -t grpc-dc-" key " .\n"
   "#   docker run --rm grpc-dc-" key "\n"
   "FROM " (second spec) "\n"
   "WORKDIR /src\n"
   (string-join (third spec) "\n") "\n"
   "CMD [\"sh\", \"-c\", \"" (fourth spec) "\"]\n"))

(make-directory* (build-path out-dir "docker"))
(for ([spec (in-list docker-specs)])
  (call-with-output-file
      (build-path out-dir "docker" (string-append (first spec) ".Dockerfile"))
    (lambda (out) (display (emit-dockerfile spec) out)) #:exists 'replace))

;; Public CI: one GitHub Actions job per generated language
;; image (the matrix is built from docker-specs so it cannot
;; drift from the Dockerfiles it runs), plus the interop demo.
;; The private baked gate stays the authoritative full check;
;; this gives the public repo a visible per-language signal
;; that users can reproduce locally with the same commands.
(make-directory* (build-path out-dir ".github/workflows"))
(call-with-output-file (build-path out-dir ".github/workflows/ci.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Generated. DO NOT EDIT.\n"
      "# One job per language Dockerfile in docker/; each job is\n"
      "# the same two commands a user runs from a local clone.\n"
      "name: CI\n"
      "on:\n"
      "  push:\n"
      "    branches: [main]\n"
      "  pull_request:\n"
      "jobs:\n"
      "  lang:\n"
      "    runs-on: ubuntu-latest\n"
      "    strategy:\n"
      "      fail-fast: false\n"
      "      matrix:\n"
      "        lang: ["
      (string-join (map first docker-specs) ", ")
      "]\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - name: Build ${{ matrix.lang }} image\n"
      "        run: docker build -f docker/${{ matrix.lang }}.Dockerfile -t grpc-dc-${{ matrix.lang }} .\n"
      "      - name: Run ${{ matrix.lang }} tests\n"
      "        run: docker run --rm grpc-dc-${{ matrix.lang }}\n"
      "  interop:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - name: Build interop image\n"
      "        run: docker build -f docker/interop.Dockerfile -t grpc-dc-interop .\n"
      "      - name: Run interop demo\n"
      "        run: docker run --rm grpc-dc-interop\n"
      "  browser:\n"
      "    runs-on: ubuntu-latest\n"
      "    timeout-minutes: 45\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: actions/setup-node@v4\n"
      "        with:\n"
      "          node-version: 22\n"
      "      - uses: actions/setup-go@v5\n"
      "        with:\n"
      "          go-version-file: go/go.mod\n"
      "      - uses: dtolnay/rust-toolchain@stable\n"
      "      - name: Install browser test deps\n"
      "        working-directory: browser-test\n"
      "        run: npm ci\n"
      "      - name: Install browsers\n"
      "        working-directory: browser-test\n"
      "        run: npx playwright install --with-deps chromium firefox webkit\n"
      "      - name: Build Rust peer for browser suites\n"
      "        run: cargo build --manifest-path webrtc/rust/Cargo.toml --example peer_echo\n"
      "      - name: Run browser suites (Chromium/Firefox/WebKit)\n"
      "        working-directory: browser-test\n"
      "        run: npm test\n")
     out)))

;; Cross-language interop demo: Python + JS clients against
;; Go + Python stdio servers, pumped by the exported runner.
(call-with-output-file (build-path out-dir "docker/interop.Dockerfile")
  (lambda (out)
    (display
     (string-append
      "# Cross-language interop demo — generated. DO NOT EDIT.\n"
      "#   docker build -f docker/interop.Dockerfile -t grpc-dc-interop .\n"
      "#   docker run --rm grpc-dc-interop\n"
      "FROM node:24-bookworm-slim AS node\n"
      "FROM golang:1.24-bookworm\n"
      "COPY --from=node /usr/local/bin/node /usr/local/bin/node\n"
      "RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*\n"
      "WORKDIR /src\n"
      "COPY go ./go\nCOPY webrtc/go ./webrtc/go\nCOPY python ./python\nCOPY js ./js\n"
      "RUN cd go && go mod edit -replace=github.com/browser-grpc/grpc-over-datachannels/webrtc/go=../webrtc/go && go mod tidy\n"
      "CMD [\"sh\", \"-c\", \"MATRIX_CLIENTS=python,go MATRIX_SERVERS=go,python node js/test/interop-matrix.mjs\"]\n")
     out))
  #:exists 'replace)

;; Plugin distribution image: protoc + every plugin wrapper on
;; PATH (bin/ resolves its runtime via ../docs/app, mirrored
;; under /plugins). Users mount their schema tree at /work and
;; run protoc directly; no host Node needed.
(call-with-output-file (build-path out-dir "docker/protoc-plugins.Dockerfile")
  (lambda (out)
    (display
     (string-append
      "# protoc + grpc-dc protoc plugins — generated. DO NOT EDIT.\n"
      "#   docker build -f docker/protoc-plugins.Dockerfile -t protoc-plugins .\n"
      "#   docker run --rm -v \"$PWD\":/work protoc-plugins -I. --grpc-dc-rust_out=gen echo.proto\n"
      "FROM node:24-bookworm-slim\n"
      "RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler && rm -rf /var/lib/apt/lists/*\n"
      "COPY bin /plugins/bin\n"
      "COPY docs/app/protoc-gen-grpc-dc.mjs /plugins/docs/app/protoc-gen-grpc-dc.mjs\n"
      "COPY docs/app/gen /plugins/docs/app/gen\n"
      "ENV PATH=\"/plugins/bin:${PATH}\"\n"
      "WORKDIR /work\n"
      "ENTRYPOINT [\"protoc\"]\n"
      "CMD [\"--help\"]\n")
     out))
  #:exists 'replace)

;; Kafka proxy image: the Rust kafka_proxy example (see
;; KAFKA.md), built with broker TLS support. Users point it at
;; a broker; generated clients in every language reach Kafka
;; through it over stdio, length-prefixed TCP, or a WebRTC
;; DataChannel.
(call-with-output-file (build-path out-dir "docker/kafka-proxy.Dockerfile")
  (lambda (out)
    (display
     (string-append
      "# Kafka over gRPC proxy — generated. DO NOT EDIT.\n"
      "#   docker build -f docker/kafka-proxy.Dockerfile -t kafka-proxy .\n"
      "#   docker run --rm kafka-proxy --tcp 0.0.0.0:50201 --broker kafka:9092\n"
      "FROM rust:1-bookworm AS build\n"
      "WORKDIR /src\n"
      "COPY rust ./rust\n"
      "COPY webrtc/rust ./webrtc/rust\n"
      "COPY proto ./proto\n"
      "RUN cd rust && cargo build --release --locked --features kafka-tls,webrtc --example kafka_proxy\n"
      "FROM debian:bookworm-slim\n"
      "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*\n"
      "COPY --from=build /src/rust/target/release/examples/kafka_proxy /usr/local/bin/kafka_proxy\n"
      "ENTRYPOINT [\"kafka_proxy\"]\n"
      "CMD [\"--help\"]\n")
     out))
  #:exists 'replace)

;; Public Kafka guide: the service surface and how to run the
;; proxy container. Deliberately free of private-repo paths.
(call-with-output-file (build-path out-dir "KAFKA.md")
  (lambda (out)
    (display
     (string-append
      "# Kafka over gRPC\n"
      "\n"
      "`proto/kafka.proto` (`grpcdc.kafka.v1.Kafka`) exposes a Kafka\n"
      "cluster through the generated gRPC clients of every supported\n"
      "language, browser and native. A single Rust proxy terminates\n"
      "the generated service and speaks the Kafka binary protocol to\n"
      "Apache Kafka (KRaft) or Redpanda, negotiating API versions per\n"
      "connection.\n"
      "\n"
      "## Run the proxy\n"
      "\n"
      "```sh\n"
      "docker build -f docker/kafka-proxy.Dockerfile -t kafka-proxy .\n"
      "docker run --rm kafka-proxy --tcp 0.0.0.0:50201 --broker kafka:9092\n"
      "```\n"
      "\n"
      "Or from the published image:\n"
      "\n"
      "```sh\n"
      "docker run --rm ghcr.io/browser-grpc/kafka-proxy:latest \\\n"
      "  --tcp 0.0.0.0:50201 --broker kafka:9092\n"
      "```\n"
      "\n"
      "Modes: `--stdio` (length-prefixed framing on stdin/stdout),\n"
      "`--tcp ADDR` (the same framing over TCP, for any generated\n"
      "client's sidecar transport), and `--webrtc-direct ADDR`\n"
      "(gRPC over a WebRTC DataChannel).\n"
      "\n"
      "Broker security: `--sasl-plain USER PASS`,\n"
      "`--sasl-scram-sha-256 USER PASS`, or\n"
      "`--sasl-scram-sha-512 USER PASS`; TLS via `--tls-ca-cert PEM`\n"
      "or `--tls-insecure-skip-verify` (the image is built with TLS\n"
      "support enabled).\n"
      "\n"
      "## Service surface\n"
      "\n"
      "- `Metadata`, `ListOffsets`, `CreateTopics`, `DeleteTopics`.\n"
      "- `Produce` / `Consume` (server-streaming): per-partition\n"
      "  ordering, offset resume, null-vs-empty record keys,\n"
      "  `read_committed`, gzip/snappy/LZ4/zstd compression.\n"
      "- Producer sessions: idempotent produce and transactions\n"
      "  (commit/abort, transactional consume-produce).\n"
      "- Consumer groups: range/roundrobin assignment, static\n"
      "  membership with fencing, committed-offset resume,\n"
      "  out-of-range auto-reset, and transparent reconnect after\n"
      "  a broker restart.\n"
      "- Multi-broker clusters route produce/fetch to the partition\n"
      "  leader discovered from metadata.\n")
     out))
  #:exists 'replace)

;; Public EventBus guide: the service surface and how to run
;; the demos. Deliberately free of private-repo paths.
(call-with-output-file (build-path out-dir "EVENTBUS.md")
  (lambda (out)
    (display
     (string-append
      "# Event bus over gRPC\n"
      "\n"
      "`proto/events.proto` (`grpcdc.events.v1.EventBus`) is a\n"
      "publish/subscribe event bus defined as a gRPC service and\n"
      "generated — broker and clients — in every supported\n"
      "language, browser and native. Publishers attach typed\n"
      "routing tags (string, int64, double, bool, or any enum by\n"
      "number); subscribers declare a containment filter and\n"
      "receive every event whose tags contain all filter pairs.\n"
      "The broker assigns a global sequence number (1-based, in\n"
      "publish order) and a wall-clock timestamp to each event.\n"
      "\n"
      "## Run a demo\n"
      "\n"
      "```sh\n"
      "python3 python/examples/eventbus_demo.py\n"
      "node js/examples/eventbus_demo.js\n"
      "```\n"
      "\n"
      "Each demo starts a broker, subscribes with a topic filter,\n"
      "publishes three events, and prints what the filter admits.\n"
      "A git-backed broker variant (`eventbus_git`) persists the\n"
      "event log to a git repository for durable, inspectable\n"
      "history.\n"
      "\n"
      "## Service surface\n"
      "\n"
      "- `Publish(tags, payload, publisher_id)` → broker sequence.\n"
      "- `Subscribe(filter)` → stream of events matching the\n"
      "  containment filter (empty filter receives all events).\n")
     out))
  #:exists 'replace)

;; ---------------------------------------------------------------------------
;; Dedicated kafka-proxy repo export (browser-grpc/kafka-proxy):
;; a standalone subset of the main export — the Rust runtime,
;; the kafka_proxy example, fixtures the crate tests include,
;; proto, and the public Kafka guide — plus its own README,
;; CI Dockerfile, e2e runner, and GitHub workflow, so users can
;; build, run, and test the proxy without the main repo. Same
;; leak rule: no Racket source ever crosses.
;; ---------------------------------------------------------------------------

(define (emit-kp-file rel text [mode #f])
  (define dest (build-path kafka-proxy-out rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest
    (lambda (out) (display text out)) #:exists 'replace)
  (when mode (file-or-directory-permissions dest mode)))

(when (non-empty-string? kafka-proxy-out)
  (when (directory-exists? kafka-proxy-out)
    (delete-directory/files kafka-proxy-out))
  (make-directory* kafka-proxy-out)
  (for ([dir (in-list '("rust" "webrtc/rust" "proto" "fixtures"))])
    (make-directory* (path-only (build-path kafka-proxy-out dir)))
    (copy-directory/files (build-path out-dir dir)
                          (build-path kafka-proxy-out dir)))
  (for ([f (in-list '("LICENSE" "KAFKA.md"))])
    (copy-file (build-path out-dir f) (build-path kafka-proxy-out f) #t))
  (make-directory* (build-path kafka-proxy-out "docker"))
  (copy-file (build-path out-dir "docker/kafka-proxy.Dockerfile")
             (build-path kafka-proxy-out "docker/kafka-proxy.Dockerfile") #t)
  (emit-kp-file
   "RELEASE.json"
   (string-append "{\n  \"version\": \"" version "\",\n"
                  "  \"sourceCommit\": \"" source-commit "\",\n"
                  "  \"generated\": true\n}\n"))
  (emit-kp-file
   "README.md"
   (string-append
    "# Kafka over gRPC — proxy\n"
    "\n"
    "A Rust proxy that exposes an Apache Kafka or Redpanda cluster as\n"
    "the generated `grpcdc.kafka.v1.Kafka` gRPC service (see\n"
    "[KAFKA.md](KAFKA.md)). Generated clients in every language —\n"
    "from the main [grpc-over-datachannels](https://github.com/browser-grpc/grpc-over-datachannels)\n"
    "repo, browser and native — reach Kafka through it over stdio,\n"
    "length-prefixed TCP, or a WebRTC DataChannel.\n"
    "\n"
    "**Watch:** [Kafka over gRPC: A Rust Kafka Proxy With Generated "
    "Clients](https://youtu.be/KJ98a4ApZ4E) — narrated walkthrough "
    "with a live demo against Apache Kafka. Background: [Kafka over "
    "gRPC](https://c100k.blogspot.com/2026/10/kafka-over-grpc-rust-kafka-proxy-with.html) "
    "on the project blog.\n"
    "\n"
    "This repository is a generated export (version " version "); the\n"
    "proxy sources live in `rust/examples/kafka_proxy/`.\n"
    "\n"
    "## Run\n"
    "\n"
    "```sh\n"
    "docker run --rm ghcr.io/browser-grpc/kafka-proxy:latest \\\n"
    "  --tcp 0.0.0.0:50201 --broker kafka:9092\n"
    "```\n"
    "\n"
    "Or build it here:\n"
    "\n"
    "```sh\n"
    "docker build -f docker/kafka-proxy.Dockerfile -t kafka-proxy .\n"
    "cd rust && cargo build --release --features kafka-tls,webrtc \\\n"
    "  --example kafka_proxy\n"
    "```\n"
    "\n"
    "## Tests\n"
    "\n"
    "The end-to-end suite (produce/consume, consumer groups,\n"
    "transactions, compression, restart resume) runs against real\n"
    "Apache Kafka and Redpanda fixtures inside Docker — nothing to\n"
    "install:\n"
    "\n"
    "```sh\n"
    "docker build -f docker/kafka-proxy-ci.Dockerfile -t kafka-proxy-ci .\n"
    "docker run --rm kafka-proxy-ci\n"
    "```\n"
    "\n"
    "GitHub Actions runs the same image on every push.\n"))
  (emit-kp-file
   "docker/kafka-proxy-ci.Dockerfile"
   (string-append
    "# Kafka proxy CI — generated. DO NOT EDIT.\n"
    "# Builds the proxy and runs the Rust e2e suite against real\n"
    "# Apache Kafka + Redpanda fixtures, all inside the image.\n"
    "#   docker build -f docker/kafka-proxy-ci.Dockerfile -t kafka-proxy-ci .\n"
    "#   docker run --rm kafka-proxy-ci\n"
    "FROM rust:1-bookworm\n"
    "RUN apt-get update && apt-get install -y --no-install-recommends default-jdk-headless curl ca-certificates procps && rm -rf /var/lib/apt/lists/*\n"
    "RUN curl -fsSL https://downloads.apache.org/kafka/4.3.1/kafka_2.13-4.3.1.tgz -o /tmp/kafka.tgz && mkdir -p /opt/kafka && tar -xzf /tmp/kafka.tgz -C /opt/kafka --strip-components=1 && rm /tmp/kafka.tgz\n"
    "RUN curl -fsSL https://linux.pkg.redpanda.com/setup-redpanda.deb.sh | bash && apt-get update && apt-get install -y --no-install-recommends redpanda && rm -rf /var/lib/apt/lists/*\n"
    "ENV KAFKA_HOME=/opt/kafka\n"
    "WORKDIR /src\n"
    "COPY rust ./rust\n"
    "COPY webrtc/rust ./webrtc/rust\n"
    "COPY proto ./proto\n"
    "COPY fixtures ./fixtures\n"
    "COPY scripts/run-e2e.sh ./scripts/run-e2e.sh\n"
    "CMD [\"bash\", \"scripts/run-e2e.sh\"]\n"))
  (emit-kp-file
   "scripts/run-e2e.sh"
   (string-append
    "#!/usr/bin/env bash\n"
    "# Run the kafka_proxy Rust e2e suite against a real Apache\n"
    "# Kafka broker, then a real Redpanda broker. Brokers are\n"
    "# started here and killed on exit. Fails loudly if a broker\n"
    "# never opens its port (the suite skips itself without\n"
    "# KAFKA_PROXY_E2E_BROKER, so the port checks matter).\n"
    "set -uo pipefail\n"
    "ROOT=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")/..\" && pwd)\"\n"
    "KAFKA_HOME=\"${KAFKA_HOME:-/opt/kafka}\"\n"
    "REDPANDA_BIN=\"${REDPANDA_BIN:-$(command -v redpanda || echo /opt/redpanda/bin/redpanda)}\"\n"
    "TMP=\"$(mktemp -d)\"\n"
    "PIDS=()\n"
    "cleanup() {\n"
    "  for pid in \"${PIDS[@]:-}\"; do\n"
    "    [ -n \"$pid\" ] && kill \"$pid\" 2>/dev/null || true\n"
    "  done\n"
    "  rm -rf \"$TMP\"\n"
    "}\n"
    "trap cleanup EXIT\n"
    "port_open() {\n"
    "  (exec 3<>\"/dev/tcp/${1%:*}/${1##*:}\") 2>/dev/null && exec 3>&- 3<&-\n"
    "}\n"
    "wait_port() {\n"
    "  local deadline=$((SECONDS + $2))\n"
    "  while ! port_open \"$1\"; do\n"
    "    if [ $SECONDS -ge $deadline ]; then\n"
    "      echo \"FAIL: $3 did not open $1 within $2s\" >&2\n"
    "      return 1\n"
    "    fi\n"
    "    sleep 1\n"
    "  done\n"
    "  echo \"ok: $3 listening on $1\"\n"
    "}\n"
    "start_kafka() {\n"
    "  local props=\"$TMP/kafka.properties\"\n"
    "  cat > \"$props\" <<EOF\n"
    "process.roles=broker,controller\n"
    "node.id=1\n"
    "listeners=PLAINTEXT://0.0.0.0:19092,CONTROLLER://0.0.0.0:19094\n"
    "advertised.listeners=PLAINTEXT://127.0.0.1:19092\n"
    "controller.listener.names=CONTROLLER\n"
    "controller.quorum.voters=1@127.0.0.1:19094\n"
    "log.dirs=$TMP/kafka-logs\n"
    "offsets.topic.replication.factor=1\n"
    "transaction.state.log.replication.factor=1\n"
    "transaction.state.log.min.isr=1\n"
    "group.initial.rebalance.delay.ms=0\n"
    "num.partitions=1\n"
    "EOF\n"
    "  local cluster_id\n"
    "  cluster_id=\"$(\"$KAFKA_HOME/bin/kafka-storage.sh\" random-uuid)\" || return 1\n"
    "  \"$KAFKA_HOME/bin/kafka-storage.sh\" format -t \"$cluster_id\" -c \"$props\" --ignore-formatted >\"$TMP/kafka-format.log\" 2>&1 || return 1\n"
    "  \"$KAFKA_HOME/bin/kafka-server-start.sh\" \"$props\" >\"$TMP/kafka.log\" 2>&1 &\n"
    "  PIDS+=($!)\n"
    "  wait_port 127.0.0.1:19092 180 kafka || { tail -20 \"$TMP/kafka.log\" >&2; return 1; }\n"
    "}\n"
    "start_redpanda() {\n"
    "  local cfg=\"$TMP/redpanda.yaml\" rpk_bin broker_bin\n"
    "  rpk_bin=\"$(dirname \"$REDPANDA_BIN\")/rpk\"\n"
    "  [ -x \"$rpk_bin\" ] || rpk_bin=\"$(command -v rpk || true)\"\n"
    "  [ -n \"$rpk_bin\" ] || { echo \"FAIL: rpk not found\" >&2; return 1; }\n"
    "  broker_bin=\"$REDPANDA_BIN\"\n"
    "  [ -x \"$(dirname \"$REDPANDA_BIN\")/../libexec/redpanda\" ] && broker_bin=\"$(dirname \"$REDPANDA_BIN\")/../libexec/redpanda\"\n"
    "  mkdir -p \"$TMP/rp-data\"\n"
    "  \"$rpk_bin\" redpanda config bootstrap --config \"$cfg\" --self 127.0.0.1 >/dev/null || return 1\n"
    "  \"$rpk_bin\" redpanda config set --config \"$cfg\" redpanda.data_directory \"$TMP/rp-data\" >/dev/null || return 1\n"
    "  \"$rpk_bin\" redpanda config set --config \"$cfg\" redpanda.rpc_server \"{address: 127.0.0.1, port: 33145}\" >/dev/null || return 1\n"
    "  \"$rpk_bin\" redpanda config set --config \"$cfg\" redpanda.advertised_rpc_api \"{address: 127.0.0.1, port: 33145}\" >/dev/null || return 1\n"
    "  \"$rpk_bin\" redpanda config set --config \"$cfg\" redpanda.admin \"[{address: 127.0.0.1, port: 9644}]\" >/dev/null || return 1\n"
    "  \"$rpk_bin\" redpanda config set --config \"$cfg\" redpanda.kafka_api \"[{name: internal, address: 127.0.0.1, port: 19095}, {name: external, address: 127.0.0.1, port: 19093}]\" >/dev/null || return 1\n"
    "  \"$rpk_bin\" redpanda config set --config \"$cfg\" redpanda.advertised_kafka_api \"[{name: internal, address: 127.0.0.1, port: 19095}, {name: external, address: 127.0.0.1, port: 19093}]\" >/dev/null || return 1\n"
    "  \"$broker_bin\" --redpanda-cfg \"$cfg\" --smp 1 --memory 512M >\"$TMP/redpanda.log\" 2>&1 &\n"
    "  PIDS+=($!)\n"
    "  wait_port 127.0.0.1:19093 120 redpanda || { tail -20 \"$TMP/redpanda.log\" >&2; return 1; }\n"
    "}\n"
    "FAILED=0\n"
    "start_kafka || exit 1\n"
    "echo \"== rust e2e (apache kafka)\"\n"
    "(cd \"$ROOT/rust\" && KAFKA_PROXY_E2E_BROKER=127.0.0.1:19092 cargo test --locked --test kafka_proxy_e2e) || FAILED=1\n"
    "if [ -x \"$REDPANDA_BIN\" ] || command -v redpanda >/dev/null 2>&1; then\n"
    "  start_redpanda || FAILED=1\n"
    "  if [ \"$FAILED\" -eq 0 ]; then\n"
    "    echo \"== rust e2e (redpanda)\"\n"
    "    (cd \"$ROOT/rust\" && KAFKA_PROXY_E2E_BROKER=127.0.0.1:19093 cargo test --locked --test kafka_proxy_e2e) || FAILED=1\n"
    "  fi\n"
    "else\n"
    "  echo \"note: redpanda binary not found; kafka leg only\"\n"
    "fi\n"
    "exit \"$FAILED\"\n")
   #o755)
  (emit-kp-file
   ".github/workflows/ci.yml"
   (string-append
    "name: CI\n"
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "  pull_request:\n"
    "jobs:\n"
    "  e2e:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - uses: actions/checkout@v4\n"
    "      - name: Build CI image (brokers + toolchain)\n"
    "        run: docker build -f docker/kafka-proxy-ci.Dockerfile -t kafka-proxy-ci .\n"
    "      - name: Run e2e suite (Apache Kafka + Redpanda)\n"
    "        run: docker run --rm kafka-proxy-ci\n"
    "      - name: Build runtime image\n"
    "        run: docker build -f docker/kafka-proxy.Dockerfile -t kafka-proxy .\n"))
  ;; Leak gate for the subset export.
  (let* ([kp-files (find-files file-exists? kafka-proxy-out)]
         [kp-leaks
          (filter (lambda (p) (string-suffix? (path->string p) ".rkt"))
                  kp-files)])
    (unless (null? kp-leaks)
      (eprintf "releasegen: KAFKA-PROXY LEAK GATE FAILED:\n")
      (for ([p (in-list kp-leaks)]) (eprintf "  ~a\n" p))
      (exit 1))
    (printf "releasegen: kafka-proxy export: ~a files, leak gate OK\n"
            (length kp-files))))

;; ---------------------------------------------------------------------------
;; Dedicated eventbus repo export (browser-grpc/eventbus):
;; the events schema, the full dependency-free Python and
;; JavaScript trees (broker, clients, demos, tests run as-is),
;; and the generated EventBus sources for every other language
;; under gen/<lang>/ to drop into the main repo's runtimes —
;; plus its own README, CI/demo Dockerfiles, and workflow.
;; Same leak rule: no Racket source ever crosses.
;; ---------------------------------------------------------------------------

(define (emit-eb-file rel text [mode #f])
  (define dest (build-path eventbus-out rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest
    (lambda (out) (display text out)) #:exists 'replace)
  (when mode (file-or-directory-permissions dest mode)))

(when (non-empty-string? eventbus-out)
  (when (directory-exists? eventbus-out)
    (delete-directory/files eventbus-out))
  (make-directory* eventbus-out)
  (for ([dir (in-list '("python" "js"))])
    (copy-directory/files (build-path out-dir dir)
                          (build-path eventbus-out dir)))
  (make-directory* (build-path eventbus-out "proto"))
  (copy-file (build-path out-dir "proto/events.proto")
             (build-path eventbus-out "proto/events.proto") #t)
  (for ([f (in-list '("LICENSE" "GENERATED-CODE-LICENSE.md" "EVENTBUS.md"))])
    (copy-file (build-path out-dir f) (build-path eventbus-out f) #t))
  ;; Generated EventBus sources for the remaining languages.
  (for ([lang (in-list languages)]
        #:unless (member (cdr lang) '("python" "js")))
    (define src-dir (build-path out-dir (cdr lang)))
    (when (directory-exists? src-dir)
      (for ([p (in-list (find-files file-exists? src-dir))]
            #:when (regexp-match? #rx"(?i:eventbus|events_)"
                                  (path->string (file-name-from-path p))))
        (define rel (find-relative-path src-dir p))
        (define dest (build-path eventbus-out "gen" (cdr lang) rel))
        (make-directory* (path-only dest))
        (copy-file p dest #t))))
  (emit-eb-file
   "RELEASE.json"
   (string-append "{\n  \"version\": \"" version "\",\n"
                  "  \"sourceCommit\": \"" source-commit "\",\n"
                  "  \"generated\": true\n}\n"))
  (emit-eb-file
   "README.md"
   (string-append
    "# Event bus over gRPC\n"
    "\n"
    "A publish/subscribe event bus defined as one gRPC service,\n"
    "`grpcdc.events.v1.EventBus` (see [EVENTBUS.md](EVENTBUS.md)),\n"
    "with the broker and clients **generated in every language** —\n"
    "browser and native — by [grpc-over-datachannels](https://github.com/browser-grpc/grpc-over-datachannels).\n"
    "Publishers attach typed routing tags; subscribers declare a\n"
    "containment filter; the broker assigns global sequence\n"
    "numbers. A git-backed broker variant persists the log.\n"
    "\n"
    "This repository is a generated export (version " version ").\n"
    "\n"
    "## Run the demo\n"
    "\n"
    "```sh\n"
    "docker run --rm ghcr.io/browser-grpc/eventbus-demo:latest\n"
    "```\n"
    "\n"
    "Or here, no install (stdlib only):\n"
    "\n"
    "```sh\n"
    "python3 python/examples/eventbus_demo.py\n"
    "node js/examples/eventbus_demo.js\n"
    "```\n"
    "\n"
    "## Layout\n"
    "\n"
    "- `proto/events.proto` — the schema (source of truth).\n"
    "- `python/`, `js/` — complete dependency-free runtimes with\n"
    "  the generated broker, clients, demos, and tests.\n"
    "- `gen/<lang>/` — generated EventBus stubs, brokers, demos,\n"
    "  and tests for the other fourteen languages; drop them into\n"
    "  the matching runtime tree of the main repo.\n"
    "\n"
    "## Tests\n"
    "\n"
    "```sh\n"
    "docker build -f docker/eventbus-ci.Dockerfile -t eventbus-ci .\n"
    "docker run --rm eventbus-ci\n"
    "```\n"
    "\n"
    "GitHub Actions runs the same image on every push. Background:\n"
    "[A generated event bus](https://c100k.blogspot.com/2026/10/a-generated-event-bus-publishsubscribe.html).\n"))
  (emit-eb-file
   "docker/eventbus-ci.Dockerfile"
   (string-append
    "# EventBus CI — generated. DO NOT EDIT.\n"
    "# Runs the Python + JavaScript event bus suites and demos.\n"
    "#   docker build -f docker/eventbus-ci.Dockerfile -t eventbus-ci .\n"
    "#   docker run --rm eventbus-ci\n"
    "FROM python:3.13-slim\n"
    "RUN apt-get update && apt-get install -y --no-install-recommends nodejs git && rm -rf /var/lib/apt/lists/*\n"
    "WORKDIR /src\n"
    "COPY proto ./proto\n"
    "COPY python ./python\n"
    "COPY js ./js\n"
    "COPY gen ./gen\n"
    "CMD [\"bash\", \"-c\", \"python3 -m unittest discover -s python/tests -p 'test_eventbus.py' && python3 python/examples/eventbus_demo.py && node --test js/test/eventbus.test.js && node js/examples/eventbus_demo.js\"]\n"))
  (emit-eb-file
   "docker/eventbus-demo.Dockerfile"
   (string-append
    "# EventBus demo — generated. DO NOT EDIT.\n"
    "#   docker build -f docker/eventbus-demo.Dockerfile -t eventbus-demo .\n"
    "#   docker run --rm eventbus-demo\n"
    "FROM python:3.13-slim\n"
    "WORKDIR /src\n"
    "COPY proto ./proto\n"
    "COPY python ./python\n"
    "CMD [\"python3\", \"python/examples/eventbus_demo.py\"]\n"))
  (emit-eb-file
   ".github/workflows/ci.yml"
   (string-append
    "name: CI\n"
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "  pull_request:\n"
    "jobs:\n"
    "  eventbus:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - uses: actions/checkout@v4\n"
    "      - name: Build CI image\n"
    "        run: docker build -f docker/eventbus-ci.Dockerfile -t eventbus-ci .\n"
    "      - name: Run suites + demos (Python, JavaScript)\n"
    "        run: docker run --rm eventbus-ci\n"
    "      - name: Build and run demo image\n"
    "        run: docker build -f docker/eventbus-demo.Dockerfile -t eventbus-demo . && docker run --rm eventbus-demo\n"))
  ;; Leak gate for the subset export.
  (let* ([eb-files (find-files file-exists? eventbus-out)]
         [eb-leaks
          (filter (lambda (p) (string-suffix? (path->string p) ".rkt"))
                  eb-files)])
    (unless (null? eb-leaks)
      (eprintf "releasegen: EVENTBUS LEAK GATE FAILED:\n")
      (for ([p (in-list eb-leaks)]) (eprintf "  ~a\n" p))
      (exit 1))
    (printf "releasegen: eventbus export: ~a files, leak gate OK\n"
            (length eb-files))))

(call-with-output-file (build-path out-dir "docker-compose.yml")
  (lambda (out)
    (display
     (string-append
      "# Generated by grpc-dc codegen. DO NOT EDIT.\n"
      "#   docker compose up                    # interop proof + browser demo\n"
      "#   docker compose run go-test           # one language's test suite\n"
      "#   docker compose --profile starter up  # browser<->Node starter, signaling included\n"
      "#   docker compose --profile tunnel up   # same, plus a public trycloudflare.com URL\n"
      "services:\n"
      "  interop:\n"
      "    build: { context: ., dockerfile: docker/interop.Dockerfile }\n"
      "  app:\n"
      "    image: python:3.13-slim\n"
      "    command: python3 -m http.server 8080 --directory /site\n"
      "    volumes: [\"./docs:/site:ro\"]\n"
      "    ports: [\"8080:8080\"]\n"
      "  go-test:\n"
      "    build: { context: ., dockerfile: docker/go.Dockerfile }\n"
      "    profiles: [\"test\"]\n"
      "  starter:\n"
      "    image: node:24-bookworm-slim\n"
      "    working_dir: /src\n"
      "    command: node examples/starter/server.mjs\n"
      "    environment: [\"PORT=8080\"]\n"
      "    volumes: [\"./:/src:ro\"]\n"
      "    ports: [\"8080:8080\"]\n"
      "    profiles: [\"starter\", \"tunnel\"]\n"
      "  demo-go:\n"
      "    build: { context: ., dockerfile: docker/go.Dockerfile }\n"
      "    command: sh -c \"cd go && go test -run TestEchoAllShapesLoopback -v .\"\n"
      "    profiles: [\"demo\"]\n"
      "  demo-python:\n"
      "    build: { context: ., dockerfile: docker/python.Dockerfile }\n"
      "    command: sh -c \"cd python && python3 -m unittest tests.test_echo -v\"\n"
      "    profiles: [\"demo\"]\n"
      "  demo-rust:\n"
      "    build: { context: ., dockerfile: docker/rust.Dockerfile }\n"
      "    command: sh -c \"cd rust && cargo test --test echo_e2e\"\n"
      "    profiles: [\"demo\"]\n"
      "  demo-js:\n"
      "    image: node:24-bookworm-slim\n"
      "    working_dir: /src\n"
      "    volumes: [\"./:/src:ro\"]\n"
      "    command: node js/examples/echo_demo.js\n"
      "    profiles: [\"demo\"]\n"
      "  browser-examples:\n"
      "    image: node:24-bookworm-slim\n"
      "    working_dir: /src\n"
      "    command: node examples/browser/server.mjs\n"
      "    environment: [\"PORT=8080\"]\n"
      "    volumes: [\"./:/src:ro\"]\n"
      "    ports: [\"8080:8080\"]\n"
      "    profiles: [\"browser-examples\", \"tunnel-browser\"]\n"
      "  tunnel:\n"
      "    image: cloudflare/cloudflared:latest\n"
      "    command: tunnel --no-autoupdate --url http://starter:8080\n"
      "    depends_on: [starter]\n"
      "    profiles: [\"tunnel\"]\n"
      "  tunnel-browser:\n"
      "    image: cloudflare/cloudflared:latest\n"
      "    command: tunnel --no-autoupdate --url http://browser-examples:8080\n"
      "    depends_on: [browser-examples]\n"
      "    profiles: [\"tunnel-browser\"]\n"
      "  tunnel-app:\n"
      "    image: cloudflare/cloudflared:latest\n"
      "    command: tunnel --no-autoupdate --url http://app:8080\n"
      "    depends_on: [app]\n"
      "    profiles: [\"tunnel-app\"]\n")
     out))
  #:exists 'replace)

(define getting-started
  (string-append
   "\n## Getting started (Docker, no toolchain install)\n\n"
   "Every language's test suite in one command pair:\n\n"
   (apply string-append
          (for/list ([spec (in-list docker-specs)])
            (format "    docker build -f docker/~a.Dockerfile -t grpc-dc-~a .\n    docker run --rm grpc-dc-~a\n"
                    (first spec) (first spec) (first spec))))
   "\nOr `docker compose up` for the cross-language interop proof\n"
   "plus the browser demo on http://localhost:8080 (generator with\n"
   "a schema preloaded: http://localhost:8080/app/#schema=echo&lang=go).\n"))

;; ---------------------------------------------------------------------------
;; Generated public files: README, docs landing, provenance.
;; ---------------------------------------------------------------------------

(define language-rows
  (apply string-append
         (for/list ([lang (in-list languages)])
           (format "| ~a | [`~a/`](~a/) · [readme](~a/README.md) · [gallery](docs/gallery.html#~a) |\n"
                   (car lang) (cdr lang) (cdr lang) (cdr lang) (cdr lang)))))

(define readme
  (string-append
   "# gRPC over WebRTC DataChannels — in the browser and natively\n\n"
   "<p align=\"center\"><img src=\"docs/badger/honey-badger-256.png\" width=\"160\" alt=\"Honey badger mascot — grpc-over-datachannels: small, fearless, goes anywhere the web goes\"></p>\n\n"
   "[![Release](https://img.shields.io/github/v/release/browser-grpc/grpc-over-datachannels?label=release)](https://github.com/browser-grpc/grpc-over-datachannels/releases)\n"
   "[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)\n"
   "[![Live generator](https://img.shields.io/badge/live%20generator-browser--grpc.github.io-brightgreen)](https://browser-grpc.github.io/grpc-over-datachannels/app/)\n"
   "[![npm](https://img.shields.io/npm/v/grpc-dc?label=npm%20grpc-dc)](https://www.npmjs.com/package/grpc-dc)\n\n"
   "![gRPC in the browser over WebRTC DataChannels](docs/social-preview.png)\n\n"
   "![Guided first run: generate a client and call it, entirely in the browser](docs/first-run.gif)\n\n"
   "**New here? Start with [QUICKSTART.md](QUICKSTART.md)** — your\n"
   "first browser RPC in about five lines, a Docker client/server\n"
   "pair, and stubs for your own `.proto`. Or open the\n"
   "[live generator](https://browser-grpc.github.io/grpc-over-datachannels/app/)\n"
   "(also at [grpc-dc.lunchgamer.com](https://grpc-dc.lunchgamer.com/))\n"
   "and press **Run your first RPC**.\n\n"
   "**Project blog:** [grpc-over-datachannels — gRPC over WebRTC, "
   "Browser & Native](https://c100k.blogspot.com/) — launch notes, "
   "design posts, and release write-ups.\n\n"
   "**Watch:** [gRPC over WebRTC DataChannels — No HTTP/2, No "
   "Dependencies](https://youtu.be/LwrXpnlMlgA) and [Kafka over gRPC: "
   "A Rust Kafka Proxy](https://youtu.be/KJ98a4ApZ4E) — narrated "
   "walkthroughs with live demos, in the [grpc-over-datachannels "
   "playlist](https://www.youtube.com/playlist?list=PLL20oIw8Dg5U).\n\n"
   "**Run gRPC in the browser.** grpc-over-datachannels speaks the\n"
   "gRPC wire protocol directly over WebRTC DataChannels, so a\n"
   "browser tab can call native services peer-to-peer — no grpc-web\n"
   "proxy, no translating gateway, no external gRPC runtime.\n"
   "Generate dependency-free gRPC clients and servers for\n"
   "JavaScript (browser + Node), Go, Rust, Python, and 12 more\n"
   "languages from the same `.proto` schemas. Browser clients use\n"
   "the native `RTCDataChannel`; other languages also run in the\n"
   "browser as Wasm. Every runtime is generated and dependency-free,\n"
   "on a reimplemented WebRTC stack (ICE/DTLS/SCTP) with native and\n"
   "browser clients and servers.\n\n"
   "Try the [live in-browser generator](https://browser-grpc.github.io/grpc-over-datachannels/app/):\n"
   "paste a `.proto`, get protoc stubs for every language. Keywords:\n"
   "`grpc`, `grpc-web alternative`, `webrtc`, `datachannel`,\n"
   "`rtcdatachannel`, `protobuf`, `protoc plugin`, `wasm`,\n"
   "`browser rpc`, `peer-to-peer`.\n\n"
   "This repository is a generated public export (version " version ")\n"
   "of the grpc-over-datachannels project. Generated code may be used\n"
   "without restriction (see GENERATED-CODE-LICENSE.md); everything\n"
   "else is Apache-2.0 (see LICENSE).\n\n"
   "## Languages\n\n"
   "| Language | Runtime + stubs |\n|---|---|\n"
   language-rows
   "| WebRTC stack | [`webrtc/`](webrtc/) |\n"
   "| Wasm facades + native Wasm | [`wasm/`](wasm/) |\n"
   getting-started
   "\n"
   "## Try it in the browser\n\n"
   "The [live generator](https://browser-grpc.github.io/grpc-over-datachannels/app/)\n"
   "runs the real protoc plugins in your browser (schema in,\n"
   "generated code out, for every language) and the app's Browse tab\n"
   "shows generated clients — including a JavaScript browser client\n"
   "on the native `RTCDataChannel` — for every bundled schema. No\n"
   "server, no install. Deep link to the JavaScript client:\n"
   "https://browser-grpc.github.io/grpc-over-datachannels/app/#schema=echo&lang=js\n\n"
   "Browser examples in every Wasm language (Echo client in\n"
   "the page, generated server on the Node stack):\n\n"
   "    docker compose --profile browser-examples up   # http://localhost:8080/\n"
   "    docker compose --profile tunnel-browser up     # same, on a public URL\n\n"
   "## Generate with protoc (Node)\n\n"
   "The same generators ship as a dependency-free Node protoc\n"
   "plugin, `docs/app/protoc-gen-grpc-dc.mjs`. Link it under one\n"
   "name per language and generate natively:\n\n"
   "    ln -s \"$PWD/docs/app/protoc-gen-grpc-dc.mjs\" ~/bin/protoc-gen-grpc-dc-rust\n"
   "    protoc --plugin=protoc-gen-grpc-dc-rust=$HOME/bin/protoc-gen-grpc-dc-rust \\\n"
   "           --grpc-dc-rust_out=out -I . echo.proto\n\n"
   "## IoT / embedded\n\n"
   "The WebRTC stack under `webrtc/rust` is `no_std` (it cross-builds\n"
   "for Cortex-M): platform traits inject clock, entropy, and the\n"
   "datagram transport, and an in-crate net stack provides Ethernet\n"
   "framing, ARP, IPv4/IPv6, UDP, and DHCP — WebRTC with no OS at\n"
   "all. Two-device bring-up over a virtual cable, power-on to\n"
   "DataChannel echo:\n\n"
   "    cargo run --example iot_cable   # in webrtc/rust\n\n"
   "Small generated runtimes (C99, Lua) target constrained hosts;\n"
   "every generated runtime is dependency-free.\n\n"
   "## Single-socket serving (PeerMux)\n\n"
   "The Rust, Go, and JS (Node) stacks can host many signaled\n"
   "peers on one bound UDP socket: `PeerMux` routes STUN by ICE\n"
   "ufrag, the first DTLS flight by a pair-hint extension, and\n"
   "every later DTLS record by its RFC 9146 connection id, so\n"
   "a server needs exactly one open port for all its peer\n"
   "connections (the single-port topology of Jitsi/Pion) —\n"
   "and two muxes can peer with each other, since records no\n"
   "longer route by source address. TURN also works on muxed\n"
   "peers (the allocation's UDP leg rides a dedicated per-peer\n"
   "socket). See `webrtc/rust/src/mux.rs`,\n"
   "`webrtc/go/mux.go`, `webrtc/js/mux.js`; one generated\n"
   "scenario tests all three stacks, and the cross-stack\n"
   "matrix pairs mux against mux across stacks.\n\n"
   "Stuck? See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)\n"
   "(secure context, signaling, TURN/NAT, WebKit fallback, transports).\n\n"
   "## Verify the browser story\n\n"
   "The `browser-test/` directory carries the real-browser\n"
   "harness (Playwright). From a clone:\n\n"
   "    cd browser-test && npm ci && npx playwright install chromium\n"
   "    node bdd.test.mjs all   # BDD scenarios in a real browser\n\n"
   "Suites needing Rust harness binaries or TURN servers say\n"
   "so in their headers; the BDD suite is self-contained.\n\n"
   "No install, on any device: `docker compose --profile tunnel up`\n"
   "serves this site through a temporary Cloudflare quick tunnel and\n"
   "prints a public `https://*.trycloudflare.com` URL (WebRTC needs\n"
   "the HTTPS secure context off localhost). The URL is random per\n"
   "run and demo-only; DataChannel traffic stays peer-to-peer and\n"
   "never passes through the tunnel.\n\n"
   "## Behavior specification\n\n"
   "The wire behavior is specified as generated BDD scenarios; see\n"
   "[BDD.md](BDD.md) (also rendered under `docs/`). The same scenario\n"
   "table runs natively in every language above and in real browsers.\n\n"
   "## Provenance\n\n"
   "Exported from source commit `" source-commit "` by the project's\n"
   "code generator. This tree contains no build system: each language\n"
   "directory carries its runtime, generated stubs, examples, and\n"
   "tests in that language's usual layout.\n"))

(call-with-output-file (build-path out-dir "README.md")
  (lambda (out) (display readme out)) #:exists 'replace)

;; Newcomer path: three copy-paste routes (browser first call,
;; Docker client/server pair, own .proto stubs). Curated deep
;; links land on code (a generated JS browser client), not prose.
(define quickstart
  (string-append
   "# Quickstart\n\n"
   "Three paths, shortest first. Everything is dependency-free:\n"
   "generated runtimes use only each language's standard library.\n\n"
   "## 1. Your first RPC in the browser (2 minutes, no install)\n\n"
   "Open the [live generator](https://browser-grpc.github.io/grpc-over-datachannels/app/)\n"
   "and press **Run your first RPC**. The page generates the Echo\n"
   "client from the bundled schema, serves it in-page over a\n"
   "loopback DataChannel pair (the same transport a real\n"
   "`RTCDataChannel` plugs into), and shows the calls plus the\n"
   "~10 lines of JavaScript you would write:\n\n"
   "```js\n"
   "import { Channel, Server, memoryDataChannelPair } from \"grpc-dc\";\n"
   "import { EchoClient, createEchoService } from \"./echo_grpc_dc.js\";\n"
   "import { EchoRequest } from \"./echo_pb.js\";\n\n"
   "const [a, b] = memoryDataChannelPair();\n"
   "const server = new Server();\n"
   "server.addService(createEchoService({ /* your handlers */ }));\n"
   "server.serve(b);\n\n"
   "const client = new EchoClient(new Channel(a));\n"
   "const reply = await client.unary(new EchoRequest({ message: \"hello\" }));\n"
   "console.log(reply.message); // echo: hello\n"
   "```\n\n"
   "In production the loopback pair is replaced by a real\n"
   "`RTCDataChannel` from two `RTCPeerConnection`s (or a native\n"
   "peer); `Channel` and the generated client do not change.\n"
   "Install the runtime with `npm install grpc-dc` (or copy the\n"
   "`js/` directory — it has no dependencies either way). The\n"
   "package ships TypeScript declarations (`index.d.ts`), so the\n"
   "runtime is typed in TS projects.\n\n"
   "## 2. Browser client ↔ native server (5 minutes)\n\n"
   "The runnable step-2 sample pairs a real browser client with\n"
   "the native stack server (SDP exchanged as plain text — swap\n"
   "in WebSocket/fetch signaling in your app):\n\n"
   "    node browser-test/native_step2.mjs chromium\n\n"
   "Or run the self-contained starter (WebSocket signaling\n"
   "included, nothing to install):\n\n"
   "    node examples/starter/server.mjs   # then open http://localhost:8080/\n\n"
   "Expected: `step2 (chromium): browser gRPC client -> native "
   "stack server OK { unary: 'echo: hello', ticks: [ 0, 1, 2 ], "
   "echoed: [ 'x', 'y' ] }`. Chromium, Firefox, and WebKit all\n"
   "work. For native-to-native and cross-language proofs, each\n"
   "language image runs its full suite and the interop image\n"
   "pairs clients and servers across languages:\n\n"
   "No toolchain install; each image runs that language's full\n"
   "test suite, and the interop image pairs clients and servers\n"
   "across languages:\n\n"
   "    git clone https://github.com/browser-grpc/grpc-over-datachannels\n"
   "    cd grpc-over-datachannels\n"
   "    docker build -f docker/go.Dockerfile -t grpc-dc-go .\n"
   "    docker run --rm grpc-dc-go\n"
   "    docker compose up   # interop proof + browser demo on :8080\n\n"
   "Then open http://localhost:8080/app/#schema=echo&lang=js for\n"
   "the generated JavaScript browser client.\n\n"
   "## 3. Stubs for your own .proto\n\n"
   "In the browser: paste your schema into the live generator,\n"
   "tick your language, download the zip (stubs + runtime +\n"
   "README, runs as-is). On the command line with protoc:\n\n"
   "    ln -s \"$PWD/docs/app/protoc-gen-grpc-dc.mjs\" ~/bin/protoc-gen-grpc-dc-js\n"
   "    protoc --plugin=protoc-gen-grpc-dc-js=$HOME/bin/protoc-gen-grpc-dc-js \\\n"
   "           --grpc-dc-js_out=out -I . your.proto\n\n"
   "One wrapper per language ships in `bin/`. Per-language\n"
   "details (first run, regenerate, API tour) are in each\n"
   "language's `README.md` — e.g. [`js/README.md`](js/README.md).\n"))
(call-with-output-file (build-path out-dir "QUICKSTART.md")
  (lambda (out) (display quickstart out)) #:exists 'replace)

;; Per-language newcomer READMEs: where things live, the first
;; command to run (the same command the Docker image runs), how
;; to regenerate stubs, and where the typed API surface is.
(define per-language-readmes
  (hash
   "js" (list "JavaScript (browser + Node)"
              "node js/examples/echo_demo.js   # all four method shapes, in-memory pair\n    node --test js/test/*.test.js   # full suite"
              "npm install grpc-dc — or copy this directory; there are no dependencies. TypeScript types ship in `index.d.ts`.")
   "python" (list "Python"
                  "cd python && python3 -m unittest discover -s tests"
                  "pip users: `pip install ./python` installs the `grpcdc` package from this tree (pyproject.toml included, no dependencies).")
   "go" (list "Go"
              "cd go && go test ./..."
              "Fetch it like any module: `go get github.com/browser-grpc/grpc-over-datachannels/go` (the WebRTC stack arrives as its sibling module `.../webrtc/go`) — or copy this directory into your module tree.")
   "rust" (list "Rust"
                "cd rust && cargo test"
                "Add the crate by path: `grpc-dc = { path = \"rust\" }` in Cargo.toml. No external crates.")
   ))
(define (emit-language-readme dir)
  (define spec (hash-ref per-language-readmes dir #f))
  (define name
    (car (or (for/first ([l (in-list languages)] #:when (equal? (cdr l) dir)) l)
             '("grpc-dc"))))
  (define body
    (if spec
        (string-append
         "# " (first spec) " — grpc-dc runtime\n\n"
         "Start here if you are new to the project. The runtime in\n"
         "this directory is generated, dependency-free, and speaks\n"
         "the gRPC wire protocol over WebRTC DataChannels.\n\n"
         "## First run\n\n```sh\n    " (second spec) "\n```\n\n"
         "## Use it in your project\n\n" (third spec) "\n\n"
         "## Regenerate stubs for your schema\n\n"
         "From the repository root (one wrapper per language in `bin/`):\n\n"
         "    protoc --plugin=protoc-gen-grpc-dc-" dir "=$PWD/bin/protoc-gen-grpc-dc-" dir " \\\n"
         "           --grpc-dc-" dir "_out=out -I . your.proto\n\n"
         "Or generate in the browser and download the zip:\n"
         "https://browser-grpc.github.io/grpc-over-datachannels/app/\n\n"
         "## Where things live\n\n"
         "- Runtime: this directory (see its generated sources).\n"
         "- Worked example: `examples/` (Echo in every method shape).\n"
         "- Tests: `tests/` — the same BDD scenarios every language runs.\n\n"
         "Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).\n")
        (string-append
         "# " name " — grpc-dc runtime\n\n"
         "Generated, dependency-free gRPC-over-DataChannels runtime\n"
         "with Echo stubs, examples, and tests in this directory.\n\n"
         "## First run (Docker, no toolchain install)\n\n"
         "    docker build -f docker/" dir ".Dockerfile -t grpc-dc-" dir " .\n"
         "    docker run --rm grpc-dc-" dir "\n\n"
         "## Regenerate stubs for your schema\n\n"
         "    protoc --plugin=protoc-gen-grpc-dc-" dir "=$PWD/bin/protoc-gen-grpc-dc-" dir " \\\n"
         "           --grpc-dc-" dir "_out=out -I . your.proto\n\n"
         "Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).\n")))
  (call-with-output-file (build-path out-dir dir "README.md")
    (lambda (out) (display body out)) #:exists 'replace))
(for ([lang (in-list languages)]) (emit-language-readme (cdr lang)))

(call-with-output-file (build-path out-dir "docs/BDD.md")
  (lambda (out) (display (file->string "BDD.md") out)) #:exists 'replace)

;; Language gallery: the same Echo server in every language,
;; source taken from the exported corpus examples, with the
;; stdio transcript captured at export time
;; (make transcripts). Generated from the corpus so it
;; cannot drift from the code that ships.
(define (gallery-lang lang)
  (define name (car lang))
  (define dir (cdr lang))
  (define corpus (build-path "webapp/assets/corpus" dir "examples"))
  (define server-file
    (and (directory-exists? corpus)
         (for/first ([f (in-list (directory-list corpus))]
                     #:when (and (file-exists? (build-path corpus f))
                                 (regexp-match? #rx"(?i:server)" (path->string f))))
           f)))
  (string-append
   "## " name "\n\n"
   (if server-file
       (string-append
        "```" dir "\n"
        (file->string (build-path corpus (path->string server-file)))
        "```\n\n")
       "_(no stdio server example in the corpus)_\n\n")
   "Test suite in Docker:\n\n"
   "    docker build -f docker/" dir ".Dockerfile -t grpc-dc-" dir " .\n"
   "    docker run --rm grpc-dc-" dir "\n\n"
   (let ([t (build-path "webapp/assets/transcripts" (string-append dir ".txt"))])
     (if (file-exists? t)
         (string-append
          "Stdout/stderr transcript (stdio client -> own server,\n"
          "captured when this export was built):\n\n```\n"
          (file->string t) "```\n\n")
         ""))))

(call-with-output-file (build-path out-dir "docs/TROUBLESHOOTING.md")
  (lambda (out)
    (display
     (string-append
      "# Troubleshooting\n\n"
      "## The page cannot create a DataChannel / crypto is unavailable\n\n"
      "WebRTC requires a secure context: `https://`, `http://localhost`, or a\n"
      "`trycloudflare.com` tunnel URL all qualify; a plain `http://` LAN address\n"
      "does not. Use the live site, `make webapp-serve`, or\n"
      "`docker compose --profile tunnel up`.\n\n"
      "## Which signaling should I use?\n\n"
      "Any channel that moves text: WebSocket, fetch POST, a message broker,\n"
      "or manual copy-paste. Only the SDP offer/answer crosses it (a few KB);\n"
      "gRPC traffic never does. The starter in `examples/starter/` shows the\n"
      "smallest WebSocket version. Swap the transport, keep the SDP handling.\n\n"
      "## Peers connect on localhost but not across machines\n\n"
      "That is NAT, not gRPC: ICE needs a TURN relay when both sides are\n"
      "behind symmetric NATs. Point the peer at a TURN server (the repo's\n"
      "WebRTC stacks accept TURN URLs/credentials), or test through the\n"
      "Cloudflare tunnel profile. DataChannel traffic stays peer-to-peer;\n"
      "the tunnel only serves the page and signaling.\n\n"
      "## WebKit shows the fallback generators\n\n"
      "Expected in some WebKit builds: the full plugin runtime cannot mount\n"
      "its filesystem there, so the app uses the built-in generators. Output\n"
      "is byte-identical either way (the parity suite pins this). For the\n"
      "full plugin path, use Chromium or Firefox, or generate with the\n"
      "`bin/protoc-gen-grpc-dc-*` wrappers locally.\n\n"
      "## What plugs into `Channel` / `Server.serve`?\n\n"
      "Anything with the DataChannel shape: a browser `RTCDataChannel`, the\n"
      "in-repo Node/Rust/Go stack channel, an in-memory pair\n"
      "(`memoryDataChannelPair` in JS), or a sidecar-bridged channel in the\n"
      "other languages. The generated client and server do not change when\n"
      "the transport does.\n\n"
      "## A call hangs with no error\n\n"
      "Check, in order: (1) both peers agree on the channel label (the gRPC\n"
      "convention here is `grpc`); (2) the server actually called `serve`\n"
      "on the accepted channel; (3) odd/even stream-id parity is not shared\n"
      "by two clients on one channel; (4) deadlines — a streaming call\n"
      "returns an async iterable, so `await` it before iterating.\n")
     out))
  #:exists 'replace)

(call-with-output-file (build-path out-dir "docs/gallery.md")
  (lambda (out)
    (display
     (string-append
      "# Echo in every language\n\n"
      "The same Echo service — unary, server-streaming,\n"
      "client-streaming, and bidi — implemented per language\n"
      "over the generated runtime. Server sources below are\n"
      "the exported corpus examples; transcripts are real\n"
      "stdio client->server runs captured at export time.\n\n"
      (apply string-append (map gallery-lang languages)))
     out))
  #:exists 'replace)

;; HTML gallery: same generated content, but browsable with
;; per-language anchors (the README language table and landing
;; page link here, not at raw Markdown).
(define (html-escape s)
  (string-replace
   (string-replace
    (string-replace s "&" "&amp;") "<" "&lt;") ">" "&gt;"))
(define (gallery-lang-html lang)
  (define name (car lang))
  (define dir (cdr lang))
  (define corpus (build-path "webapp/assets/corpus" dir "examples"))
  (define server-file
    (and (directory-exists? corpus)
         (for/first ([f (in-list (directory-list corpus))]
                     #:when (and (file-exists? (build-path corpus f))
                                 (regexp-match? #rx"(?i:server)" (path->string f))))
           f)))
  (define transcript
    (build-path "webapp/assets/transcripts" (string-append dir ".txt")))
  (string-append
   "<section id=\"" dir "\">\n<h2>" name "</h2>\n"
   (if server-file
       (string-append
        "<pre><code>" (html-escape (file->string (build-path corpus (path->string server-file)))) "</code></pre>\n")
       "<p><em>No stdio server example in the corpus.</em></p>\n")
   "<p>Test suite in Docker:</p>\n"
   "<pre><code>docker build -f docker/" dir ".Dockerfile -t grpc-dc-" dir " .\n"
   "docker run --rm grpc-dc-" dir "</code></pre>\n"
   (if (file-exists? transcript)
       (string-append
        "<p>Stdio client &#8594; own server transcript, captured at export time:</p>\n"
        "<pre><code>" (html-escape (file->string transcript)) "</code></pre>\n")
       "")
   "</section>\n"))
(call-with-output-file (build-path out-dir "docs/gallery.html")
  (lambda (out)
    (display
     (string-append
      "<!doctype html>\n<html lang=\"en\">\n<head>\n"
      "<meta charset=\"utf-8\">\n"
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
      "<title>Echo in Every Language — gRPC over WebRTC DataChannels</title>\n"
      "<meta name=\"description\" content=\"The same Echo gRPC service implemented in 16 languages over WebRTC DataChannels: generated dependency-free runtimes, Docker test commands, and real transcripts.\">\n"
      "<link rel=\"canonical\" href=\"https://browser-grpc.github.io/grpc-over-datachannels/gallery.html\">\n"
      "</head>\n<body>\n"
      "<h1>Echo in every language</h1>\n"
      "<p>The same Echo service — unary, server-streaming, "
      "client-streaming, and bidi — per language over the "
      "generated runtime. Anchors: "
      (string-join
       (for/list ([lang (in-list languages)])
         (string-append "<a href=\"#" (cdr lang) "\">" (car lang) "</a>"))
       " · ")
      ".</p>\n"
      (apply string-append (map gallery-lang-html languages))
      "</body>\n</html>\n")
     out))
  #:exists 'replace)

;; Org profile README (published to browser-grpc/.github by
;; the push step's second phase; generated here so it stays
;; in sync with the language table).
(make-directory* (build-path out-dir "org-profile"))
(call-with-output-file (build-path out-dir "org-profile/README.md")
  (lambda (out)
    (display
     (string-append
      "# browser-grpc\n\n"
      "<p align=\"center\"><img src=\"https://browser-grpc.github.io/grpc-over-datachannels/badger/honey-badger-256.png\" width=\"160\" alt=\"Honey badger mascot — browser-grpc\"></p>\n\n"
      "**gRPC in the browser, over WebRTC DataChannels.** "
      "Dependency-free gRPC clients and servers for "
      (number->string (length languages))
      " languages that run in browser tabs (native RTCDataChannel, "
      "plus Wasm clients) and natively — no grpc-web proxy, no "
      "external gRPC runtime.\n\n"
      "Start in 60 seconds, no toolchain install:\n\n"
      "    git clone https://github.com/browser-grpc/grpc-over-datachannels\n"
      "    cd grpc-over-datachannels\n"
      "    docker build -f docker/go.Dockerfile -t grpc-dc-go .\n"
      "    docker run --rm grpc-dc-go\n\n"
      "Or generate stubs for your own schema in the browser:\n"
      "https://browser-grpc.github.io/grpc-over-datachannels/app/#schema=echo&lang=go\n\n"
      "Project blog (launch notes, design posts, releases): "
      "https://c100k.blogspot.com/\n")
     out))
  #:exists 'replace)

;; SEO/discoverability: keyword-forward title/description aimed
;; at web and browser developers, Open Graph cards, canonical
;; URL, and JSON-LD. All absolute URLs point at the live Pages
;; site (canonical home of the export).
(define site-url "https://browser-grpc.github.io/grpc-over-datachannels/")
(define seo-title
  "gRPC in the Browser over WebRTC DataChannels | grpc-over-datachannels")
(define seo-description
  (string-append
   "Run gRPC in the browser and natively over WebRTC DataChannels. "
   "Generate dependency-free gRPC clients and servers for JavaScript, "
   "TypeScript-ready JS, Go, Rust, Python and 11 more languages from "
   ".proto schemas — no grpc-web proxy, no external gRPC runtime. "
   "Live in-browser protoc generator plus native and Wasm clients."))
(define landing
  (string-append
   "<!doctype html>\n"
   "<html lang=\"en\">\n<head>\n"
   "<meta charset=\"utf-8\">\n"
   "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
   "<title>" seo-title "</title>\n"
   "<meta name=\"description\" content=\"" seo-description "\">\n"
   "<link rel=\"canonical\" href=\"" site-url "\">\n"
   "<meta property=\"og:type\" content=\"website\">\n"
   "<meta property=\"og:site_name\" content=\"grpc-over-datachannels\">\n"
   "<meta property=\"og:title\" content=\"" seo-title "\">\n"
   "<meta property=\"og:description\" content=\"" seo-description "\">\n"
   "<meta property=\"og:url\" content=\"" site-url "\">\n"
   "<link rel=\"icon\" href=\"favicon.ico\" sizes=\"16x16 32x32 48x48\">\n"
   "<link rel=\"icon\" type=\"image/png\" sizes=\"32x32\" href=\"badger/honey-badger-32.png\">\n"
   "<link rel=\"icon\" type=\"image/png\" sizes=\"16x16\" href=\"badger/honey-badger-16.png\">\n"
   "<link rel=\"apple-touch-icon\" sizes=\"180x180\" href=\"badger/honey-badger-180.png\">\n"
   "<meta property=\"og:image\" content=\"" site-url "social-preview.png\">\n"
   "<meta name=\"twitter:card\" content=\"summary_large_image\">\n"
   "<meta name=\"twitter:title\" content=\"" seo-title "\">\n"
   "<meta name=\"twitter:description\" content=\"" seo-description "\">\n"
   "<script type=\"application/ld+json\">\n"
   "{\"@context\":\"https://schema.org\",\"@type\":\"SoftwareSourceCode\","
   "\"name\":\"grpc-over-datachannels\","
   "\"description\":\"" seo-description "\","
   "\"codeRepository\":\"https://github.com/browser-grpc/grpc-over-datachannels\","
   "\"url\":\"" site-url "\","
   "\"programmingLanguage\":[\"JavaScript\",\"Go\",\"Rust\",\"Python\",\"Java\",\"C#\",\"C++\",\"Swift\",\"Kotlin\",\"Dart\",\"Zig\",\"Lua\",\"Ruby\",\"PHP\",\"Scala\",\"C\"],"
   "\"license\":\"https://www.apache.org/licenses/LICENSE-2.0\","
   "\"applicationCategory\":\"DeveloperApplication\","
   "\"operatingSystem\":\"Any (browser via WebRTC/Wasm, plus native)\"}\n"
   "</script>\n</head>\n<body>\n"
   "<p><img src=\"badger/honey-badger-128.png\" width=\"96\" height=\"96\" alt=\"Honey badger mascot\"></p>\n"
   "<h1>gRPC over WebRTC DataChannels</h1>\n"
   "<p><img src=\"first-run.gif\" alt=\"Guided first run: generate a gRPC client and call it in the browser\" width=\"720\"></p>\n"
   "<p>grpc-over-datachannels " version " — gRPC clients and servers "
   "that run <strong>in the browser</strong> over native WebRTC "
   "DataChannels, and natively in 16 languages, from the same "
   ".proto schemas. No grpc-web proxy and no external gRPC "
   "runtime: every runtime is generated and dependency-free.</p>\n"
   "<ul>\n"
   "<li><a href=\"app/\">In-browser protoc generator + live demo</a> — "
   "paste a .proto, get stubs for every language</li>\n"
   "<li><a href=\"app/#schema=echo&lang=js\">JavaScript/TypeScript browser client example</a></li>\n"
   "<li><a href=\"app/#schema=echo&lang=go\">Go generated client</a> · "
   "<a href=\"app/#schema=echo&lang=python\">Python generated messages</a> · "
   "<a href=\"app/#schema=shop&lang=js\">A larger schema (shop) in JavaScript</a></li>\n"
   "<li><a href=\"gallery.html\">Echo server in every language</a> "
   "(<a href=\"gallery.md\">Markdown</a>)</li>\n"
   "<li><a href=\"BDD.md\">Behavior specification (BDD)</a></li>\n"
   "<li><a href=\"https://github.com/browser-grpc/grpc-over-datachannels\">"
   "Source, runtimes and examples on GitHub</a></li>\n"
   "<li><a href=\"https://c100k.blogspot.com/\">Project blog</a> — "
   "launch notes, design posts, and release write-ups</li>\n</ul>\n"
   "<h2>Why DataChannels?</h2>\n"
   "<p>WebRTC DataChannels give browsers an encrypted, ordered or "
   "lossy/unordered, bidirectional message pipe to any peer — "
   "including native processes. This project speaks the gRPC wire "
   "protocol directly over that pipe (HTTP/2 framing replaced by "
   "DataChannel messages), so a browser tab can call a Rust, Go, "
   "Python or Node service peer-to-peer, behind NATs via ICE/STUN/TURN, "
   "without a translating proxy.</p>\n"
   "</body>\n</html>\n"))

(make-directory* (build-path out-dir "docs"))
(call-with-output-file (build-path out-dir "docs/index.html")
  (lambda (out) (display landing out)) #:exists 'replace)

;; Crawler files for the Pages site.
(call-with-output-file (build-path out-dir "docs/robots.txt")
  (lambda (out)
    (display
     (string-append
      "User-agent: *\nAllow: /\n\nSitemap: " site-url "sitemap.xml\n")
     out))
  #:exists 'replace)
(call-with-output-file (build-path out-dir "docs/sitemap.xml")
  (lambda (out)
    (display
     (string-append
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
      "<url><loc>" site-url "</loc></url>\n"
      "<url><loc>" site-url "app/</loc></url>\n"
      "<url><loc>" site-url "gallery.html</loc></url>\n"
      "<url><loc>" site-url "gallery.md</loc></url>\n"
      "<url><loc>" site-url "BDD.md</loc></url>\n"
      "</urlset>\n")
     out))
  #:exists 'replace)
;; AI-discovery file: what this project is, in one screen of
;; plain text, for LLM crawlers and answer engines.
(call-with-output-file (build-path out-dir "docs/llms.txt")
  (lambda (out)
    (display
     (string-append
      "# grpc-over-datachannels\n\n"
      "gRPC over WebRTC DataChannels: the gRPC wire protocol spoken "
      "directly over a single RTCDataChannel, so browser tabs and "
      "native programs call each other peer-to-peer with no "
      "grpc-web proxy and no external gRPC runtime.\n\n"
      "Dependency-free generated gRPC clients and servers for "
      "JavaScript, Go, Rust, Python, Java, C#, C++, Swift, Kotlin, "
      "Dart, Zig, C, Lua, Ruby, PHP, and Scala, plus a "
      "zero-dependency WebRTC stack (ICE/DTLS/SCTP/DCEP) and a "
      "TCP<->DataChannel proxy that bridges browsers to stock "
      "HTTP/2 gRPC backends. Generated runtimes are graded against "
      "Google's official grpc-java and grpc-go interop clients and "
      "servers. A generated gRPC event bus (grpcdc.events.v1: "
      "publish/subscribe with tag-value filtering and a "
      "git-backed event log) ships in all sixteen languages.\n\n"
      "Site: " site-url "\n"
      "Blog: https://c100k.blogspot.com/\n"
      "Repository: https://github.com/browser-grpc/grpc-over-datachannels\n"
      "npm: https://www.npmjs.com/package/grpc-dc\n"
      "PyPI: https://pypi.org/project/grpc-dc/\n")
     out))
  #:exists 'replace)

;; ---------------------------------------------------------------------------
;; Examples catalog repo export (browser-grpc/examples):
;; a generated index over the main repo's per-language example
;; trees — no copied code, so nothing can drift. Rows derive
;; from the language table and the exported trees themselves
;; (file counts measured at generation time); links pin to
;; this release's tag in the main repo.
;; ---------------------------------------------------------------------------

(define (emit-ex-file rel text [mode #f])
  (define dest (build-path examples-out rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest
    (lambda (out) (display text out)) #:exists 'replace)
  (when mode (file-or-directory-permissions dest mode)))

(when (non-empty-string? examples-out)
  (when (directory-exists? examples-out)
    (delete-directory/files examples-out))
  (make-directory* examples-out)
  (for ([f (in-list '("LICENSE" "GENERATED-CODE-LICENSE.md"))])
    (copy-file (build-path out-dir f) (build-path examples-out f) #t))
  (define main-repo "https://github.com/browser-grpc/grpc-over-datachannels")
  (define (count-files dir)
    (if (directory-exists? dir)
        (length (find-files file-exists? dir))
        0))
  ;; First-run command per language: the curated readme spec
  ;; when one exists, else the Docker fallback its readme uses.
  (define (first-run dir)
    (define entry (hash-ref per-language-readmes dir #f))
    (if entry
        (car (string-split (cadr entry) "\n"))
        (string-append "docker build -f docker/" dir ".Dockerfile -t grpc-dc-" dir " . && docker run --rm grpc-dc-" dir)))
  ;; Guard: a language with example files but neither a curated
  ;; spec nor a generated Dockerfile would silently produce an
  ;; incomplete catalog row. Fail generation instead, so adding
  ;; examples (or a language) without either is a red build.
  (for ([lang (in-list languages)])
    (define dir (cdr lang))
    (define n (count-files (build-path out-dir dir "examples")))
    (when (and (> n 0)
               (not (hash-ref per-language-readmes dir #f))
               (not (file-exists? (build-path out-dir "docker"
                                              (string-append dir ".Dockerfile")))))
      (eprintf "releasegen: EXAMPLES GATE FAILED: ~a has ~a example files but no readme spec and no docker/~a.Dockerfile\n"
               dir n dir)
      (exit 1)))
  (define example-rows
    (apply string-append
           (for/list ([lang (in-list languages)])
             (define dir (cdr lang))
             (define n (count-files (build-path out-dir dir "examples")))
             (define run (first-run dir))
             (string-append
              "| " (car lang) " | " (number->string n) " | [examples]("
              main-repo "/tree/" version "/" dir "/examples) · [readme]("
              main-repo "/blob/" version "/" dir "/README.md) | `"
              (string-trim run) "` |\n"))))
  (define total-examples
    (for/sum ([lang (in-list languages)])
      (count-files (build-path out-dir (cdr lang) "examples"))))
  (emit-ex-file
   "RELEASE.json"
   (string-append "{\n  \"version\": \"" version "\",\n"
                  "  \"sourceCommit\": \"" source-commit "\",\n"
                  "  \"generated\": true\n}\n"))
  (emit-ex-file
   "README.md"
   (string-append
    "# grpc-dc examples — the catalog\n"
    "\n"
    "Every runnable example in the grpc-over-datachannels project,\n"
    "indexed by language and scenario. This repository is a\n"
    "**generated catalog** (version " version "): it copies no code, so it\n"
    "cannot drift — each entry links to the example in the main\n"
    "repo at this release's tag, where it is tested by the same\n"
    "CI that tests the runtimes.\n"
    "\n"
    "New here? Run your first RPC in the browser, no install:\n"
    "[live generator](https://browser-grpc.github.io/grpc-over-datachannels/app/).\n"
    "\n"
    "## Scenarios\n"
    "\n"
    "- **Echo in every language** — the same unary / server-streaming /\n"
    "  client-streaming / bidi service in all sixteen languages:\n"
    "  [gallery](https://browser-grpc.github.io/grpc-over-datachannels/gallery.html).\n"
    "- **Event bus** — publish/subscribe as a gRPC service:\n"
    "  [browser-grpc/eventbus](https://github.com/browser-grpc/eventbus).\n"
    "- **Kafka clients** — produce/consume through the Rust proxy:\n"
    "  [browser-grpc/kafka-proxy](https://github.com/browser-grpc/kafka-proxy).\n"
    "- **Browser starter** — browser client ↔ Node server with\n"
    "  WebSocket signaling: [`examples/starter`](" main-repo "/tree/" version "/examples/starter).\n"
    "- **WebRTC-Direct** — signaling-free Echo in every language\n"
    "  (direct, TURN, and STUN peer modes, compose included):\n"
    "  [`examples/direct`](" main-repo "/tree/" version "/examples/direct).\n"
    "- **VoxelSeed** — the procgen voxel dashboard (WebGPU):\n"
    "  [play it](https://voxelseed.lunchgamer.com/) ·\n"
    "  [source](" main-repo "/tree/" version "/examples/browser/voxelseed).\n"
    "\n"
    "## Examples by language (" (number->string total-examples) " files)\n"
    "\n"
    "| Language | Example files | In the main repo | First run |\n"
    "|---|---|---|---|\n"
    example-rows
    "\n"
    "Generated code may be used without restriction (see\n"
    "GENERATED-CODE-LICENSE.md); everything else is Apache-2.0\n"
    "(see LICENSE). Background and design posts:\n"
    "[project blog](https://c100k.blogspot.com/).\n"))
  (emit-ex-file
   "scripts/check-links.py"
   (string-append
    "#!/usr/bin/env python3\n"
    "\"\"\"Check every URL in README.md answers (stdlib only).\n"
    "403 counts as alive (bot walls); anything else >= 400 fails.\"\"\"\n"
    "import re, sys, urllib.request\n"
    "\n"
    "text = open('README.md').read()\n"
    "urls = sorted(set(re.findall(r'https://[^\\s)\\]]+', text)))\n"
    "bad = []\n"
    "for u in urls:\n"
    "    try:\n"
    "        req = urllib.request.Request(u, method='HEAD',\n"
    "                                     headers={'User-Agent': 'link-check'})\n"
    "        code = urllib.request.urlopen(req, timeout=20).status\n"
    "    except Exception as e:\n"
    "        code = getattr(e, 'code', 0) or 0\n"
    "        if code == 403:\n"
    "            code = 200\n"
    "        if code == 0 or code >= 400:\n"
    "            bad.append((u, code or str(e)))\n"
    "    print(code, u)\n"
    "print('checked', len(urls), 'links;', len(bad), 'bad')\n"
    "sys.exit(1 if bad else 0)\n")
   #o755)
  (emit-ex-file
   ".github/workflows/ci.yml"
   (string-append
    "name: CI\n"
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "  pull_request:\n"
    "jobs:\n"
    "  links:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - uses: actions/checkout@v4\n"
    "      - name: Check catalog links\n"
    "        run: python3 scripts/check-links.py\n"))
  ;; Leak gate for the catalog export.
  (let* ([ex-files (find-files file-exists? examples-out)]
         [ex-leaks
          (filter (lambda (p) (string-suffix? (path->string p) ".rkt"))
                  ex-files)])
    (unless (null? ex-leaks)
      (eprintf "releasegen: EXAMPLES LEAK GATE FAILED:\n")
      (for ([p (in-list ex-leaks)]) (eprintf "  ~a\n" p))
      (exit 1))
    (printf "releasegen: examples export: ~a files, leak gate OK\n"
            (length ex-files))))

(call-with-output-file (build-path out-dir "RELEASE.json")
  (lambda (out)
    (fprintf out "{\n  \"version\": \"~a\",\n  \"sourceCommit\": \"~a\",\n  \"generated\": true\n}\n"
             version source-commit))
  #:exists 'replace)

;; Package-manager story: align the npm package version with
;; the release (the js/ package.json is the single source of
;; truth for contents), and give Python a pip-installable
;; package so `pip install ./python` works from the export.
(define npm-version
  (if (string-prefix? version "v") (substring version 1) version))
(define js-package-path (build-path out-dir "js/package.json"))
(when (file-exists? js-package-path)
  (define text (file->string js-package-path))
  (define versioned
    (regexp-replace #rx"\"version\": \"[^\"]+\""
                    text
                    (string-append "\"version\": \"" npm-version "\"")))
  ;; Plugin distribution: expose the staged js/plugin wrappers
  ;; as npm bin entries and ship the plugin/ tree in the tarball.
  (define bin-block
    (string-append
     "  \"bin\": {\n"
     (string-join
      (for/list ([lang (in-list plugin-langs)])
        (string-append "    \"protoc-gen-grpc-dc-" lang
                       "\": \"plugin/protoc-gen-grpc-dc-" lang ".mjs\""))
      ",\n")
     "\n  },\n"))
  (define aligned
    (if (regexp-match? #rx"\"bin\"" versioned)
        versioned
        (regexp-replace
         #rx"  \"files\": \\["
         (regexp-replace #rx"    \"src\"\n" versioned
                         "    \"src\",\n    \"plugin\"\n")
         (string-append bin-block "  \"files\": ["))))
  (call-with-output-file js-package-path #:exists 'replace
    (lambda (out) (display aligned out))))
;; GitHub Packages mirrors (npm / NuGet / RubyGems — the only
;; package registries GitHub hosts; Maven stays on the Pages
;; repo, which resolves anonymously). The npm mirror needs a
;; scoped name, so emit a scoped variant manifest next to the
;; canonical one; scripts/release-push.sh stages it as
;; package.json when publishing to npm.pkg.github.com.
(when (file-exists? js-package-path)
  (define text (file->string js-package-path))
  (define scoped
    (regexp-replace
     #rx"\"license\": \"Apache-2.0\"\n}"
     (regexp-replace #rx"\"name\": \"grpc-dc\""
                     text
                     "\"name\": \"@browser-grpc/grpc-dc\"")
     (string-append
      "\"license\": \"Apache-2.0\",\n"
      "  \"publishConfig\": {\"registry\": \"https://npm.pkg.github.com\"}\n}")))
  (call-with-output-file (build-path out-dir "js/package.github.json")
    #:exists 'replace
    (lambda (out) (display scoped out))))
;; RubyGems mirror: the export's ruby/ tree has no gemspec, so
;; emit one (stdlib-only runtime, no gem dependencies; the
;; generated grpcdc.kafka.v1 stubs ship inside the same gem).
(call-with-output-file (build-path out-dir "ruby/grpc-dc.gemspec")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Gem packaging for the generated Ruby runtime.\n"
      "# Build from the export root: gem build ruby/grpc-dc.gemspec\n"
      "Gem::Specification.new do |spec|\n"
      "  spec.name = \"grpc-dc\"\n"
      "  spec.version = \"" npm-version "\"\n"
      "  spec.authors = [\"John Davis\"]\n"
      "  spec.summary = \"gRPC over WebRTC DataChannels, dependency-free generated Ruby runtime\"\n"
      "  spec.description = \"Generated, stdlib-only gRPC clients and servers for Ruby speaking the gRPC wire protocol over a WebRTC DataChannel, plus generated stubs (incl. grpcdc.kafka.v1). No grpc library underneath.\"\n"
      "  spec.homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
      "  spec.license = \"Apache-2.0\"\n"
      "  spec.required_ruby_version = \">= 3.0\"\n"
      "  spec.files = Dir[\"ruby/grpcdc.rb\", \"ruby/grpcdc/**/*.rb\", \"ruby/README.md\"]\n"
      "  spec.require_paths = [\"ruby\"]\n"
      "end\n")
     out)))
(call-with-output-file (build-path out-dir "GITHUB-PACKAGES.md")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# GitHub Packages mirrors\\n\\n"
      "The canonical packages live on the language registries\\n"
      "(npm, PyPI, Maven Central + the Pages Maven repo, NuGet,\\n"
      "crates.io-compatible git tags for Go). As a mirror, the\\n"
      "registries GitHub Packages can host are also published\\n"
      "to GitHub under the `browser-grpc` org at each release:\\n\\n"
      "| Ecosystem | GitHub Packages artifact |\\n"
      "|---|---|\\n"
      "| npm | `@browser-grpc/grpc-dc` |\\n"
      "| NuGet | `GrpcDc` |\\n"
      "| RubyGems | `grpc-dc` |\\n\\n"
      "Each ecosystem also gets a separate `kafka-grpc` package\\n"
      "(npm `@browser-grpc/kafka-grpc`, NuGet `KafkaGrpc`, gem\\n"
      "`kafka-grpc`) holding the generated `grpcdc.kafka.v1`\\n"
      "stubs; see packages/README.md in the export.\\n\\n"
      "GitHub Packages requires an authenticated token for\\n"
      "consumers **even for public packages** (a GitHub personal\\n"
      "access token with `read:packages`). That friction is why\\n"
      "Maven is *not* mirrored here: the Pages-hosted Maven repo\\n"
      "(see MAVEN-PUBLISHING.md) resolves the same coordinates\\n"
      "anonymously. Ecosystems GitHub cannot host (Python, Rust,\\n"
      "Go, Dart, PHP, Lua, Swift, Zig, C/C++) use their language\\n"
      "registries, git tags, or the release zip instead.\\n\\n"
      "## npm\\n\\n"
      "```ini\\n"
      "@browser-grpc:registry=https://npm.pkg.github.com\\n"
      "//npm.pkg.github.com/:_authToken=YOUR_TOKEN\\n"
      "```\\n\\n"
      "## NuGet\\n\\n"
      "```sh\\n"
      "dotnet nuget add source https://nuget.pkg.github.com/browser-grpc/index.json \\\\\\n"
      "  --name github-browser-grpc --username YOUR_GITHUB_USER --password YOUR_TOKEN\\n"
      "dotnet add package GrpcDc\\n"
      "```\\n\\n"
      "## RubyGems\\n\\n"
      "```sh\\n"
      "gem install grpc-dc \\\\\\n"
      "  --source https://rubygems.pkg.github.com/browser-grpc/\\n"
      "```\\n"
      "(with `github: Bearer YOUR_TOKEN` in ~/.gem/credentials)\\n")
     out)))
;; ---------------------------------------------------------------------------
;; Separate kafka-grpc packages. The generated grpcdc.kafka.v1
;; stubs (messages + client, two files per language) also ship
;; as their own package in every ecosystem we publish, next to
;; grpc-dc, depending on it. Trees land in packages/kafka-<lang>
;; so each is installable/buildable on its own; Go gets a
;; nested module, Rust a path-dependency crate, and the JVM a
;; second Maven artifact (same group, reactor-built).
(define kafka-root (build-path out-dir "packages"))
(define (emit-kafka-file dest-rel text)
  (define dest (build-path kafka-root dest-rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest #:exists 'replace
    (lambda (out) (display text out))))
(define (copy-kafka-file src-rel dest-rel)
  (define src (build-path out-dir src-rel))
  (when (file-exists? src)
    (define dest (build-path kafka-root dest-rel))
    (make-directory* (path-only dest))
    (copy-file src dest #t)))
(define kafka-desc
  "Kafka over gRPC — generated grpcdc.kafka.v1 clients (produce/consume/groups/topics) speaking gRPC over WebRTC DataChannels, via the grpc-dc runtime")
;; --- npm (canonical + GitHub Packages scoped variant) ---
(copy-kafka-file "js/src/kafka_pb.js" "kafka-js/kafka_pb.js")
(copy-kafka-file "js/src/kafka_grpc_dc.js" "kafka-js/kafka_grpc_dc.js")
(emit-kafka-file "kafka-js/index.js"
  "export * from \"./kafka_pb.js\";\nexport * from \"./kafka_grpc_dc.js\";\n")
(define (kafka-npm-manifest name dep-name)
  (string-append
   "{\n  \"name\": \"" name "\",\n"
   "  \"version\": \"" npm-version "\",\n"
   "  \"description\": \"" kafka-desc " (JavaScript, browser + Node)\",\n"
   "  \"type\": \"module\",\n  \"main\": \"index.js\",\n"
   "  \"files\": [\"index.js\", \"kafka_pb.js\", \"kafka_grpc_dc.js\"],\n"
   "  \"dependencies\": {\"" dep-name "\": \"^" npm-version "\"},\n"
   "  \"license\": \"Apache-2.0\",\n"
   "  \"repository\": {\"type\": \"git\", \"url\": \"git+https://github.com/browser-grpc/grpc-over-datachannels.git\"}\n}\n"))
(emit-kafka-file "kafka-js/package.json" (kafka-npm-manifest "kafka-grpc" "grpc-dc"))
(emit-kafka-file "kafka-js/package.github.json"
  (kafka-npm-manifest "@browser-grpc/kafka-grpc" "@browser-grpc/grpc-dc"))
;; --- PyPI ---
(copy-kafka-file "python/grpcdc/kafka_pb.py" "kafka-python/grpcdc/kafka_pb.py")
(copy-kafka-file "python/grpcdc/kafka_grpc_dc.py" "kafka-python/grpcdc/kafka_grpc_dc.py")
(emit-kafka-file "kafka-python/grpcdc/__init__.py"
  "\"\"\"Generated grpcdc.kafka.v1 stubs; the runtime lives in the grpc-dc package.\"\"\"\n")
(emit-kafka-file "kafka-python/README.md"
  (string-append "# kafka-grpc (Python)\n\n" kafka-desc ".\n\nInstall: `pip install kafka-grpc` (depends on `grpc-dc`).\n"))
(emit-kafka-file "kafka-python/pyproject.toml"
  (string-append
   "[build-system]\nrequires = [\"setuptools>=61\"]\nbuild-backend = \"setuptools.build_meta\"\n\n"
   "[project]\nname = \"kafka-grpc\"\nversion = \"" npm-version "\"\n"
   "description = \"" kafka-desc " (Python)\"\nreadme = \"README.md\"\nrequires-python = \">=3.9\"\n"
   "license = {text = \"Apache-2.0\"}\ndependencies = [\"grpc-dc>=" npm-version "\"]\n\n"
   "[tool.setuptools.packages.find]\ninclude = [\"grpcdc*\"]\n"))
;; --- RubyGems ---
(copy-kafka-file "ruby/grpcdc/kafka_pb.rb" "kafka-ruby/lib/grpcdc/kafka_pb.rb")
(copy-kafka-file "ruby/grpcdc/kafka_grpc_dc.rb" "kafka-ruby/lib/grpcdc/kafka_grpc_dc.rb")
(emit-kafka-file "kafka-ruby/lib/kafka_grpc.rb"
  "require_relative \"grpcdc/kafka_pb\"\nrequire_relative \"grpcdc/kafka_grpc_dc\"\n")
(emit-kafka-file "kafka-ruby/kafka-grpc.gemspec"
  (string-append
   "Gem::Specification.new do |spec|\n"
   "  spec.name = \"kafka-grpc\"\n  spec.version = \"" npm-version "\"\n"
   "  spec.authors = [\"John Davis\"]\n"
   "  spec.summary = \"Kafka over gRPC — generated grpcdc.kafka.v1 Ruby clients\"\n"
   "  spec.description = \"" kafka-desc " (Ruby).\"\n"
   "  spec.homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "  spec.license = \"Apache-2.0\"\n  spec.required_ruby_version = \">= 3.0\"\n"
   "  spec.files = Dir[\"lib/**/*.rb\"]\n  spec.require_paths = [\"lib\"]\n"
   "  spec.add_runtime_dependency \"grpc-dc\", \"= " npm-version "\"\nend\n"))
;; --- NuGet (own project, ProjectReference on Grpcdc for pack) ---
(copy-kafka-file "csharp/grpcdc/kafka/v1/KafkaPb.cs" "kafka-csharp/KafkaPb.cs")
(copy-kafka-file "csharp/grpcdc/kafka/v1/KafkaGrpcDc.cs" "kafka-csharp/KafkaGrpcDc.cs")
(emit-kafka-file "kafka-csharp/KafkaGrpc.csproj"
  (string-append
   "<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n"
   "    <TargetFramework>net8.0</TargetFramework>\n"
   "    <PackageId>KafkaGrpc</PackageId>\n    <Version>" npm-version "</Version>\n"
   "    <Authors>John Davis</Authors>\n    <Description>" kafka-desc " (.NET).</Description>\n"
   "    <PackageLicenseExpression>Apache-2.0</PackageLicenseExpression>\n"
   "    <RepositoryUrl>https://github.com/browser-grpc/grpc-over-datachannels</RepositoryUrl>\n"
   "  </PropertyGroup>\n  <ItemGroup>\n"
   "    <PackageReference Include=\"GrpcDc\" Version=\"" npm-version "\" />\n"
   "  </ItemGroup>\n</Project>\n"))
;; --- Maven (second artifact in the same reactor) ---
(copy-kafka-file "java/grpcdc/kafka/v1/KafkaPb.java" "kafka-java/grpcdc/kafka/v1/KafkaPb.java")
(copy-kafka-file "java/grpcdc/kafka/v1/KafkaGrpcDc.java" "kafka-java/grpcdc/kafka/v1/KafkaGrpcDc.java")
(emit-kafka-file "kafka-java/pom.xml"
  (string-append
   "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n  <modelVersion>4.0.0</modelVersion>\n"
   "  <groupId>io.github.browser-grpc</groupId>\n  <artifactId>kafka-grpc</artifactId>\n"
   "  <version>" npm-version "</version>\n"
   "  <name>kafka-grpc</name>\n  <description>" kafka-desc " (Java).</description>\n"
   "  <url>https://github.com/browser-grpc/grpc-over-datachannels</url>\n"
   "  <licenses><license><name>Apache-2.0</name></license></licenses>\n"
   "  <properties><maven.compiler.source>11</maven.compiler.source><maven.compiler.target>11</maven.compiler.target><project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties>\n"
   "  <dependencies><dependency><groupId>io.github.browser-grpc</groupId><artifactId>grpc-dc</artifactId><version>" npm-version "</version></dependency></dependencies>\n"
   "  <build><sourceDirectory>${project.basedir}</sourceDirectory><plugins>\n"
   "    <plugin><artifactId>maven-source-plugin</artifactId><version>3.3.1</version><executions><execution><id>attach-sources</id><goals><goal>jar-no-fork</goal></goals></execution></executions></plugin>\n"
   "    <plugin><artifactId>maven-javadoc-plugin</artifactId><version>3.10.0</version><configuration><additionalOptions><additionalOption>-Xdoclint:none</additionalOption></additionalOptions><quiet>true</quiet></configuration><executions><execution><id>attach-javadocs</id><goals><goal>jar</goal></goals></execution></executions></plugin>\n"
   "    <plugin><groupId>org.sonatype.central</groupId><artifactId>central-publishing-maven-plugin</artifactId><version>0.8.0</version><extensions>true</extensions><configuration><publishingServerId>central</publishingServerId><autoPublish>true</autoPublish><waitUntil>published</waitUntil></configuration></plugin>\n"
   "  </plugins></build>\n"
   "  <profiles><profile><id>release</id><build><plugins><plugin><artifactId>maven-gpg-plugin</artifactId><version>3.2.7</version><executions><execution><id>sign-artifacts</id><phase>verify</phase><goals><goal>sign</goal></goals></execution></executions><configuration><gpgArguments><arg>--pinentry-mode</arg><arg>loopback</arg></gpgArguments></configuration></plugin></plugins></build></profile></profiles>\n"
   "</project>\n"))
;; --- Cargo (path dependency on the grpc-dc crate in-repo) ---
(copy-kafka-file "rust/gen/kafka_pb.rs" "kafka-rust/src/kafka_pb.rs")
(copy-kafka-file "rust/gen/kafka_grpc_dc.rs" "kafka-rust/src/kafka_grpc_dc.rs")
(emit-kafka-file "kafka-rust/src/lib.rs"
  "pub mod kafka_pb;\npub mod kafka_grpc_dc;\n")
(emit-kafka-file "kafka-rust/Cargo.toml"
  (string-append
   "[package]\nname = \"kafka-grpc\"\nversion = \"" npm-version "\"\nedition = \"2021\"\n"
   "license = \"Apache-2.0\"\ndescription = \"" kafka-desc " (Rust).\"\n"
   "homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n\n"
   "[dependencies]\ngrpc-dc = { path = \"../../rust\" }\n"))
;; --- Go (nested module) ---
(copy-kafka-file "go/kafka/kafka_pb.go" "kafka-go/kafka_pb.go")
(copy-kafka-file "go/kafka/kafka_grpc_dc.go" "kafka-go/kafka_grpc_dc.go")
(emit-kafka-file "kafka-go/go.mod"
  (string-append
   "module github.com/browser-grpc/grpc-over-datachannels/kafka\n\ngo 1.21\n\n"
   "require github.com/browser-grpc/grpc-over-datachannels/go v" npm-version "\n"))
(call-with-output-file (build-path kafka-root "README.md")
  #:exists 'replace
  (lambda (out) (display
   (string-append
   "# Separate kafka-grpc packages\n\n"
   "Each `kafka-<lang>` tree here is a standalone package of the\n"
   "generated `grpcdc.kafka.v1` stubs for one ecosystem, depending\n"
   "on that ecosystem's `grpc-dc` package at the same version:\n\n"
   "| Tree | Package | Depends on |\n|---|---|---|\n"
   "| kafka-js | npm `kafka-grpc` / GitHub `@browser-grpc/kafka-grpc` | `grpc-dc` / `@browser-grpc/grpc-dc` |\n"
   "| kafka-python | PyPI `kafka-grpc` | `grpc-dc` |\n"
   "| kafka-ruby | RubyGems/GitHub `kafka-grpc` | `grpc-dc` |\n"
   "| kafka-csharp | NuGet/GitHub `KafkaGrpc` | `GrpcDc` |\n"
   "| kafka-java | Maven `io.github.browser-grpc:kafka-grpc` | `io.github.browser-grpc:grpc-dc` |\n"
   "| kafka-rust | crates.io `kafka-grpc` | `grpc-dc` |\n"
   "| kafka-go | module `github.com/browser-grpc/grpc-over-datachannels/kafka` | `.../go` |\n\n"
   "Kotlin, Scala, Dart, PHP, Lua, Swift, Zig, C and C++ carry the\n"
   "same two generated files inside their grpc-dc trees (those\n"
   "ecosystems have no separate package split here). Publishing is\n"
   "driven by scripts/release-push.sh; see GITHUB-PACKAGES.md.\n")
   out)))
(call-with-output-file (build-path out-dir "python/pyproject.toml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# pip packaging for the generated Python runtime.\n"
      "# Install from the export root: pip install ./python\n"
      "[build-system]\n"
      "requires = [\"setuptools>=61\"]\n"
      "build-backend = \"setuptools.build_meta\"\n\n"
      "[project]\n"
      "name = \"grpc-dc\"\n"
      "version = \"" npm-version "\"\n"
      "description = \"gRPC over WebRTC DataChannels — dependency-free generated Python runtime\"\n"
      "readme = \"README.md\"\n"
      "requires-python = \">=3.9\"\n"
      "license = {text = \"Apache-2.0\"}\n"
      "keywords = [\"grpc\", \"webrtc\", \"datachannel\", \"rpc\"]\n"
      "classifiers = [\n"
      "  \"Development Status :: 4 - Beta\",\n"
      "  \"Intended Audience :: Developers\",\n"
      "  \"License :: OSI Approved :: Apache Software License\",\n"
      "  \"Programming Language :: Python :: 3\",\n"
      "  \"Topic :: Software Development :: Libraries\",\n"
      "]\n\n"
      "[project.urls]\n"
      "Homepage = \"https://browser-grpc.github.io/grpc-over-datachannels\"\n"
      "Repository = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n\n"
      "[tool.setuptools.packages.find]\n"
      "include = [\"grpcdc*\"]\n")
     out)))

;; ---------------------------------------------------------------------------
;; Leak gate: no Racket source may cross. (Generated-file
;; headers naming the generator are provenance and stay.)
;; ---------------------------------------------------------------------------

(define all-exported
  (find-files file-exists? out-dir))

(define (leak? p)
  (define rel (path->string (find-relative-path (current-directory) p)))
  (or (string-suffix? rel ".rkt")
      (string-suffix? rel ".rktl")
      (regexp-match? #rx"build-racket-wasm" rel)
      (let ([text (with-handlers ([exn:fail? (lambda (_) "")])
                    (file->string p))])
        (regexp-match? #rx"(?m:^#lang (racket|scrbl))" text))))

(define leaks (filter leak? all-exported))
(unless (null? leaks)
  (eprintf "releasegen: LEAK GATE FAILED, Racket source in export:\n")
  (for ([p (in-list leaks)]) (eprintf "  ~a\n" p))
  (exit 1))

;; ---------------------------------------------------------------------------
;; Clarity gate: user-facing exported text (docs, READMEs, the
;; browser app, generated code) must not point at generator-
;; internal source paths, so newcomers never meet a reference
;; they cannot open. Provenance files keep the full story.
;; Only relative paths are matched ("../racket/...", "/racket/"
;; or a leading "racket/" path); prose and asset paths are fine.
;; ---------------------------------------------------------------------------

(define clarity-allowlist
  '("CHANGELOG.md" "SPEC.md" "SPEC-WEBRTC.md" "BDD.md"
    "GENERATED-CODE-LICENSE.md" "RELEASE.json"))

(define (clarity-violation? p)
  (define rel (path->string (find-relative-path out-dir p)))
  (and (not (member rel clarity-allowlist))
       (not (string-prefix? rel "docs/BDD.md"))
       (let ([text (with-handlers ([exn:fail? (lambda (_) "")])
                     (file->string p))])
         ;; Runtime fetch URLs ("assets/racket/runner.rkt") are
         ;; asset references, not source-path references: exempt.
         (regexp-match? #rx"(^|[\"'(/ \t])racket/[a-z0-9_.*-]+[.]rkt"
                        (regexp-replace* #rx"assets/racket/" text "assets/")))))

(define clarity-violations (filter clarity-violation? all-exported))
(unless (null? clarity-violations)
  (eprintf "releasegen: CLARITY GATE FAILED, generator-internal paths in user-facing export:\n")
  (for ([p (in-list clarity-violations)])
    (eprintf "  ~a\n" (path->string (find-relative-path out-dir p))))
  (exit 1))
(printf "releasegen: clarity gate OK (no generator-internal paths in user-facing text)\n")

(define total-bytes
  (for/sum ([p (in-list all-exported)]) (file-size p)))

(printf "releasegen: exported ~a files (~a MB) for ~a from ~a\n"
        (length all-exported)
        (real->decimal-string (/ total-bytes 1048576.0) 1)
        version source-commit)
(printf "releasegen: leak gate OK (no Racket source)\n")
