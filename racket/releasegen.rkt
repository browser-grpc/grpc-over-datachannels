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
(define kafka-native-out (arg-value "--kafka-native-out" ""))
(define php-out (arg-value "--php-out" ""))
(define kafka-php-out (arg-value "--kafka-php-out" ""))
(define eventbus-php-out (arg-value "--eventbus-php-out" ""))
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
          '("webrtc" "wasm" "proto" "fixtures" "examples" "conformance" "crates/kafka-native"
            ;; The shared Rust cores: the Go stack links the
            ;; FFI cdylibs and the JS stack generates its Wasm
            ;; glue from these, so a public clone must carry
            ;; them to build at all (post-consolidation).
            "crates/dc-sctp-ffi" "crates/dc-dtls-ffi" "crates/dc-ice-ffi"
            "crates/dc-sctp-wasm" "crates/dc-dtls-wasm" "crates/dc-ice-wasm"
            "crates/dc-bridge-wasm")))

;; QUICKSTART step 2 lives in browser-test/, which is otherwise
;; private test tooling (and carries built wasm/binaries); export
;; just the sample so the public quickstart command runs as-is.
(define allow-files-extra '("browser-test/native_step2.mjs"))

(define allow-files
  '("LICENSE" "NOTICE" "GENERATED-CODE-LICENSE.md" "CHANGELOG.md"
    "BDD.md" "SPEC.md" "CONTRIBUTING.md" "SECURITY.md"))

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
         "# GrpcDc\n\ngRPC over WebRTC DataChannels for .NET (net8.0 + netstandard2.0: Unity, .NET Framework 4.7.2+, Mono, Xamarin) — generated gRPC clients and servers.\n\nSee https://browser-grpc.github.io/grpc-over-datachannels/ and the `csharp/README.md` in the repository.\n"
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
                  (regexp-match? #rx"[.](mjs|html|json|py)$" rel)
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
      "# Publish the grpc-dc and kafka-grpc npm packages via\n"
      "# Trusted Publishing (OIDC). Manual dispatch only; see\n"
      "# NPM-PUBLISHING.md. Requires the Trusted Publisher\n"
      "# configured for both packages on npmjs.com (this repo +\n"
      "# this workflow file).\n"
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
      "        run: npm publish --provenance --access public\n"
      "      - if: \"!cancelled()\"\n"
      "        working-directory: packages/kafka-js\n"
      "        run: npm publish --provenance --access public\n"
      "      - if: \"!cancelled()\"\n"
      "        working-directory: packages/eventbus-js\n"
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
      "      - name: Push GrpcDc to nuget.org\n"
      "        run: dotnet nuget push /tmp/nuget/GrpcDc.*.nupkg --api-key ${{ steps.login.outputs.NUGET_API_KEY }} --source https://api.nuget.org/v3/index.json --skip-duplicate\n"
      "      - name: Wait for GrpcDc indexing (KafkaGrpc restore needs it)\n"
      "        run: |\n"
      "          V=$(grep -oPm1 '(?<=Include=\"GrpcDc\" Version=\")[^\"]+' packages/kafka-csharp/KafkaGrpc.csproj)\n"
      "          for i in $(seq 1 40); do curl -sf https://api.nuget.org/v3-flatcontainer/grpcdc/index.json | grep -q \"\\\"$V\\\"\" && exit 0; sleep 15; done; echo 'GrpcDc not indexed in time' >&2; exit 1\n"
      "      - name: Pack KafkaGrpc\n"
      "        run: dotnet pack packages/kafka-csharp/KafkaGrpc.csproj -c Release -o /tmp/nuget\n"
      "      - name: Pack EventBusGrpc\n"
      "        run: dotnet pack packages/eventbus-csharp/EventBusGrpc.csproj -c Release -o /tmp/nuget\n"
      "      - name: Push to nuget.org\n"
      "        run: dotnet nuget push /tmp/nuget/*.nupkg --api-key ${{ steps.login.outputs.NUGET_API_KEY }} --source https://api.nuget.org/v3/index.json --skip-duplicate\n")
     out)))

;; pub.dev (Dart/Flutter): workflow publishing packages/grpc-dart
;; (grpc_dc) then packages/kafka-dart (kafka_grpc) via pub.dev
;; automated publishing (GitHub OIDC, no stored token). Requires
;; automated publishing enabled for both packages on pub.dev
;; (repo browser-grpc/grpc-over-datachannels, tag pattern
;; v{{version}}, workflow_dispatch allowed). pub.dev rejects
;; branch-ref OIDC tokens, so release-push.sh dispatches this
;; workflow with --ref set to the release tag; the first versions
;; were published interactively. See the packages' pubspec.yaml
;; files under packages/.
(call-with-output-file (build-path out-dir ".github/workflows/publish-pubdev.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish the grpc_dc and kafka_grpc pub.dev packages via\n"
      "# pub.dev automated publishing (OIDC). pub.dev only accepts\n"
      "# OIDC tokens issued for a git tag matching the configured\n"
      "# tag pattern (v{{version}}), so dispatch this workflow\n"
      "# from the release tag ref (scripts/release-push.sh does:\n"
      "# gh workflow run publish-pubdev.yml --ref vX.Y.Z); a\n"
      "# branch-ref dispatch is rejected by pub.dev. Each publish\n"
      "# step is idempotent (skips when the pubspec version is\n"
      "# already the latest on pub.dev), and the grpc_dc step\n"
      "# waits until the new version is visible in the pub.dev\n"
      "# API before kafka_grpc (which depends on it) publishes.\n"
      "name: publish-pubdev\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: read\n"
      "  id-token: write\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: dart-lang/setup-dart@v1\n"
      "      - name: Publish grpc_dc\n"
      "        working-directory: packages/grpc-dart\n"
      "        run: |\n"
      "          VER=$(sed -n 's/^version: //p' pubspec.yaml)\n"
      "          latest() { curl -sf https://pub.dev/api/packages/grpc_dc | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"latest\"][\"version\"])'; }\n"
      "          if [ \"$(latest)\" = \"$VER\" ]; then\n"
      "            echo \"grpc_dc $VER already on pub.dev; skipping\"\n"
      "          else\n"
      "            dart pub publish --force\n"
      "          fi\n"
      "          for i in $(seq 1 30); do\n"
      "            [ \"$(latest)\" = \"$VER\" ] && break\n"
      "            sleep 20\n"
      "          done\n"
      "          [ \"$(latest)\" = \"$VER\" ]\n"
      "      - if: \"!cancelled()\"\n"
      "        name: Publish kafka_grpc\n"
      "        working-directory: packages/kafka-dart\n"
      "        run: |\n"
      "          VER=$(sed -n 's/^version: //p' pubspec.yaml)\n"
      "          LATEST=$(curl -sf https://pub.dev/api/packages/kafka_grpc | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"latest\"][\"version\"])' || echo none)\n"
      "          if [ \"$LATEST\" = \"$VER\" ]; then\n"
      "            echo \"kafka_grpc $VER already on pub.dev; skipping\"\n"
      "          else\n"
      "            dart pub publish --force\n"
      "          fi\n"
      "      - if: \"!cancelled()\"\n"
      "        name: Publish eventbus_grpc\n"
      "        working-directory: packages/eventbus-dart\n"
      "        run: |\n"
      "          VER=$(sed -n 's/^version: //p' pubspec.yaml)\n"
      "          LATEST=$(curl -sf https://pub.dev/api/packages/eventbus_grpc | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"latest\"][\"version\"])' || echo none)\n"
      "          if [ \"$LATEST\" = \"$VER\" ]; then\n"
      "            echo \"eventbus_grpc $VER already on pub.dev; skipping\"\n"
      "          else\n"
      "            dart pub publish --force\n"
      "          fi\n")
     out)))

;; crates.io: manual-dispatch workflow publishing
;; packages/grpc-rust (grpc-dc) then packages/kafka-rust
;; (kafka-grpc) via crates.io Trusted Publishing (OIDC token
;; exchange with rust-lang/crates-io-auth-action, no stored
;; API token). Requires Trusted Publishing configured for both
;; crates on crates.io (repo browser-grpc/grpc-over-datachannels,
;; workflow publish-crates.yml); the first versions were
;; published with an API token.
(call-with-output-file (build-path out-dir ".github/workflows/publish-crates.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish the grpc-dc and kafka-grpc crates via crates.io\n"
      "# Trusted Publishing (OIDC). Manual dispatch only.\n"
      "# Requires Trusted Publishing configured for both crates\n"
      "# on crates.io (this repo + this workflow file).\n"
      "name: publish-crates\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: read\n"
      "  id-token: write\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: dtolnay/rust-toolchain@stable\n"
      "      - uses: rust-lang/crates-io-auth-action@v1\n"
      "        id: auth\n"
      "      - name: Publish grpc-dc\n"
      "        working-directory: packages/grpc-rust\n"
      "        run: cargo publish --token ${{ steps.auth.outputs.token }}\n"
      "      - name: Publish kafka-grpc (retry while the index catches up)\n"
      "        if: \"!cancelled()\"\n"
      "        working-directory: packages/kafka-rust\n"
      "        run: |\n"
      "          for i in $(seq 1 20); do\n"
      "            cargo publish --token ${{ steps.auth.outputs.token }} && exit 0\n"
      "            sleep 30\n"
      "          done\n"
      "          echo 'kafka-grpc publish did not succeed' >&2; exit 1\n"
      "      - name: Publish eventbus-grpc (retry while the index catches up)\n"
      "        if: \"!cancelled()\"\n"
      "        working-directory: packages/eventbus-rust\n"
      "        run: |\n"
      "          for i in $(seq 1 20); do\n"
      "            cargo publish --token ${{ steps.auth.outputs.token }} && exit 0\n"
      "            sleep 30\n"
      "          done\n"
      "          echo 'eventbus-grpc publish did not succeed' >&2; exit 1\n")
     out)))

;; RubyGems: manual-dispatch workflow publishing
;; packages/grpc-ruby (grpc-dc) then packages/kafka-ruby
;; (kafka-grpc) via RubyGems Trusted Publishing (OIDC, using
;; rubygems/configure-rubygems-credentials, then plain
;; gem build/push in each package dir). Requires a Trusted
;; Publisher configured for both gems on rubygems.org (repo
;; browser-grpc/grpc-over-datachannels, workflow
;; publish-rubygems.yml); the first versions were pushed with
;; an API key.
(call-with-output-file (build-path out-dir ".github/workflows/publish-rubygems.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish the grpc-dc and kafka-grpc gems via RubyGems\n"
      "# Trusted Publishing (OIDC). Manual dispatch only.\n"
      "# Requires a Trusted Publisher configured for both gems\n"
      "# on rubygems.org (this repo + this workflow file).\n"
      "name: publish-rubygems\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: read\n"
      "  id-token: write\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: ruby/setup-ruby@v1\n"
      "        with:\n"
      "          ruby-version: ruby\n"
      "      - uses: rubygems/configure-rubygems-credentials@v1.0.0\n"
      "      - name: Push grpc-dc\n"
      "        working-directory: packages/grpc-ruby\n"
      "        run: |\n"
      "          gem build grpc-dc.gemspec\n"
      "          gem push grpc-dc-*.gem\n"
      "      - name: Push kafka-grpc\n"
      "        if: \"!cancelled()\"\n"
      "        working-directory: packages/kafka-ruby\n"
      "        run: |\n"
      "          gem build kafka-grpc.gemspec\n"
      "          gem push kafka-grpc-*.gem\n"
      "      - name: Push eventbus-grpc\n"
      "        if: \"!cancelled()\"\n"
      "        working-directory: packages/eventbus-ruby\n"
      "        run: |\n"
      "          gem build eventbus-grpc.gemspec\n"
      "          gem push eventbus-grpc-*.gem\n")
     out)))

;; LuaRocks: manual-dispatch workflow uploading the rockspecs in
;; packages/grpc-lua and packages/kafka-lua. LuaRocks has no
;; OIDC; publishing uses the account API key in the
;; LUAROCKS_API_KEY repo secret (the first upload also creates
;; the account's packages).
(call-with-output-file (build-path out-dir ".github/workflows/publish-luarocks.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish the grpc-dc and kafka-grpc rocks via LuaRocks\n"
      "# (luarocks upload). Manual dispatch only. Requires the\n"
      "# LUAROCKS_API_KEY repo secret (luarocks.org account key).\n"
      "name: publish-luarocks\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: read\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: leafo/gh-actions-lua@v10\n"
      "        with:\n"
      "          luaVersion: \"5.4\"\n"
      "      - uses: leafo/gh-actions-luarocks@v4\n"
      "      - name: JSON library for luarocks upload\n"
      "        run: luarocks install lua-cjson\n"
      "      - name: Upload grpc-dc\n"
      "        working-directory: packages/grpc-lua\n"
      "        run: |\n"
      "          # luarocks upload also tries to hand the server a\n"
      "          # locally packed src.rock and exits 1 when the\n"
      "          # server builds that rock from the git source\n"
      "          # itself (repeated dispatch: 'revision already\n"
      "          # exists'). Judge by registry state instead.\n"
      "          VER=$(basename grpc-dc-*.rockspec .rockspec | sed 's/^grpc-dc-//')\n"
      "          luarocks upload --api-key ${{ secrets.LUAROCKS_API_KEY }} grpc-dc-*.rockspec || true\n"
      "          curl -sf https://luarocks.org/modules/unicomp21/grpc-dc | grep -q \"$VER\"\n"
      "      - name: Upload kafka-grpc\n"
      "        if: \"!cancelled()\"\n"
      "        working-directory: packages/kafka-lua\n"
      "        run: |\n"
      "          VER=$(basename kafka-grpc-*.rockspec .rockspec | sed 's/^kafka-grpc-//')\n"
      "          luarocks upload --api-key ${{ secrets.LUAROCKS_API_KEY }} kafka-grpc-*.rockspec || true\n"
      "          curl -sf https://luarocks.org/modules/unicomp21/kafka-grpc | grep -q \"$VER\"\n"
      "      - name: Upload eventbus-grpc\n"
      "        if: \"!cancelled()\"\n"
      "        working-directory: packages/eventbus-lua\n"
      "        run: |\n"
      "          VER=$(basename eventbus-grpc-*.rockspec .rockspec | sed 's/^eventbus-grpc-//')\n"
      "          luarocks upload --api-key ${{ secrets.LUAROCKS_API_KEY }} eventbus-grpc-*.rockspec || true\n"
      "          curl -sf https://luarocks.org/modules/unicomp21/eventbus-grpc | grep -q \"$VER\"\n")
     out)))

;; JSR (Deno): manual-dispatch workflow publishing js/ as
;; @browser-grpc/grpc-dc and packages/kafka-js as
;; @browser-grpc/kafka-grpc via `jsr publish` with GitHub OIDC.
;; Requires the one-time scope<->repo package link on jsr.io
;; for both packages (no stored token afterwards).
(call-with-output-file (build-path out-dir ".github/workflows/publish-jsr.yml")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# Publish @browser-grpc/grpc-dc and @browser-grpc/kafka-grpc\n"
      "# to JSR via OIDC. Manual dispatch only. Requires both\n"
      "# packages linked to this repo on jsr.io.\n"
      "name: publish-jsr\n"
      "on: workflow_dispatch\n"
      "permissions:\n"
      "  contents: read\n"
      "  id-token: write\n"
      "jobs:\n"
      "  publish:\n"
      "    runs-on: ubuntu-latest\n"
      "    steps:\n"
      "      - uses: actions/checkout@v4\n"
      "      - uses: denoland/setup-deno@v2\n"
      "        with:\n"
      "          deno-version: v2.x\n"
      "      - name: Publish grpc-dc\n"
      "        working-directory: js\n"
      "        run: npx -y jsr publish --allow-slow-types\n"
      "      - name: Publish kafka-grpc\n"
      "        if: \"!cancelled()\"\n"
      "        working-directory: packages/kafka-js\n"
      "        run: npx -y jsr publish --allow-slow-types\n"
      "      - name: Publish eventbus-grpc\n"
      "        if: \"!cancelled()\"\n"
      "        working-directory: packages/eventbus-js\n"
      "        run: npx -y jsr publish --allow-slow-types\n")
     out)))

;; SwiftPM / Swift Package Index: Package.swift at the export
;; root, so the public repo is itself the Swift package
;; (library product GrpcDc, module Grpcdc from swift/grpcdc;
;; the kafka stubs stay in-module for Swift, as in the tree).
;; SPI listing is a one-time web submission against the public
;; repo; releases are picked up from git tags automatically.
(call-with-output-file (build-path out-dir "Package.swift")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "// swift-tools-version: 5.9\n"
      "// Package.swift for grpc-over-datachannels: the generated,\n"
      "// dependency-free Swift gRPC-over-DataChannels runtime.\n"
      "// Generated by the grpc-dc release generator.\n"
      "import PackageDescription\n\n"
      "let package = Package(\n"
      "    name: \"grpc-over-datachannels\",\n"
      "    products: [\n"
      "        .library(name: \"GrpcDc\", targets: [\"Grpcdc\"]),\n"
      "    ],\n"
      "    targets: [\n"
      "        .target(name: \"Grpcdc\", path: \"swift/grpcdc\"),\n"
      "    ]\n"
      ")\n")
     out)))

;; Zig package manager: build.zig + build.zig.zon at the export
;; root, so the public repo is itself a Zig package fetched by
;; git URL + tag (zig fetch --save git+https://github.com/
;; browser-grpc/grpc-over-datachannels.git#vX.Y.Z). Two modules:
;; grpcdc (zig/grpcdc) and kafka_grpc (the kafka stubs, which in
;; the Zig tree live with the examples). The fixed fingerprint
;; is the package identity and must never change.
(call-with-output-file (build-path out-dir "build.zig")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "// Zig package for grpc-over-datachannels: modules grpcdc\n"
      "// (runtime) and kafka_grpc (grpcdc.kafka.v1 stubs).\n"
      "// Generated by the grpc-dc release generator.\n"
      "const std = @import(\"std\");\n\n"
      "pub fn build(b: *std.Build) void {\n"
      "    const target = b.standardTargetOptions(.{});\n"
      "    const optimize = b.standardOptimizeOption(.{});\n"
      "    const grpcdc = b.addModule(\"grpcdc\", .{\n"
      "        .root_source_file = b.path(\"zig/grpcdc/grpcdc.zig\"),\n"
      "        .target = target,\n"
      "        .optimize = optimize,\n"
      "    });\n"
      "    _ = b.addModule(\"kafka_grpc\", .{\n"
      "        .root_source_file = b.path(\"zig/examples/kafka_grpc_dc.zig\"),\n"
      "        .target = target,\n"
      "        .optimize = optimize,\n"
      "        .imports = &.{.{ .name = \"grpcdc\", .module = grpcdc }},\n"
      "    });\n"
      "    _ = b.addModule(\"eventbus_grpc\", .{\n"
      "        .root_source_file = b.path(\"zig/examples/events_grpc_dc.zig\"),\n"
      "        .target = target,\n"
      "        .optimize = optimize,\n"
      "        .imports = &.{.{ .name = \"grpcdc\", .module = grpcdc }},\n"
      "    });\n"
      "}\n")
     out)))
(call-with-output-file (build-path out-dir "build.zig.zon")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      ".{\n"
      "    .name = .grpc_dc,\n"
      "    .version = \"" (regexp-replace #rx"^v" version "") "\",\n"
      "    .fingerprint = 0xf71c4e31e7d21092,\n"
      "    .minimum_zig_version = \"0.15.1\",\n"
      "    .dependencies = .{},\n"
      "    .paths = .{\n"
      "        \"build.zig\",\n"
      "        \"build.zig.zon\",\n"
      "        \"zig/grpcdc\",\n"
      "        \"zig/examples/kafka_grpc_dc.zig\",\n"
      "        \"zig/examples/kafka_messages.zig\",\n"
      "        \"zig/examples/events_grpc_dc.zig\",\n"
      "        \"zig/examples/events_messages.zig\",\n"
      "        \"LICENSE\",\n"
      "    },\n"
      "}\n")
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
      "        <configuration><excludes><exclude>target/**</exclude></excludes></configuration>\n"
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
      "      - name: Build signed eventbus-grpc bundle\n"
      "        if: \"!cancelled()\"\n"
      "        run: mvn -B -f packages/eventbus-java/pom.xml deploy -Prelease -DcentralBaseUrl=http://127.0.0.1:9/nope || test -f packages/eventbus-java/target/central-publishing/central-bundle.zip\n"
      "        env:\n"
      "          MAVEN_USERNAME: ${{ secrets.CENTRAL_USERNAME }}\n"
      "          MAVEN_PASSWORD: ${{ secrets.CENTRAL_PASSWORD }}\n"
      "          MAVEN_GPG_PASSPHRASE: ${{ secrets.MAVEN_GPG_PASSPHRASE }}\n"
      "      - name: Upload eventbus-grpc via Central Portal API\n"
      "        if: \"!cancelled()\"\n"
      "        shell: bash\n"
      "        run: |\n"
      "          set -euo pipefail\n"
      "          TOKEN=$(printf '%s:%s' \"${{ secrets.CENTRAL_USERNAME }}\" \"${{ secrets.CENTRAL_PASSWORD }}\" | base64 -w0)\n"
      "          zip -d packages/eventbus-java/target/central-publishing/central-bundle.zip '*/_remote.repositories*' '*/maven-metadata-local.xml*' || true\n"
      "          ID=$(curl -sf -X POST -H \"Authorization: Bearer $TOKEN\" -F \"bundle=@packages/eventbus-java/target/central-publishing/central-bundle.zip\" \"https://central.sonatype.com/api/v1/publisher/upload?name=eventbus-grpc&publishingType=USER_MANAGED\")\n"
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
      "        # install, not just package: the kafka/eventbus jar\n"
      "        # builds below resolve grpc-dc from the local repo,\n"
      "        # so this workflow does not depend on Maven Central\n"
      "        # already carrying the version (it is dispatched\n"
      "        # before Central in the publish sequence).\n"
      "        run: mvn -B -f java/pom.xml install -DskipTests\n"
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
      "      - name: Build eventbus-grpc jar and lay out its Maven repository\n"
      "        if: \"!cancelled()\"\n"
      "        shell: bash\n"
      "        run: |\n"
      "          set -euo pipefail\n"
      "          mvn -B -f packages/eventbus-java/pom.xml package -DskipTests\n"
      "          V=$(grep -m1 '<version>' packages/eventbus-java/pom.xml | sed -E 's/<[^>]+>//g; s/^ *//; s/ *$//')\n"
      "          DEST=\"docs/maven/io/github/browser-grpc/eventbus-grpc/$V\"\n"
      "          mkdir -p \"$DEST\"\n"
      "          cp packages/eventbus-java/pom.xml \"$DEST/eventbus-grpc-$V.pom\"\n"
      "          cp \"packages/eventbus-java/target/eventbus-grpc-$V.jar\" \"$DEST/\"\n"
      "          cp \"packages/eventbus-java/target/eventbus-grpc-$V-sources.jar\" \"$DEST/\"\n"
      "          cp \"packages/eventbus-java/target/eventbus-grpc-$V-javadoc.jar\" \"$DEST/\"\n"
      "          for f in \"$DEST\"/*; do\n"
      "            md5sum \"$f\" | cut -d' ' -f1 > \"$f.md5\"\n"
      "            sha1sum \"$f\" | cut -d' ' -f1 > \"$f.sha1\"\n"
      "          done\n"
      "          BASE=docs/maven/io/github/browser-grpc/eventbus-grpc\n"
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
      "                   '  <artifactId>eventbus-grpc</artifactId>', '  <versioning>',\n"
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
      "The Trusted Publishing workflow (path 2) is the active\n"
      "publish path since v0.37.1: `scripts/release-push.sh`\n"
      "dispatches it during a release. The local-token path is\n"
      "kept below as a fallback only; npm retires token-based\n"
      "direct publishing in January 2027.\n\n"
      "## Path 1: local token (fallback)\n\n"
      "With a granular access token (all-packages, bypass 2FA)\n"
      "in `~/.npmrc`: `npm publish --access public` in `js/`\n"
      "and `packages/kafka-js` from the generated export.\n\n"
      "## Path 2: Trusted Publishing via GitHub Actions\n\n"
      "This export ships `.github/workflows/publish-npm.yml`\n"
      "(manual dispatch only). It publishes `js/` (grpc-dc)\n"
      "and `packages/kafka-js` (kafka-grpc) with\n"
      "`npm publish --provenance` using the workflow's OIDC\n"
      "identity — no token is stored anywhere.\n\n"
      "One-time setup on npmjs.com (package owner, passkey\n"
      "required), once per package:\n\n"
      "1. Open the package settings (`grpc-dc` and\n"
      "   `kafka-grpc`), Trusted Publisher.\n"
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
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "COPY rust ./rust" "COPY conformance ./conformance" "COPY crates/kafka-native ./crates/kafka-native" "COPY webrtc/rust ./webrtc/rust" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN cd rust && cargo fetch --locked && cargo test --locked --no-run")
         "cd rust && cargo test --locked -- --skip official_clients_call_rust_server")
   (list "go" "golang:1.24-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs curl && rm -rf /var/lib/apt/lists/*" "COPY go ./go" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto" "COPY webrtc/go ./webrtc/go" "COPY webrtc/rust ./webrtc/rust" "COPY rust ./rust" "COPY crates/dc-sctp-ffi ./crates/dc-sctp-ffi" "COPY crates/dc-dtls-ffi ./crates/dc-dtls-ffi" "COPY crates/dc-ice-ffi ./crates/dc-ice-ffi" "RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable" "RUN export PATH=\"$HOME/.cargo/bin:$PATH\" && cd crates/dc-sctp-ffi && cargo build --release && cd ../dc-dtls-ffi && cargo build --release && cd ../dc-ice-ffi && cargo build --release && cd ../../rust && cargo build --release" "RUN cd go && go mod edit -replace=github.com/browser-grpc/grpc-over-datachannels/webrtc/go=../webrtc/go && go mod tidy && go build ./...")
         "cd go && GRPCDC_STRUCTDC_LIB=/src/rust/target/release/libgrpc_dc.so go test -race -skip 'Sidecar|TestInteropOfficialClientsCallGoServer' ./...")
   (list "js" "node:24-bookworm-slim"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs git curl ca-certificates build-essential && rm -rf /var/lib/apt/lists/*" "COPY js ./js" "COPY webrtc/js ./webrtc/js" "COPY webrtc/rust ./webrtc/rust" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto" "COPY examples/tracing ./examples/tracing" "COPY crates/dc-sctp-wasm ./crates/dc-sctp-wasm" "COPY crates/dc-dtls-wasm ./crates/dc-dtls-wasm" "COPY crates/dc-ice-wasm ./crates/dc-ice-wasm" "COPY crates/dc-bridge-wasm ./crates/dc-bridge-wasm" "COPY rust ./rust" "RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable && export PATH=\"$HOME/.cargo/bin:$PATH\" && rustup target add wasm32-unknown-unknown && cargo install wasm-bindgen-cli --version 0.2.100" "RUN export PATH=\"$HOME/.cargo/bin:$PATH\" && for c in sctp dtls ice; do (cd crates/dc-$c-wasm && cargo build --release --target wasm32-unknown-unknown && wasm-bindgen --target web --out-dir ../../browser-test/dc_${c}_gen target/wasm32-unknown-unknown/release/dc_${c}_wasm.wasm); done && (cd crates/dc-bridge-wasm && cargo build --release --target wasm32-unknown-unknown && wasm-bindgen --target web --out-dir ../../browser-test/dc_bridge_gen target/wasm32-unknown-unknown/release/dc_bridge_wasm.wasm)")
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
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs curl ca-certificates && rm -rf /var/lib/apt/lists/*" "COPY cpp ./cpp" "COPY rust ./rust" "RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable && export PATH=\"$HOME/.cargo/bin:$PATH\" && cd rust && cargo build --release"  "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p cpp/build && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/tests/main.cpp cpp/tests/test_codec.cpp cpp/tests/test_echo.cpp cpp/tests/test_interop.cpp cpp/tests/test_interop_oracle.cpp cpp/tests/test_interop_server_oracle.cpp cpp/tests/test_oracle.cpp cpp/tests/test_dynamic.cpp cpp/tests/test_bdd.cpp cpp/tests/test_deadline.cpp cpp/tests/test_tracing.cpp cpp/tests/test_inline_pump.cpp cpp/tests/test_pb_messages.cpp cpp/tests/test_bdd_schemas.cpp cpp/tests/test_sidecar.cpp cpp/tests/test_bdd_sidecar.cpp cpp/tests/test_eventbus.cpp cpp/tests/test_kafka_e2e.cpp cpp/tests/test_struct_codec.cpp -L rust/target/release -lgrpc_dc -Wl,-rpath,$PWD/rust/target/release -o cpp/build/tests && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/examples/echo_server_stdio.cpp -L rust/target/release -lgrpc_dc -Wl,-rpath,$PWD/rust/target/release -o cpp/build/echo_server_stdio && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/examples/echo_client_stdio.cpp -L rust/target/release -lgrpc_dc -Wl,-rpath,$PWD/rust/target/release -o cpp/build/echo_client_stdio && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/examples/dynamic_echo_server_stdio.cpp -L rust/target/release -lgrpc_dc -Wl,-rpath,$PWD/rust/target/release -o cpp/build/dynamic_echo_server_stdio && g++ -std=c++20 -pthread -O1 -Icpp -I. cpp/tests/test_async.cpp -o cpp/build/test_async")
         (string-append "cd cpp && "
                        (test-loop "./build/tests ~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestDeadline" "TestBddSchemas" "TestPbMessages"))
                        " && ./build/test_async"))
   (list "swift" "swift:6.2-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs curl ca-certificates && rm -rf /var/lib/apt/lists/*" "COPY swift ./swift" "COPY rust ./rust" "RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable && export PATH=\"$HOME/.cargo/bin:$PATH\" && cd rust && cargo build --release"  "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p swift/build && swiftc -swift-version 5 -O -L rust/target/release -lgrpc_dc -Xlinker -rpath -Xlinker $PWD/rust/target/release swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoRequestStruct.swift swift/examples/EchoResponseStruct.swift swift/examples/StructDcBridge.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/DynamicEchoService.swift swift/examples/interop/*.swift $(ls swift/tests/*.swift | grep -v TestKafkaNative.swift) -o swift/build/tests && swiftc -swift-version 5 -O -L rust/target/release -lgrpc_dc -Xlinker -rpath -Xlinker $PWD/rust/target/release swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoRequestStruct.swift swift/examples/EchoResponseStruct.swift swift/examples/StructDcBridge.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/EchoServerStdio/main.swift -o swift/build/echo_server_stdio && swiftc -swift-version 5 -O -L rust/target/release -lgrpc_dc -Xlinker -rpath -Xlinker $PWD/rust/target/release swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoRequestStruct.swift swift/examples/EchoResponseStruct.swift swift/examples/StructDcBridge.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/EchoClientStdio/main.swift -o swift/build/echo_client_stdio && swiftc -swift-version 5 -O -L rust/target/release -lgrpc_dc -Xlinker -rpath -Xlinker $PWD/rust/target/release swift/grpcdc/*.swift swift/examples/StdioTransport.swift swift/examples/DynamicEchoService.swift swift/examples/DynamicEchoServerStdio/main.swift -o swift/build/dynamic_echo_server_stdio")
         (string-append "cd swift && "
                        (test-loop "./build/tests ~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestDeadline" "TestBddSchemas" "TestPbMessages"))))
   (list "kotlin" "eclipse-temurin:21-jdk"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "RUN apt-get update && apt-get install -y curl unzip && curl -fsSL https://github.com/JetBrains/kotlin/releases/download/v2.4.0/kotlin-compiler-2.4.0.zip -o /tmp/kotlin.zip && unzip -q /tmp/kotlin.zip -d /opt && rm /tmp/kotlin.zip"
           "ENV PATH=\"/opt/kotlinc/bin:${PATH}\""
           "COPY kotlin ./kotlin" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p kotlin/build && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoRequestStruct.kt kotlin/examples/EchoResponseStruct.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/DynamicEchoService.kt kotlin/examples/interop/*.kt kotlin/tests/*.kt -d kotlin/build/tests.jar && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoRequestStruct.kt kotlin/examples/EchoResponseStruct.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/EchoServerStdio/Main.kt -d kotlin/build/echo_server_stdio.jar && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoRequestStruct.kt kotlin/examples/EchoResponseStruct.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/EchoClientStdio/Main.kt -d kotlin/build/echo_client_stdio.jar && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/StdioTransport.kt kotlin/examples/DynamicEchoService.kt kotlin/examples/DynamicEchoServerStdio/Main.kt -d kotlin/build/dynamic_echo_server_stdio.jar")
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
           "COPY zig ./zig" "COPY rust ./rust" "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable && export PATH=\"$HOME/.cargo/bin:$PATH\" && cd rust && cargo build --release"
           "RUN cd zig && zig build --prefix build")
         (string-append "cd zig && "
                        (test-loop "./build/bin/tests ~a"
                                   '("TestCodec" "TestEcho" "TestBdd" "TestBddSchemas" "TestPbMessages"))))
   (list "c" "gcc:14-bookworm"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs curl ca-certificates && rm -rf /var/lib/apt/lists/*" "COPY c ./c" "COPY rust ./rust" "RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable && export PATH=\"$HOME/.cargo/bin:$PATH\" && cd rust && cargo build --release"  "COPY fixtures ./fixtures" "COPY bin ./bin" "COPY webapp/testdata ./webapp/testdata" "COPY docs/app/protoc-gen-grpc-dc.mjs ./docs/app/protoc-gen-grpc-dc.mjs" "COPY docs/app/gen ./docs/app/gen" "COPY proto ./proto"
           "RUN mkdir -p c/build && gcc -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -pthread -O1 -Ic -Ic/examples -Ic/tests c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/grpcdc/sidecar_transport.c c/grpcdc/dynamic.c c/examples/stdio_transport.c c/tests/main.c -L rust/target/release -lgrpc_dc -Wl,-rpath,$PWD/rust/target/release -o c/build/tests && gcc -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -pthread -O1 -Ic -Ic/examples -Ic/tests c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/examples/stdio_transport.c c/examples/echo_server_stdio.c -L rust/target/release -lgrpc_dc -Wl,-rpath,$PWD/rust/target/release -o c/build/echo_server_stdio && gcc -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -pthread -O1 -Ic -Ic/examples -Ic/tests c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/examples/stdio_transport.c c/examples/echo_client_stdio.c -L rust/target/release -lgrpc_dc -Wl,-rpath,$PWD/rust/target/release -o c/build/echo_client_stdio")
         (test-loop "./c/build/tests ~a"
                    '("TestCodec" "TestEcho" "TestBdd" "TestBddSchemas" "TestPbMessages")))
   (list "lua" "debian:bookworm-slim"
         '("RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler nodejs && rm -rf /var/lib/apt/lists/*" "RUN apt-get update && apt-get install -y build-essential curl ca-certificates libreadline-dev && (curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 https://www.lua.org/ftp/lua-5.4.8.tar.gz -o /tmp/lua.tar.gz && tar -xzf /tmp/lua.tar.gz -C /tmp && make -C /tmp/lua-5.4.8 linux && cp /tmp/lua-5.4.8/src/lua /usr/local/bin/lua || apt-get install -y --no-install-recommends lua5.4)"
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
      "      - name: Build Rust FFI cores for the Go rendezvous server\n"
      "        run: for c in sctp dtls ice; do (cd crates/dc-$c-ffi && cargo build --release); done\n"
      "      - name: Build Rust peer for browser suites\n"
      "        run: cargo build --manifest-path webrtc/rust/Cargo.toml --example peer_echo\n"
      "      - name: Generate Rust-core Wasm glue\n"
      "        run: |\n"
      "          rustup target add wasm32-unknown-unknown\n"
      "          cargo install wasm-bindgen-cli --version 0.2.100\n"
      "          for c in sctp dtls ice; do (cd crates/dc-$c-wasm && cargo build --release --target wasm32-unknown-unknown && wasm-bindgen --target web --out-dir ../../browser-test/dc_${c}_gen target/wasm32-unknown-unknown/release/dc_${c}_wasm.wasm); done\n"
      "          (cd crates/dc-bridge-wasm && cargo build --release --target wasm32-unknown-unknown && wasm-bindgen --target web --out-dir ../../browser-test/dc_bridge_gen target/wasm32-unknown-unknown/release/dc_bridge_wasm.wasm)\n"
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
      "COPY go ./go\nCOPY webrtc/go ./webrtc/go\nCOPY webrtc/rust ./webrtc/rust\nCOPY crates/dc-sctp-ffi ./crates/dc-sctp-ffi\nCOPY crates/dc-dtls-ffi ./crates/dc-dtls-ffi\nCOPY crates/dc-ice-ffi ./crates/dc-ice-ffi\nCOPY python ./python\nCOPY js ./js\n"
      "RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/* && curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable\n"
      "RUN export PATH=\"$HOME/.cargo/bin:$PATH\" && cd crates/dc-sctp-ffi && cargo build --release && cd ../dc-dtls-ffi && cargo build --release && cd ../dc-ice-ffi && cargo build --release\n"
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
      "COPY crates/kafka-native ./crates/kafka-native\n"
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
  (for ([dir (in-list '("rust" "webrtc/rust" "proto" "fixtures" "crates/kafka-native"))])
    (make-directory* (path-only (build-path kafka-proxy-out dir)))
    (copy-directory/files (build-path out-dir dir)
                          (build-path kafka-proxy-out dir)))
  (for ([f (in-list '("LICENSE" "KAFKA.md" "CONTRIBUTING.md" "SECURITY.md"))])
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
    "COPY crates/kafka-native ./crates/kafka-native\n"
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

(define kn-bare-version
  (if (string-prefix? version "v") (substring version 1) version))

;; ---------------------------------------------------------------------------
;; Dedicated kafka-native repo export (browser-grpc/kafka-native):
;; the in-process Kafka protocol client — Rust crate, C ABI,
;; Python wrapper — as a standalone subset of the main export
;; plus its maintained crate sources (tracked files only), its
;; own README, CI Dockerfile, e2e runner, and GitHub workflow.
;; Same leak rule: no Racket source ever crosses.
;; ---------------------------------------------------------------------------

(define (emit-kn-file rel text [mode #f])
  (define dest (build-path kafka-native-out rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest
    (lambda (out) (display text out)) #:exists 'replace)
  (when mode (file-or-directory-permissions dest mode)))

(when (non-empty-string? kafka-native-out)
  (when (directory-exists? kafka-native-out)
    (delete-directory/files kafka-native-out))
  (make-directory* kafka-native-out)
  (for ([dir (in-list '("rust" "python" "proto" "fixtures" "webrtc/rust"))])
    (make-directory* (path-only (build-path kafka-native-out dir)))
    (copy-directory/files (build-path out-dir dir)
                          (build-path kafka-native-out dir)))
  ;; Maintained crate sources: tracked files only, so build
  ;; output never crosses.
  (for ([rel (in-list (string-split
                       (sh "git ls-files crates/kafka-native")
                       "\n"))])
    (define dest (build-path kafka-native-out rel))
    (make-directory* (path-only dest))
    (copy-file rel dest #t))
  (for ([f (in-list '("LICENSE" "GENERATED-CODE-LICENSE.md" "KAFKA.md" "CONTRIBUTING.md" "SECURITY.md"))])
    (copy-file (build-path out-dir f) (build-path kafka-native-out f) #t))
  (emit-kn-file
   "RELEASE.json"
   (string-append "{\n  \"version\": \"" version "\",\n"
                  "  \"sourceCommit\": \"" source-commit "\",\n"
                  "  \"generated\": true\n}\n"))
  (emit-kn-file
   "README.md"
   (string-append
    "# Kafka native client\n"
    "\n"
    "An in-process Kafka protocol client for native applications:\n"
    "the Kafka wire implementation runs in your process — no proxy\n"
    "process, no gRPC hop. It speaks the Kafka binary protocol to\n"
    "Apache Kafka (KRaft) or Redpanda, negotiating API versions\n"
    "per connection.\n"
    "\n"
    "Three form factors share one wire implementation:\n"
    "\n"
    "- **kafka-native** (this repo) — in-process library: Rust\n"
    "  crate, C ABI, per-language FFI wrappers. Native only.\n"
    "- **kafka-grpc** — generated client stubs over gRPC\n"
    "  transports from [grpc-over-datachannels](https://github.com/browser-grpc/grpc-over-datachannels);\n"
    "  browser OK, reaches a broker through the proxy.\n"
    "- **kafka-proxy** — the [sidecar](https://github.com/browser-grpc/kafka-proxy)\n"
    "  that bridges the two.\n"
    "\n"
    "This repository is a generated export (version " version ").\n"
    "\n"
    "## Use\n"
    "\n"
    "Rust:\n"
    "\n"
    "```toml\n"
    "kafka-native = \"0.1\"\n"
    "```\n"
    "\n"
    "```rust\n"
    "let broker = kafka_native::Broker::new(config);\n"
    "broker.create_topics(vec![(\"events\".into(), 3, 1)], 30_000, false).await?;\n"
    "```\n"
    "\n"
    "C: link `libkafka_native` and include\n"
    "`crates/kafka-native/include/kafka_native.h`. Calls take a\n"
    "method name and the protobuf-encoded request and return the\n"
    "protobuf-encoded response.\n"
    "\n"
    "Python (stdlib `ctypes`, same generated messages as the\n"
    "gRPC client):\n"
    "\n"
    "```python\n"
    "from grpcdc.kafka_native import NativeKafkaClient\n"
    "client = NativeKafkaClient(\"127.0.0.1:9092\")\n"
    "```\n"
    "\n"
    "Surface: metadata, produce/consume, producer sessions\n"
    "(idempotence, transactions), consumer groups, and the admin\n"
    "operations (configs, partitions, delete-records, groups,\n"
    "ACLs, transactions) — see [KAFKA.md](KAFKA.md). Plaintext\n"
    "brokers only for now; SASL/TLS stay on the sidecar path.\n"
    "\n"
    "## Tests\n"
    "\n"
    "```sh\n"
    "docker build -f docker/kafka-native-ci.Dockerfile -t kafka-native-ci .\n"
    "docker run --rm kafka-native-ci\n"
    "```\n"
    "\n"
    "GitHub Actions runs the same image on every push.\n"))
  (emit-kn-file
   "docker/kafka-native-ci.Dockerfile"
   (string-append
    "# Kafka native CI — generated. DO NOT EDIT.\n"
    "# Builds libkafka_native and runs the direct, FFI, Python,\n"
    "# and C test legs against a real Apache Kafka fixture,\n"
    "# all inside the image.\n"
    "#   docker build -f docker/kafka-native-ci.Dockerfile -t kafka-native-ci .\n"
    "#   docker run --rm kafka-native-ci\n"
    "FROM rust:1-bookworm\n"
    "RUN apt-get update && apt-get install -y --no-install-recommends default-jdk-headless curl ca-certificates procps python3 gcc && rm -rf /var/lib/apt/lists/*\n"
    "RUN curl -fsSL https://downloads.apache.org/kafka/4.3.1/kafka_2.13-4.3.1.tgz -o /tmp/kafka.tgz && mkdir -p /opt/kafka && tar -xzf /tmp/kafka.tgz -C /opt/kafka --strip-components=1 && rm /tmp/kafka.tgz\n"
    "ENV KAFKA_HOME=/opt/kafka\n"
    "WORKDIR /src\n"
    "COPY rust ./rust\n"
    "COPY webrtc/rust ./webrtc/rust\n"
    "COPY crates ./crates\n"
    "COPY python ./python\n"
    "COPY proto ./proto\n"
    "COPY fixtures ./fixtures\n"
    "COPY scripts/run-e2e.sh ./scripts/run-e2e.sh\n"
    "CMD [\"bash\", \"scripts/run-e2e.sh\"]\n"))
  (emit-kn-file
   "scripts/run-e2e.sh"
   (string-append
    "#!/usr/bin/env bash\n"
    "# Run the kafka-native legs (Rust direct, Rust FFI, C\n"
    "# smoke, Python) against a real Apache Kafka broker\n"
    "# started here and killed on exit.\n"
    "set -uo pipefail\n"
    "ROOT=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")/..\" && pwd)\"\n"
    "KAFKA_HOME=\"${KAFKA_HOME:-/opt/kafka}\"\n"
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
    "FAILED=0\n"
    "start_kafka || exit 1\n"
    "echo \"== rust direct + admin (apache kafka)\"\n"
    "(cd \"$ROOT/rust\" && KAFKA_PROXY_E2E_BROKER=127.0.0.1:19092 cargo test --test kafka_direct_e2e --test kafka_admin_e2e) || FAILED=1\n"
    "echo \"== rust ffi (apache kafka)\"\n"
    "(cd \"$ROOT/rust\" && KAFKA_PROXY_E2E_BROKER=127.0.0.1:19092 cargo test --test kafka_native_ffi_e2e) || FAILED=1\n"
    "echo \"== building libkafka_native\"\n"
    "(cd \"$ROOT/crates/kafka-native\" && cargo build) || FAILED=1\n"
    "echo \"== c ffi smoke\"\n"
    "cc -O1 -I\"$ROOT/crates/kafka-native/include\" \"$ROOT/crates/kafka-native/tests/ffi_smoke.c\" -L\"$ROOT/crates/kafka-native/target/debug\" -lkafka_native -Wl,-rpath,\"$ROOT/crates/kafka-native/target/debug\" -o \"$TMP/ffi_smoke\" && \"$TMP/ffi_smoke\" 127.0.0.1:19092 || FAILED=1\n"
    "echo \"== python native (apache kafka)\"\n"
    "(cd \"$ROOT/python\" && KAFKA_E2E_BROKER=127.0.0.1:19092 GRPC_DC_KAFKA_NATIVE_LIB=\"$ROOT/crates/kafka-native/target/debug/libkafka_native.so\" python3 -m unittest tests.test_kafka_native) || FAILED=1\n"
    "exit \"$FAILED\"\n")
   #o755)
  (define kn-kn-bare-version
    (if (string-prefix? version "v") (substring version 1) version))
  ;; Stamp the crate version to the release version so the
  ;; crates.io publish matches the release. The grpc-dc path
  ;; dependency gains the matching version (cargo strips the
  ;; path when packaging; the exported rust/ tree is stamped
  ;; to the same version so in-repo builds still resolve via
  ;; the path), and the generated pb/stub modules are copied
  ;; inside the crate (lib.rs reaches them via ../../../rust/
  ;; in the source tree, which a packaged crate cannot do).
  (let* ([cargo (build-path kafka-native-out "crates/kafka-native/Cargo.toml")]
         [stamped (string-replace (file->string cargo)
                                  "version = \"0.1.0\""
                                  (string-append "version = \"" kn-bare-version "\""))]
         [stamped (string-replace stamped
                                  "grpc-dc = { path = \"../../rust\" }"
                                  (string-append "grpc-dc = { version = \"" kn-bare-version "\", path = \"../../rust\" }"))])
    (call-with-output-file cargo
      (lambda (out) (display stamped out))
      #:exists 'replace))
  ;; The crate's Cargo.lock must carry the stamped version too:
  ;; cargo publish updates a stale lock itself and then refuses
  ;; the dirty tree, which is exactly how v0.42.0 failed.
  (let* ([lock (build-path kafka-native-out "crates/kafka-native/Cargo.lock")]
         [stamped (string-replace (file->string lock)
                                  "name = \"kafka-native\"\nversion = \"0.1.0\""
                                  (string-append "name = \"kafka-native\"\nversion = \"" kn-bare-version "\""))]
         [stamped (string-replace stamped
                                  "name = \"grpc-dc\"\nversion = \"0.1.0\""
                                  (string-append "name = \"grpc-dc\"\nversion = \"" kn-bare-version "\""))])
    (call-with-output-file lock
      (lambda (out) (display stamped out))
      #:exists 'replace))
  (let* ([rust-cargo (build-path kafka-native-out "rust/Cargo.toml")]
         [stamped (string-replace (file->string rust-cargo)
                                  "version = \"0.1.0\""
                                  (string-append "version = \"" kn-bare-version "\""))])
    (call-with-output-file rust-cargo
      (lambda (out) (display stamped out))
      #:exists 'replace))
  (make-directory* (build-path kafka-native-out "crates/kafka-native/src/gen"))
  (for ([gen (in-list '("kafka_pb.rs" "kafka_grpc_dc.rs"))])
    (copy-file (build-path out-dir "rust/gen" gen)
               (build-path kafka-native-out "crates/kafka-native/src/gen" gen)
               #t))
  (let* ([lib (build-path kafka-native-out "crates/kafka-native/src/lib.rs")]
         [rewritten (string-replace (file->string lib)
                                    "../../../rust/gen/kafka_pb.rs"
                                    "gen/kafka_pb.rs")]
         [rewritten (string-replace rewritten
                                    "../../../rust/gen/kafka_grpc_dc.rs"
                                    "gen/kafka_grpc_dc.rs")])
    (call-with-output-file lib
      (lambda (out) (display rewritten out))
      #:exists 'replace))
  (emit-kn-file
   ".github/workflows/publish-crates.yml"
   (string-append
    "# Publish the kafka-native crate via crates.io Trusted\n"
    "# Publishing (OIDC). Manual dispatch only. Requires a\n"
    "# Trusted Publisher configured for the crate on crates.io\n"
    "# (this repo + this workflow file).\n"
    "name: publish-crates\n"
    "on: workflow_dispatch\n"
    "permissions:\n"
    "  contents: read\n"
    "  id-token: write\n"
    "jobs:\n"
    "  publish:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - uses: actions/checkout@v4\n"
    "      - uses: dtolnay/rust-toolchain@stable\n"
    "      - uses: rust-lang/crates-io-auth-action@v1\n"
    "        id: auth\n"
    "      - name: Publish kafka-native (retry while the index catches up)\n"
    "        working-directory: crates/kafka-native\n"
    "        run: |\n"
    "          for i in $(seq 1 20); do\n"
    "            cargo publish --token ${{ steps.auth.outputs.token }} && exit 0\n"
    "            sleep 30\n"
    "          done\n"
    "          exit 1\n"))
  (emit-kn-file
   ".github/workflows/publish-pypi.yml"
   (string-append
    "# Publish the kafka-native Python wheel (bundled\n"
    "# libkafka_native) via PyPI Trusted Publishing (OIDC).\n"
    "# Manual dispatch only. Requires a Trusted Publisher\n"
    "# configured for the project on PyPI (this repo + this\n"
    "# workflow file).\n"
    "name: publish-pypi\n"
    "on: workflow_dispatch\n"
    "permissions:\n"
    "  contents: read\n"
    "  id-token: write\n"
    "jobs:\n"
    "  build:\n"
    "    strategy:\n"
    "      fail-fast: false\n"
    "      matrix:\n"
    "        include:\n"
    "          - runner: ubuntu-latest\n"
    "            image: quay.io/pypa/manylinux_2_28_x86_64\n"
    "            slug: linux-x86_64\n"
    "          - runner: ubuntu-24.04-arm\n"
    "            image: quay.io/pypa/manylinux_2_28_aarch64\n"
    "            slug: linux-aarch64\n"
    "          - runner: macos-latest\n"
    "            slug: mac-arm64-py312\n"
    "            python: '3.12'\n"
    "            macarch: arm64\n"
    "          - runner: macos-latest\n"
    "            slug: mac-arm64-py313\n"
    "            python: '3.13'\n"
    "            macarch: arm64\n"
    "          - runner: macos-latest\n"
    "            slug: mac-x86_64-py312\n"
    "            python: '3.12'\n"
    "            macarch: x86_64\n"
    "          - runner: macos-latest\n"
    "            slug: mac-x86_64-py313\n"
    "            python: '3.13'\n"
    "            macarch: x86_64\n"
    "    runs-on: ${{ matrix.runner }}\n"
    "    steps:\n"
    "      - uses: actions/checkout@v4\n"
    "      - name: Build wheels in manylinux_2_28 (cp312 + cp313)\n"
    "        if: ${{ matrix.image }}\n"
    "        run: |\n"
    "          docker run --rm -v \"$PWD:/io\" -w /io \"${{ matrix.image }}\" bash -c '\n"
    "            set -e\n"
    "            curl --proto \"=https\" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null\n"
    "            export PATH=\"$HOME/.cargo/bin:$PATH\"\n"
    "            (cd crates/kafka-native && cargo build --release)\n"
    "            mkdir -p wheel/grpcdc wheel/dist\n"
    "            cp python/grpcdc/*.py wheel/grpcdc/\n"
    "            cp crates/kafka-native/target/release/libkafka_native.so wheel/grpcdc/\n"
    "            cp python/pyproject-kafka-native.toml wheel/pyproject.toml\n"
    "            cp python/setup-kafka-native.py wheel/setup.py\n"
    "            cp README.md wheel/README.md\n"
    "            for PY in cp312-cp312 cp313-cp313; do\n"
    "              /opt/python/$PY/bin/python -m pip install -q build wheel\n"
    "              (cd wheel && /opt/python/$PY/bin/python -m build --wheel --outdir dist-$PY)\n"
    "              /opt/python/$PY/bin/python -m wheel tags --platform-tag manylinux_2_28_$(uname -m) --remove wheel/dist-$PY/*.whl\n"
    "              cp wheel/dist-$PY/*.whl wheel/dist/\n"
    "            done\n"
    "          '\n"
    "      - name: Set up Rust (macOS)\n"
    "        if: ${{ !matrix.image }}\n"
    "        uses: dtolnay/rust-toolchain@stable\n"
    "      - name: Add x86_64 target (macOS cross)\n"
    "        if: ${{ matrix.macarch == 'x86_64' }}\n"
    "        run: rustup target add x86_64-apple-darwin\n"
    "      - name: Set up Python (macOS)\n"
    "        if: ${{ !matrix.image }}\n"
    "        uses: actions/setup-python@v5\n"
    "        with:\n"
    "          python-version: ${{ matrix.python }}\n"
    "      - name: Build wheel (macOS)\n"
    "        if: ${{ !matrix.image }}\n"
    "        run: |\n"
    "          if [ \"${{ matrix.macarch }}\" = \"x86_64\" ]; then\n"
    "            (cd crates/kafka-native && cargo build --release --target x86_64-apple-darwin)\n"
    "            LIB=crates/kafka-native/target/x86_64-apple-darwin/release/libkafka_native.dylib\n"
    "            TAG=macosx_10_12_x86_64\n"
    "          else\n"
    "            (cd crates/kafka-native && cargo build --release)\n"
    "            LIB=crates/kafka-native/target/release/libkafka_native.dylib\n"
    "            TAG=macosx_11_0_arm64\n"
    "          fi\n"
    "          if [ -f \"$LIB\" ]; then echo \"built $LIB\"; else echo \"LIB MISSING: $LIB\"; find crates/kafka-native/target -name 'libkafka_native*' 2>/dev/null | head -3; fi\n"
    "          mkdir -p wheel/grpcdc wheel/dist\n"
    "          cp python/grpcdc/*.py wheel/grpcdc/\n"
    "          cp \"$LIB\" wheel/grpcdc/libkafka_native.dylib\n"
    "          cp python/pyproject-kafka-native.toml wheel/pyproject.toml\n"
    "          cp python/setup-kafka-native.py wheel/setup.py\n"
    "          cp README.md wheel/README.md\n"
    "          pip install build wheel\n"
    "          (cd wheel && python -m build --wheel)\n"
    "          python -m wheel tags --platform-tag \"$TAG\" --remove wheel/dist/*.whl\n"
    "      - uses: actions/upload-artifact@v4\n"
    "        with:\n"
    "          name: ${{ matrix.slug }}\n"
    "          path: wheel/dist/*.whl\n"
    "  sdist:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - uses: actions/checkout@v4\n"
    "      - uses: actions/setup-python@v5\n"
    "        with:\n"
    "          python-version: '3.12'\n"
    "      - name: Assemble sdist tree (crate sources, no prebuilt lib)\n"
    "        run: |\n"
    "          mkdir -p wheel/grpcdc wheel/crates\n"
    "          cp python/grpcdc/*.py wheel/grpcdc/\n"
    "          cp python/pyproject-kafka-native.toml wheel/pyproject.toml\n"
    "          cp python/setup-kafka-native.py wheel/setup.py\n"
    "          cp python/MANIFEST-kafka-native.in wheel/MANIFEST.in\n"
    "          cp README.md wheel/README.md\n"
    "          cp -r crates/kafka-native wheel/crates/kafka-native\n"
    "          rm -rf wheel/crates/kafka-native/target\n"
    "          cp -r rust wheel/rust\n"
    "          rm -rf wheel/rust/target\n"
    "          cp -r webrtc wheel/webrtc\n"
    "          rm -rf wheel/webrtc/*/target\n"
    "          cp crates/kafka-native/Cargo.lock wheel/Cargo.lock\n"
    "      - name: Build sdist\n"
    "        working-directory: wheel\n"
    "        run: |\n"
    "          pip install build\n"
    "          python -m build --sdist\n"
    "      - uses: actions/upload-artifact@v4\n"
    "        with:\n"
    "          name: sdist\n"
    "          path: wheel/dist/*.tar.gz\n"
    "  publish:\n"
    "    needs: [build, sdist]\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - uses: actions/download-artifact@v4\n"
    "        with:\n"
    "          path: wheel/dist\n"
    "          merge-multiple: true\n"
    "      - name: Publish to PyPI\n"
    "        uses: pypa/gh-action-pypi-publish@release/v1\n"
    "        with:\n"
    "          packages-dir: wheel/dist\n"
    "          skip-existing: true\n"))
  (emit-kn-file
   "python/pyproject-kafka-native.toml"
   (string-append
    "[build-system]\n"
    "requires = [\"setuptools>=61\", \"wheel\"]\n"
    "build-backend = \"setuptools.build_meta\"\n"
    "\n"
    "[project]\n"
    "name = \"kafka-native\"\n"
    "version = \"" kn-bare-version "\"\n"
    "description = \"Kafka native client — in-process Kafka protocol library (bundled libkafka_native) for Apache Kafka/Redpanda, via the grpcdc.kafka.v1 message types\"\n"
    "readme = \"README.md\"\n"
    "requires-python = \">=3.9\"\n"
    "license = {text = \"Apache-2.0\"}\n"
    "dependencies = [\"grpc-dc>=" kn-bare-version "\"]\n"
    "\n"
    "[tool.setuptools.packages.find]\n"
    "include = [\"grpcdc*\"]\n"
    "\n"
    "[tool.setuptools.package-data]\n"
    "grpcdc = [\"*.so\", \"*.dylib\"]\n"))
  (emit-kn-file
   "python/setup-kafka-native.py"
   (string-append
    "# Marks the wheel as platform-specific (it bundles\n"
    "# libkafka_native) instead of py3-none-any. Wheels carry\n"
    "# a prebuilt library; the sdist carries the crate sources\n"
    "# and BuildPy compiles them with cargo at install time.\n"
    "import glob\n"
    "import os\n"
    "import shutil\n"
    "import subprocess\n"
    "\n"
    "from setuptools import setup\n"
    "from setuptools.command.build_py import build_py\n"
    "from wheel.bdist_wheel import bdist_wheel\n"
    "\n"
    "LIB_NAMES = (\"libkafka_native.so\", \"libkafka_native.dylib\", \"kafka_native.dll\")\n"
    "\n"
    "\n"
    "class PlatformWheel(bdist_wheel):\n"
    "    def finalize_options(self):\n"
    "        super().finalize_options()\n"
    "        self.root_is_pure = False\n"
    "\n"
    "\n"
    "class BuildPy(build_py):\n"
    "    def run(self):\n"
    "        super().run()\n"
    "        dest_dir = os.path.join(self.build_lib, \"grpcdc\")\n"
    "        if any(os.path.exists(os.path.join(dest_dir, n)) for n in LIB_NAMES):\n"
    "            return\n"
    "        here = os.path.dirname(os.path.abspath(__file__))\n"
    "        crate = next(\n"
    "            (\n"
    "                c\n"
    "                for c in (\n"
    "                    os.path.join(here, \"crates\", \"kafka-native\"),\n"
    "                    os.path.join(here, \"..\", \"crates\", \"kafka-native\"),\n"
    "                )\n"
    "                if os.path.exists(os.path.join(c, \"Cargo.toml\"))\n"
    "            ),\n"
    "            os.path.join(here, \"crates\", \"kafka-native\"),\n"
    "        )\n"
    "        subprocess.check_call([\"cargo\", \"build\", \"--release\"], cwd=crate)\n"
    "        built = []\n"
    "        for name in LIB_NAMES:\n"
    "            built += glob.glob(os.path.join(crate, \"target\", \"release\", name))\n"
    "        if not built:\n"
    "            raise RuntimeError(\"cargo build produced no libkafka_native library\")\n"
    "        os.makedirs(dest_dir, exist_ok=True)\n"
    "        shutil.copy(built[0], dest_dir)\n"
    "\n"
    "\n"
    "setup(cmdclass={\"bdist_wheel\": PlatformWheel, \"build_py\": BuildPy})\n"))
  (emit-kn-file
   "python/MANIFEST-kafka-native.in"
   (string-append
    "include README.md\n"
    "include Cargo.lock\n"
    "recursive-include crates/kafka-native *.rs *.toml *.lock *.h\n"
    "recursive-include rust *.rs *.toml\n"
    "recursive-include webrtc *.rs *.toml\n"))
(emit-kn-file
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
    "      - name: Build CI image (broker + toolchain)\n"
    "        run: docker build -f docker/kafka-native-ci.Dockerfile -t kafka-native-ci .\n"
    "      - name: Run native legs (Apache Kafka)\n"
    "        run: docker run --rm kafka-native-ci\n"))
  ;; Leak gate for the subset export.
  (let* ([kn-files (find-files file-exists? kafka-native-out)]
         [kn-leaks
          (filter (lambda (p) (string-suffix? (path->string p) ".rkt"))
                  kn-files)])
    (unless (null? kn-leaks)
      (eprintf "releasegen: KAFKA-NATIVE LEAK GATE FAILED:\n")
      (for ([p (in-list kn-leaks)]) (eprintf "  ~a\n" p))
      (exit 1))
    (printf "releasegen: kafka-native export: ~a files, leak gate OK\n"
            (length kn-files))))

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
  (for ([f (in-list '("LICENSE" "GENERATED-CODE-LICENSE.md" "EVENTBUS.md" "CONTRIBUTING.md" "SECURITY.md"))])
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
   "zig" (list "Zig"
               "cd zig && zig build tests"
               (string-append "Zig package manager: `zig fetch --save git+https://github.com/browser-grpc/grpc-over-datachannels.git#" version "` — the repository root is a Zig package (build.zig.zon) exposing modules `grpcdc` (the runtime) and `kafka_grpc` (the grpcdc.kafka.v1 stubs). Depend on it with `b.dependency(\"grpc_dc\", .{})` and `dep.module(\"grpcdc\")` / `dep.module(\"kafka_grpc\")`. Or copy this directory; there are no dependencies."))
   "swift" (list "Swift"
                 "cd swift && mkdir -p build && swiftc -swift-version 5 -O -L ../rust/target/release -lgrpc_dc -Xlinker -rpath -Xlinker $PWD/../rust/target/release grpcdc/*.swift examples/Pb.swift examples/EchoMessages.swift examples/EchoRequestStruct.swift examples/EchoResponseStruct.swift examples/StructDcBridge.swift examples/EchoGrpcDc.swift examples/EchoServiceImpl.swift examples/StdioTransport.swift examples/DynamicEchoService.swift examples/interop/*.swift $(ls tests/*.swift | grep -v TestKafkaNative.swift) -o build/tests && ./build/tests TestEcho"
                 "SwiftPM: this repository is a Swift package (Package.swift at the root, listed on the Swift Package Index). Add it as a package dependency on https://github.com/browser-grpc/grpc-over-datachannels (use the newest release tag) and depend on the `GrpcDc` library product (module `Grpcdc`). Or compile the sources in `swift/grpcdc/` directly into your target — no dependencies either way. The `grpcdc.kafka.v1` stubs (KafkaMessages/KafkaGrpcDc) are part of the same module.")
   "csharp" (list "C#"
                  "cd csharp && dotnet run --project tests -- TestEcho"
                  "`dotnet add package GrpcDc` (net8.0: zero dependencies; netstandard2.0 pulls three first-party BCL compat packages for async/JSON). The raw-TCP HTTP/2 transport is net8-only; the DataChannel core and generated stubs run everywhere.\n\n### Unity (and .NET Framework 4.7.2+, Mono, Xamarin)\n\nThe netstandard2.0 build is the Unity target. Add `GrpcDc` with NuGetForUnity (or drop the `lib/netstandard2.0` DLLs plus `Microsoft.Bcl.AsyncInterfaces`, `System.Threading.Channels`, and `System.Text.Json` into `Assets/Plugins`). Implement `Grpcdc.ITransport` over your `RTCDataChannel` — `Send(byte[])` per message, `Recv()` blocking until the next message (throw `EndOfStreamException` on close), and `Close()` (explicit on netstandard; it has a default only on net8) — then serve or dial exactly like the Echo example in `examples/`. A maintained consumer doing this against the packed nupkg lives in the source repo under `csharp/tests-netstandard` and runs in CI under Mono.")
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
         (if (equal? dir "csharp")
             "Start here if you are new to the project. The runtime in\nthis directory is generated and speaks the gRPC wire\nprotocol over WebRTC DataChannels (net8.0 dependency-free;\nnetstandard2.0 adds BCL compat packages).\n\n"
             "Start here if you are new to the project. The runtime in\nthis directory is generated, dependency-free, and speaks\nthe gRPC wire protocol over WebRTC DataChannels.\n\n")
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
         "- Tests: `tests/` — the same BDD scenarios every language runs.\n"
         "- Test and example index: [`TESTS.md`](TESTS.md) — every suite and example here, plus shared matrix coverage.\n\n"
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
         "Test and example index: [`TESTS.md`](TESTS.md).\n\n"
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
  (for ([f (in-list '("LICENSE" "GENERATED-CODE-LICENSE.md" "CONTRIBUTING.md" "SECURITY.md"))])
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
;; JSR (Deno): jsr.json next to the npm manifest in js/ (and in
;; packages/kafka-js below). Publishing is the publish-jsr
;; workflow (jsr publish, GitHub OIDC after the one-time
;; scope<->repo link on jsr.io). JSR accepts the plain-JS
;; sources; --allow-slow-types covers the untyped exports.
(call-with-output-file (build-path out-dir "js/jsr.json")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "{\n"
      "  \"name\": \"@browser-grpc/grpc-dc\",\n"
      "  \"version\": \"" npm-version "\",\n"
      "  \"license\": \"Apache-2.0\",\n"
      "  \"exports\": \"./index.js\"\n"
      "}\n")
     out)))
;; ---------------------------------------------------------------------------
;; Dedicated Packagist repo exports: Packagist reads one
;; composer.json per repository, so PHP gets two small repos of
;; its own (browser-grpc/grpc-dc-php = composer browser-grpc/
;; grpc-dc, browser-grpc/kafka-grpc-php = composer
;; browser-grpc/kafka-grpc), lib-layout copies of the generated
;; PHP runtime / kafka stubs. Packagist submission is one-time
;; per repo; new tags are picked up automatically afterwards.
;; ---------------------------------------------------------------------------

(define (emit-php-file root rel text)
  (define dest (build-path root rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest #:exists 'replace
    (lambda (out) (display text out))))
(define (copy-php-file root src-rel dest-rel [rewrite #f])
  (define src (build-path out-dir src-rel))
  (when (file-exists? src)
    (define text (file->string src))
    (emit-php-file root dest-rel (if rewrite (rewrite text) text))))

(when (non-empty-string? php-out)
  (when (directory-exists? php-out) (delete-directory/files php-out))
  (make-directory* php-out)
  (copy-php-file php-out "php/grpcdc.php" "lib/grpcdc.php")
  (for ([f (in-list (directory-list (build-path out-dir "php/grpcdc")))]
        #:when (and (path-has-extension? f #".php")
                    (not (string-prefix? (path->string f) "kafka_"))))
    (copy-php-file php-out (build-path "php/grpcdc" f)
                   (build-path "lib/grpcdc" f)))
  (copy-php-file php-out "LICENSE" "LICENSE")
  (copy-php-file php-out "CONTRIBUTING.md" "CONTRIBUTING.md")
  (copy-php-file php-out "SECURITY.md" "SECURITY.md")
  (emit-php-file php-out "composer.json"
    (string-append
     "{\n"
     "  \"name\": \"browser-grpc/grpc-dc\",\n"
     "  \"description\": \"gRPC over WebRTC DataChannels for PHP: dependency-free generated runtime, client and server, all four call shapes.\",\n"
     "  \"type\": \"library\",\n"
     "  \"license\": \"Apache-2.0\",\n"
     "  \"homepage\": \"https://github.com/browser-grpc/grpc-over-datachannels\",\n"
     "  \"autoload\": {\n"
     "    \"files\": [\"lib/grpcdc.php\"],\n"
     "    \"classmap\": [\"lib/grpcdc\"]\n"
     "  },\n"
     "  \"require\": { \"php\": \">=8.1\" }\n"
     "}\n"))
  (emit-php-file php-out "README.md"
    (string-append
     "# grpc-dc (PHP)\n\n"
     "gRPC over WebRTC DataChannels — a generated, dependency-free\n"
     "PHP runtime (PHP 8.1+, stdlib only): clients and servers\n"
     "speaking the gRPC wire protocol over a WebRTC DataChannel.\n\n"
     "Install: `composer require browser-grpc/grpc-dc`. Kafka\n"
     "stubs ship separately in the `browser-grpc/kafka-grpc`\n"
     "package, which depends on this one.\n"))
  (printf "releasegen: php export: ~a files, leak gate OK\n"
          (length (find-files file-exists? php-out))))

(when (non-empty-string? kafka-php-out)
  (when (directory-exists? kafka-php-out)
    (delete-directory/files kafka-php-out))
  (make-directory* kafka-php-out)
  (copy-php-file kafka-php-out "php/grpcdc/kafka_pb.php" "lib/kafka_pb.php")
  ;; The stub's test-tree require of the runtime entry point is
  ;; satisfied by the grpc-dc package's composer autoload instead.
  (copy-php-file kafka-php-out "php/grpcdc/kafka_grpc_dc.php" "lib/kafka_grpc_dc.php"
                 (lambda (text)
                   (string-replace text
                                   "require_once __DIR__ . \"/../grpcdc.php\";\n"
                                   "")))
  (copy-php-file kafka-php-out "LICENSE" "LICENSE")
  (copy-php-file kafka-php-out "CONTRIBUTING.md" "CONTRIBUTING.md")
  (copy-php-file kafka-php-out "SECURITY.md" "SECURITY.md")
  (emit-php-file kafka-php-out "composer.json"
    (string-append
     "{\n"
     "  \"name\": \"browser-grpc/kafka-grpc\",\n"
     "  \"description\": \"Kafka over gRPC for PHP: generated grpcdc.kafka.v1 clients (produce/consume/groups/topics) over the grpc-dc runtime.\",\n"
     "  \"type\": \"library\",\n"
     "  \"license\": \"Apache-2.0\",\n"
     "  \"homepage\": \"https://github.com/browser-grpc/grpc-over-datachannels\",\n"
     "  \"autoload\": {\n"
     "    \"classmap\": [\"lib\"],\n"
     "    \"files\": [\"lib/kafka_grpc_dc.php\"]\n"
     "  },\n"
     "  \"require\": {\n"
     "    \"php\": \">=8.1\",\n"
     "    \"browser-grpc/grpc-dc\": \"^" npm-version "\"\n"
     "  }\n"
     "}\n"))
  (emit-php-file kafka-php-out "README.md"
    (string-append
     "# kafka-grpc (PHP)\n\n"
     "Generated `grpcdc.kafka.v1` clients for PHP (produce/consume/\n"
     "groups/topics) over the `grpc-dc` runtime. Install:\n"
     "`composer require browser-grpc/kafka-grpc`.\n"))
  (printf "releasegen: kafka-php export: ~a files, leak gate OK\n"
          (length (find-files file-exists? kafka-php-out))))
(when (non-empty-string? eventbus-php-out)
  (when (directory-exists? eventbus-php-out)
    (delete-directory/files eventbus-php-out))
  (make-directory* eventbus-php-out)
  (copy-php-file eventbus-php-out "php/grpcdc/events_pb.php" "lib/events_pb.php")
  (copy-php-file eventbus-php-out "php/grpcdc/events_grpc_dc.php" "lib/events_grpc_dc.php"
                 (lambda (text)
                   (string-replace text
                                   "require_once __DIR__ . \"/../grpcdc.php\";\n"
                                   "")))
  (copy-php-file eventbus-php-out "LICENSE" "LICENSE")
  (copy-php-file eventbus-php-out "CONTRIBUTING.md" "CONTRIBUTING.md")
  (copy-php-file eventbus-php-out "SECURITY.md" "SECURITY.md")
  (emit-php-file eventbus-php-out "composer.json"
    (string-append
     "{\n"
     "  \"name\": \"browser-grpc/eventbus-grpc\",\n"
     "  \"description\": \"Event bus over gRPC for PHP: generated grpcdc.events.v1 publish/subscribe clients over the grpc-dc runtime.\",\n"
     "  \"type\": \"library\",\n"
     "  \"license\": \"Apache-2.0\",\n"
     "  \"homepage\": \"https://github.com/browser-grpc/grpc-over-datachannels\",\n"
     "  \"autoload\": {\n"
     "    \"classmap\": [\"lib\"],\n"
     "    \"files\": [\"lib/events_grpc_dc.php\"]\n"
     "  },\n"
     "  \"require\": {\n"
     "    \"php\": \">=8.1\",\n"
     "    \"browser-grpc/grpc-dc\": \"^" npm-version "\"\n"
     "  }\n"
     "}\n"))
  (emit-php-file eventbus-php-out "README.md"
    (string-append
     "# eventbus-grpc (PHP)\n\n"
     "Generated `grpcdc.events.v1` clients for PHP (publish/\n"
     "subscribe) over the `grpc-dc` runtime. Install:\n"
     "`composer require browser-grpc/eventbus-grpc`.\n"))
  (printf "releasegen: eventbus-php export: ~a files\n"
          (length (find-files file-exists? eventbus-php-out))))



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
;; RubyGems (canonical): packages/grpc-ruby, a lib-layout gem
;; tree like the other canonical packages (the export's ruby/
;; tree stays the test tree; the GitHub Packages mirror builds
;; this same gemspec). Kafka stubs are excluded here — they
;; ship in the kafka-grpc gem, same split as everywhere else.
(define (emit-ruby-pub dest-rel text)
  (define dest (build-path out-dir "packages" dest-rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest #:exists 'replace
    (lambda (out) (display text out))))
(define (copy-ruby-pub src-rel dest-rel)
  (define src (build-path out-dir src-rel))
  (when (file-exists? src)
    (define dest (build-path out-dir "packages" dest-rel))
    (make-directory* (path-only dest))
    (copy-file src dest #t)))
(copy-ruby-pub "ruby/grpcdc.rb" "grpc-ruby/lib/grpcdc.rb")
(for ([f (in-list (directory-list (build-path out-dir "ruby/grpcdc")))]
      #:when (and (path-has-extension? f #".rb")
                  (not (string-prefix? (path->string f) "kafka_"))))
  (copy-ruby-pub (build-path "ruby/grpcdc" f)
                 (build-path "grpc-ruby/lib/grpcdc" f)))
(emit-ruby-pub "grpc-ruby/lib/grpc_dc.rb"
  "require_relative \"grpcdc\"\n")
(emit-ruby-pub "grpc-ruby/grpc-dc.gemspec"
  (string-append
   "Gem::Specification.new do |spec|\n"
   "  spec.name = \"grpc-dc\"\n  spec.version = \"" npm-version "\"\n"
   "  spec.authors = [\"John Davis\"]\n  spec.email = [\"jdavis@pcprogramming.com\"]\n"
   "  spec.summary = \"gRPC over WebRTC DataChannels, dependency-free generated Ruby runtime\"\n"
   "  spec.description = \"Generated, stdlib-only gRPC clients and servers for Ruby speaking the gRPC wire protocol over a WebRTC DataChannel. No grpc library underneath. Kafka stubs ship separately in the kafka-grpc gem.\"\n"
   "  spec.homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "  spec.license = \"Apache-2.0\"\n  spec.required_ruby_version = \">= 3.0\"\n"
   "  spec.metadata = { \"homepage_uri\" => spec.homepage, \"source_code_uri\" => \"https://github.com/browser-grpc/grpc-over-datachannels/tree/main/packages/grpc-ruby\", \"changelog_uri\" => \"https://github.com/browser-grpc/grpc-over-datachannels/blob/main/CHANGELOG.md\" }\n"
   "  spec.files = Dir[\"lib/**/*.rb\", \"README.md\", \"LICENSE\"]\n  spec.require_paths = [\"lib\"]\n"
   "end\n"))
(emit-ruby-pub "grpc-ruby/README.md"
  (string-append
   "# grpc-dc (Ruby)\n\n"
   "gRPC over WebRTC DataChannels — a generated, stdlib-only\n"
   "Ruby runtime: clients and servers speaking the gRPC wire\n"
   "protocol over a WebRTC DataChannel. No `grpc` gem (or any\n"
   "other gem) underneath.\n\n"
   "Install: `gem install grpc-dc`, then `require \"grpcdc\"`\n"
   "(or `require \"grpc_dc\"`). Kafka stubs ship separately in\n"
   "the `kafka-grpc` gem, which depends on this one.\n"))
(copy-ruby-pub "LICENSE" "grpc-ruby/LICENSE")

;; LuaRocks (canonical): packages/grpc-lua and packages/kafka-lua
;; hold rockspecs whose source is this repo at the release tag;
;; LuaRocks fetches the tag and installs the module files from
;; lua/grpcdc (resp. the kafka stubs in lua/examples, which are
;; in every tagged tree) per the builtin build table.
;; Publishing is
;; `luarocks upload` with an account API key (secret
;; LUAROCKS_API_KEY in the publish-luarocks workflow); there is
;; no OIDC path on LuaRocks.
(define (emit-lua-pub dest-rel text)
  (define dest (build-path out-dir "packages" dest-rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest #:exists 'replace
    (lambda (out) (display text out))))
(define lua-module-files
  '("channel" "codec" "dynamic" "endpoint" "eventbus" "eventbus_git"
    "memory_transport" "server" "sidecar_transport" "status"
    "transport" "wire"))
(define (rockspec name summary modules deps)
  (string-append
   "package = \"" name "\"\n"
   "version = \"" npm-version "-1\"\n"
   "source = {\n"
   "  url = \"git+https://github.com/browser-grpc/grpc-over-datachannels\",\n"
   "  tag = \"v" npm-version "\",\n"
   "}\n"
   "description = {\n"
   "  summary = \"" summary "\",\n"
   "  homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\",\n"
   "  license = \"Apache-2.0\",\n"
   "}\n"
   "dependencies = {\n"
   (apply string-append
          (for/list ([d (in-list deps)])
            (string-append "  \"" d "\",\n")))
   "}\n"
   "build = {\n"
   "  type = \"builtin\",\n"
   "  modules = {\n"
   (apply string-append
          (for/list ([m (in-list modules)])
            (string-append "    [\"" (car m) "\"] = \"" (cdr m) "\",\n")))
   "  },\n"
   "}\n"))
(emit-lua-pub (string-append "grpc-lua/grpc-dc-" npm-version "-1.rockspec")
  (rockspec
   "grpc-dc"
   "gRPC over WebRTC DataChannels for Lua: dependency-free generated runtime"
   (for/list ([m (in-list lua-module-files)])
     (cons (string-append "grpcdc." m)
           (string-append "lua/grpcdc/" m ".lua")))
   '("lua >= 5.4")))
(emit-lua-pub "grpc-lua/README.md"
  (string-append
   "# grpc-dc (Lua)\n\n"
   "gRPC over WebRTC DataChannels — a generated, dependency-free\n"
   "Lua runtime (Lua 5.4, stdlib only): clients and servers\n"
   "speaking the gRPC wire protocol over a WebRTC DataChannel.\n\n"
   "Install: `luarocks install grpc-dc`, then\n"
   "`require(\"grpcdc.channel\")` etc. Kafka stubs ship separately\n"
   "in the `kafka-grpc` rock, which depends on this one.\n"))
(emit-lua-pub (string-append "kafka-lua/kafka-grpc-" npm-version "-1.rockspec")
  (rockspec
   "kafka-grpc"
   "Kafka over gRPC for Lua: generated grpcdc.kafka.v1 clients (produce/consume/groups/topics)"
   ;; The stubs live in lua/examples in every tagged tree, and
   ;; kafka_grpc_dc requires them as examples.kafka_messages;
   ;; register both module names for the same file.
   '(("kafka_messages" . "lua/examples/kafka_messages.lua")
     ("examples.kafka_messages" . "lua/examples/kafka_messages.lua")
     ("kafka_grpc_dc" . "lua/examples/kafka_grpc_dc.lua"))
   (list "lua >= 5.4" (string-append "grpc-dc >= " npm-version))))
(emit-lua-pub "kafka-lua/README.md"
  (string-append
   "# kafka-grpc (Lua)\n\n"
   "Generated `grpcdc.kafka.v1` clients for Lua (produce/consume/\n"
   "groups/topics) over the `grpc-dc` runtime. Install:\n"
   "`luarocks install kafka-grpc`, then\n"
   "`require(\"kafka_grpc_dc\")`.\n"))
(emit-lua-pub (string-append "eventbus-lua/eventbus-grpc-" npm-version "-1.rockspec")
  (rockspec
   "eventbus-grpc"
   "Event bus over gRPC for Lua: generated grpcdc.events.v1 publish/subscribe clients"
   ;; Packaged copies (below): two module names mapped to one
   ;; source file install only one of them, so the messages
   ;; file ships under its own path and the stub's require is
   ;; rewritten to the plain module name.
   '(("events_messages" . "packages/eventbus-lua/events_messages.lua")
     ("events_grpc_dc" . "packages/eventbus-lua/events_grpc_dc.lua"))
   (list "lua >= 5.4" (string-append "grpc-dc >= " npm-version))))
(define (copy-eb-lua src-rel dest-rel rewrite?)
  (define src (build-path out-dir src-rel))
  (when (file-exists? src)
    (define text (file->string src))
    (emit-lua-pub dest-rel
                  (if rewrite?
                      (string-replace text "examples.events_messages" "events_messages")
                      text))))
(copy-eb-lua "lua/examples/events_messages.lua" "eventbus-lua/events_messages.lua" #f)
(copy-eb-lua "lua/examples/events_grpc_dc.lua" "eventbus-lua/events_grpc_dc.lua" #t)
(emit-lua-pub "eventbus-lua/README.md"
  (string-append
   "# eventbus-grpc (Lua)\n\n"
   "Generated `grpcdc.events.v1` clients for Lua (publish/\n"
   "subscribe) over the `grpc-dc` runtime. Install:\n"
   "`luarocks install eventbus-grpc`, then\n"
   "`require(\"events_grpc_dc\")`.\n"))
(call-with-output-file (build-path out-dir "GITHUB-PACKAGES.md")
  #:exists 'replace
  (lambda (out)
    (display
     (string-append
      "# GitHub Packages mirrors\\n\\n"
      "The canonical packages live on the language registries\\n"
      "(npm, PyPI, Maven Central + the Pages Maven repo, NuGet,\\n"
      "crates.io, pub.dev, and git tags for Go). As a mirror, the\\n"
      "registries GitHub Packages can host are also published\\n"
      "to GitHub under the `browser-grpc` org at each release:\\n\\n"
      "| Ecosystem | GitHub Packages artifacts |\\n"
      "|---|---|\\n"
      "| npm | `@browser-grpc/grpc-dc`, `@browser-grpc/kafka-grpc`, `@browser-grpc/eventbus-grpc` |\\n"
      "| NuGet | `GrpcDc`, `KafkaGrpc`, `EventBusGrpc` |\\n"
      "| RubyGems | `grpc-dc`, `kafka-grpc`, `eventbus-grpc` |\\n\\n"
      "Each ecosystem also gets separate `kafka-grpc` and\\n"
      "`eventbus-grpc` packages (npm `@browser-grpc/kafka-grpc`\\n"
      "and `@browser-grpc/eventbus-grpc`, NuGet `KafkaGrpc` and\\n"
      "`EventBusGrpc`, gems `kafka-grpc` and `eventbus-grpc`)\\n"
      "holding the generated Kafka and event-bus stubs; see\\n"
      "packages/README.md in the export. NuGet and RubyGems\\n"
      "mirrors are pushed from the packed artifacts by\\n"
      "scripts/release-push.sh and need `dotnet`/`gem` on the\\n"
      "publishing host (the CI image has both).\\n\\n"
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
;; Go nested modules must sit at the directory matching their
;; module path (repo-root kafka/ and eventbus/), or the module
;; proxy cannot resolve them; release-push tags kafka/<version>
;; and eventbus/<version> like go/<version>.
(define (emit-go-file dest-rel text)
  (define dest (build-path out-dir dest-rel))
  (make-directory* (path-only dest))
  (call-with-output-file dest #:exists 'replace
    (lambda (out) (display text out))))
(define (copy-go-file src-rel dest-rel)
  (define src (build-path out-dir src-rel))
  (when (file-exists? src)
    (define dest (build-path out-dir dest-rel))
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
(emit-kafka-file "kafka-js/jsr.json"
  (string-append
   "{\n  \"name\": \"@browser-grpc/kafka-grpc\",\n"
   "  \"version\": \"" npm-version "\",\n"
   "  \"license\": \"Apache-2.0\",\n"
   "  \"exports\": \"./index.js\"\n}\n"))
;; --- PyPI ---
(copy-kafka-file "python/grpcdc/kafka_pb.py" "kafka-python/grpcdc/kafka_pb.py")
(copy-kafka-file "python/grpcdc/kafka_grpc_dc.py" "kafka-python/grpcdc/kafka_grpc_dc.py")
;; No grpcdc/__init__.py in the stub wheels: it would clobber
;; the grpc-dc wheel's package init when both are installed
;; into the same grpcdc/ directory.
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
   "  spec.authors = [\"John Davis\"]\n  spec.email = [\"jdavis@pcprogramming.com\"]\n"
   "  spec.summary = \"Kafka over gRPC — generated grpcdc.kafka.v1 Ruby clients\"\n"
   "  spec.description = \"" kafka-desc " (Ruby).\"\n"
   "  spec.homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "  spec.license = \"Apache-2.0\"\n  spec.required_ruby_version = \">= 3.0\"\n"
   "  spec.metadata = { \"homepage_uri\" => spec.homepage, \"source_code_uri\" => \"https://github.com/browser-grpc/grpc-over-datachannels/tree/main/packages/kafka-ruby\" }\n"
   "  spec.files = Dir[\"lib/**/*.rb\", \"README.md\", \"LICENSE\"]\n  spec.require_paths = [\"lib\"]\n"
   "  spec.add_runtime_dependency \"grpc-dc\", \"= " npm-version "\"\nend\n"))
(emit-kafka-file "kafka-ruby/README.md"
  (string-append "# kafka-grpc (Ruby)\n\n" kafka-desc " (Ruby).\n\n"
                 "Install: `gem install kafka-grpc` (depends on `grpc-dc`).\n"))
(copy-kafka-file "LICENSE" "kafka-ruby/LICENSE")
;; --- NuGet (own project, ProjectReference on Grpcdc for pack) ---
;; All kafka stub sources (support + client + every message
;; type), not just the two framework files: the package must
;; compile against a GrpcDc that carries no kafka types.
(for ([f (in-list (directory-list (build-path out-dir "csharp/grpcdc/kafka/v1")))]
      #:when (path-has-extension? f #".cs"))
  (copy-kafka-file (build-path "csharp/grpcdc/kafka/v1" f)
                   (build-path "kafka-csharp" f)))
(emit-kafka-file "kafka-csharp/KafkaGrpc.csproj"
  (string-append
   "<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n"
   "    <TargetFrameworks>netstandard2.0;net8.0</TargetFrameworks>\n    <LangVersion>latest</LangVersion>\n"
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
   "  <developers><developer><id>unicomp21</id><name>John Davis</name><email>jdavis@pcprogramming.com</email></developer></developers>\n"
   "  <scm><connection>scm:git:https://github.com/browser-grpc/grpc-over-datachannels.git</connection><developerConnection>scm:git:https://github.com/browser-grpc/grpc-over-datachannels.git</developerConnection><url>https://github.com/browser-grpc/grpc-over-datachannels</url></scm>\n"
   "  <properties><maven.compiler.release>17</maven.compiler.release><project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties>\n"
   "  <dependencies><dependency><groupId>io.github.browser-grpc</groupId><artifactId>grpc-dc</artifactId><version>" npm-version "</version></dependency></dependencies>\n"
   "  <build><sourceDirectory>${project.basedir}</sourceDirectory><plugins>\n"
   "    <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.13.0</version></plugin>\n"
   "    <plugin><artifactId>maven-source-plugin</artifactId><version>3.3.1</version><configuration><excludes><exclude>target/**</exclude></excludes></configuration><executions><execution><id>attach-sources</id><goals><goal>jar-no-fork</goal></goals></execution></executions></plugin>\n"
   "    <plugin><artifactId>maven-javadoc-plugin</artifactId><version>3.10.0</version><configuration><additionalOptions><additionalOption>-Xdoclint:none</additionalOption></additionalOptions><quiet>true</quiet></configuration><executions><execution><id>attach-javadocs</id><goals><goal>jar</goal></goals></execution></executions></plugin>\n"
   "    <plugin><groupId>org.sonatype.central</groupId><artifactId>central-publishing-maven-plugin</artifactId><version>0.8.0</version><extensions>true</extensions><configuration><publishingServerId>central</publishingServerId><autoPublish>true</autoPublish><waitUntil>published</waitUntil></configuration></plugin>\n"
   "  </plugins></build>\n"
   "  <profiles><profile><id>release</id><build><plugins><plugin><artifactId>maven-gpg-plugin</artifactId><version>3.2.7</version><executions><execution><id>sign-artifacts</id><phase>verify</phase><goals><goal>sign</goal></goals></execution></executions><configuration><gpgArguments><arg>--pinentry-mode</arg><arg>loopback</arg></gpgArguments></configuration></plugin></plugins></build></profile></profiles>\n"
   "</project>\n"))
;; --- Cargo (crates.io) ---
;; Canonical grpc-dc crate in packages/grpc-rust: the export's
;; rust/src minus the webrtc modules, whose dc-webrtc path
;; dependency cannot ship on crates.io (the `webrtc` feature
;; stays available to in-repo path users). Version stamped
;; like every other registry manifest.
(define (copy-rust-pub src-rel dest-rel)
  (define src (build-path out-dir src-rel))
  (when (file-exists? src)
    (define dest (build-path kafka-root dest-rel))
    (make-directory* (path-only dest))
    (copy-file src dest #t)))
(for ([f (in-list '("channel" "codec" "dynamic" "endpoint" "eventbus"
                    "eventbus_git" "http2" "lib" "link_stats" "message" "server"
                    "status" "transport" "wire_gen"))])
  (copy-rust-pub (string-append "rust/src/" f ".rs")
                 (string-append "grpc-rust/src/" f ".rs")))
;; src/eventbus.rs includes its messages via ../gen/events_pb.rs.
(copy-rust-pub "rust/gen/events_pb.rs" "grpc-rust/gen/events_pb.rs")
(emit-kafka-file "grpc-rust/Cargo.toml"
  (string-append
   "[package]\nname = \"grpc-dc\"\nversion = \"" npm-version "\"\nedition = \"2021\"\n"
   "license = \"Apache-2.0\"\n"
   "description = \"gRPC over WebRTC DataChannels: dependency-free generated Rust runtime, client and server, all four call shapes, over a single RTCDataChannel.\"\n"
   "homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "repository = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "readme = \"README.md\"\nkeywords = [\"grpc\", \"webrtc\", \"datachannel\", \"rpc\"]\n"
   "categories = [\"network-programming\", \"asynchronous\"]\n\n"
   "[lib]\nname = \"grpc_dc\"\npath = \"src/lib.rs\"\n\n"
   "[features]\ndefault = []\nprost = [\"dep:prost\"]\n"
   "kafka-tls = [\"dep:tokio-rustls\", \"dep:rustls\", \"dep:rustls-pemfile\"]\n\n"
   "[dependencies]\n"
   "async-trait = \"0.1\"\nbytes = \"1\"\nfutures-channel = \"0.3\"\n"
   "futures-core = \"0.3\"\n"
   "futures-util = { version = \"0.3\", default-features = false, features = [\"std\"] }\n"
   "prost = { version = \"0.14\", optional = true }\n"
   "serde = { version = \"1\", features = [\"derive\"] }\nserde_json = \"1\"\n\n"
   "[target.'cfg(not(target_arch = \"wasm32\"))'.dependencies]\n"
   "tokio = { version = \"1\", features = [\"rt\", \"rt-multi-thread\", \"macros\", \"sync\", \"time\", \"io-util\", \"io-std\", \"net\"] }\n"
   "tokio-rustls = { version = \"0.26\", optional = true, default-features = false, features = [\"ring\", \"tls12\"] }\n"
   "rustls = { version = \"0.23\", optional = true, default-features = false, features = [\"ring\", \"std\", \"tls12\"] }\n"
   "rustls-pemfile = { version = \"2\", optional = true }\n\n"
   "[target.'cfg(target_arch = \"wasm32\")'.dependencies]\n"
   "tokio = { version = \"1\", features = [\"sync\", \"rt\"] }\n"
   "wasm-bindgen = \"0.2\"\nwasm-bindgen-futures = \"0.4\"\njs-sys = \"0.3\"\n"))
(emit-kafka-file "grpc-rust/README.md"
  (string-append
   "# grpc-dc (Rust)\n\n"
   "gRPC over WebRTC DataChannels — a dependency-free generated\n"
   "Rust runtime: client and server, all four call shapes\n"
   "(unary, server/client streaming, bidi), deadlines, metadata,\n"
   "and status over a single `RTCDataChannel`. Stub code is\n"
   "generated from your `.proto` by the grpc-dc protoc plugins;\n"
   "this crate is the runtime those stubs call.\n\n"
   "```toml\n[dependencies]\ngrpc-dc = \"" npm-version "\"\n```\n\n"
   "Features: `prost` (prost messages implement the runtime's\n"
   "`Message` trait automatically) and `kafka-tls` (TLS to a\n"
   "Kafka broker for the proxy examples). The in-repo crate's\n"
   "`webrtc` feature (the reimplemented WebRTC stack) is not in\n"
   "the crates.io build because it is a path dependency; use\n"
   "the repository checkout by path if you need it. Kafka\n"
   "stubs ship separately in the `kafka-grpc` crate, which\n"
   "depends on this one.\n"))
(copy-rust-pub "LICENSE" "grpc-rust/LICENSE")
;; kafka-grpc: depends on the crates.io grpc-dc (path kept for
;; pre-publish resolution from this tree; cargo strips it on
;; publish). The stubs address message types as crate::pb::*, so
;; the lib re-exports kafka_pb under that name — without it the
;; crate never compiled standalone.
(copy-kafka-file "rust/gen/kafka_pb.rs" "kafka-rust/src/kafka_pb.rs")
(copy-kafka-file "rust/gen/kafka_grpc_dc.rs" "kafka-rust/src/kafka_grpc_dc.rs")
;; grpc_dc::Message adapters for the kafka messages: the same
;; macro bridge the kafka proxy example uses, shipped in-crate
;; (without it the stubs' Channel calls have no Message impls).
(copy-kafka-file "crates/kafka-native/src/pb_message_impl.rs"
                 "kafka-rust/src/pb_message_impl.rs")
(emit-kafka-file "kafka-rust/src/lib.rs"
  "pub mod kafka_pb;\npub mod kafka_grpc_dc;\n\npub use kafka_pb as pb;\n\nmod pb_message_impl;\n")
(emit-kafka-file "kafka-rust/Cargo.toml"
  (string-append
   "[package]\nname = \"kafka-grpc\"\nversion = \"" npm-version "\"\nedition = \"2021\"\n"
   "license = \"Apache-2.0\"\ndescription = \"" kafka-desc " (Rust).\"\n"
   "homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "repository = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "readme = \"README.md\"\n\n"
   "[dependencies]\ngrpc-dc = { version = \"" npm-version "\", path = \"../../grpc-rust\" }\n"))
(emit-kafka-file "kafka-rust/README.md"
  (string-append "# kafka-grpc (Rust)\n\n" kafka-desc " (Rust).\n\n"
                 "```toml\n[dependencies]\nkafka-grpc = \"" npm-version "\"\n```\n\n"
                 "(depends on the `grpc-dc` crate).\n"))
(copy-rust-pub "LICENSE" "kafka-rust/LICENSE")
;; --- pub.dev (Dart/Flutter) ---
;; Canonical grpc_dc lives in packages/grpc-dart (its own tree,
;; like kafka-<lang>): lib/grpcdc/*.dart copies keep the
;; generated files' relative imports intact, and the barrel
;; lib/grpc_dc.dart re-exports the non-IO core. The dart:io
;; transports (http2/sidecar/eventbus_git) ship in the tree but
;; stay out of the barrel so the main library stays
;; Flutter/web-clean; VM users import them by path. Kafka stubs
;; are excluded here (kafka_grpc below) — same split as NuGet,
;; where sharing the types caused CS0433.
(define (copy-dart-pub src-rel dest-rel)
  (define src (build-path out-dir src-rel))
  (when (file-exists? src)
    (define dest (build-path kafka-root dest-rel))
    (make-directory* (path-only dest))
    (copy-file src dest #t)))
(define dart-runtime-files
  '("channel" "codec" "dynamic" "endpoint" "eventbus" "eventbus_git"
    "events_grpc_dc" "events_messages" "http2_transport"
    "memory_transport" "server" "sidecar_transport" "status"
    "transport" "web_transport" "wire"))
(for ([f (in-list dart-runtime-files)])
  (copy-dart-pub (string-append "dart/grpcdc/" f ".dart")
                 (string-append "grpc-dart/lib/grpcdc/" f ".dart")))
(emit-kafka-file "grpc-dart/lib/grpc_dc.dart"
  (string-append
   "// grpc_dc: gRPC over WebRTC DataChannels — Dart runtime.\n"
   "// Generated by the grpc-dc release generator. The runtime is\n"
   "// dependency-free (Dart SDK libraries only). The dart:io\n"
   "// transports are not re-exported here; on the VM import\n"
   "// package:grpc_dc/grpcdc/http2_transport.dart (or\n"
   "// sidecar_transport.dart / eventbus_git.dart) directly.\n"
   (apply string-append
          (for/list ([f (in-list '("channel" "codec" "dynamic" "endpoint"
                                   "eventbus" "events_grpc_dc"
                                   "events_messages" "memory_transport"
                                   "server" "status" "transport" "wire"))])
            (string-append "export 'grpcdc/" f ".dart';\n")))))
(emit-kafka-file "grpc-dart/pubspec.yaml"
  (string-append
   "name: grpc_dc\n"
   "version: " npm-version "\n"
   "description: \"gRPC over WebRTC DataChannels for Dart and Flutter: dependency-free generated runtime, client and server, all four call shapes, no grpc package underneath.\"\n"
   "homepage: https://github.com/browser-grpc/grpc-over-datachannels\n"
   "repository: https://github.com/browser-grpc/grpc-over-datachannels\n"
   "issue_tracker: https://github.com/browser-grpc/grpc-over-datachannels/issues\n"
   "environment:\n  sdk: \">=3.3.0 <4.0.0\"\n"
   "dependencies:\n"))
(emit-kafka-file "grpc-dart/README.md"
  (string-append
   "# grpc_dc (Dart / Flutter)\n\n"
   "gRPC over WebRTC DataChannels — a dependency-free generated\n"
   "Dart runtime: client and server, all four call shapes\n"
   "(unary, server/client streaming, bidi), deadlines, metadata,\n"
   "and status over a single DataChannel. No `grpc` or WebRTC\n"
   "package underneath; stub code is generated from your `.proto`\n"
   "by the grpc-dc protoc plugins.\n\n"
   "Install: `dart pub add grpc_dc` (or `flutter pub add grpc_dc`).\n\n"
   "```dart\n"
   "import 'package:grpc_dc/grpc_dc.dart';\n"
   "```\n\n"
   "See `example/example.dart` for a complete in-memory\n"
   "client/server call. Transports: the main library is\n"
   "platform-neutral (Flutter native + web, Dart VM). The\n"
   "`dart:io` transports (HTTP/2, sidecar, git event bus) live\n"
   "at `package:grpc_dc/grpcdc/http2_transport.dart` and\n"
   "friends, imported directly on the VM; on the web (Flutter\n"
   "web included) import\n"
   "`package:grpc_dc/grpcdc/web_transport.dart` and hand\n"
   "`WebTransport` your page's RTCDataChannel bridge\n"
   "(`{send(Uint8Array), setOnMessage(cb)}`). Kafka stubs\n"
   "ship separately\n"
   "in the `kafka_grpc` package, which depends on this one.\n"))
(emit-kafka-file "grpc-dart/CHANGELOG.md"
  (string-append "# Changelog\n\n## " npm-version "\n\n"
                 "- First pub.dev release: the dependency-free Dart\n"
                 "  runtime (client + server) from grpc-over-datachannels "
                 "v" npm-version ".\n"))
(emit-kafka-file "grpc-dart/example/example.dart"
  (string-append
   "// In-memory unary call: a Server and a Channel joined by the\n"
   "// loopback transport pair. Run: dart run example/example.dart\n"
   "import 'dart:convert';\n"
   "import 'dart:typed_data';\n\n"
   "import 'package:grpc_dc/grpc_dc.dart';\n\n"
   "/// One protobuf string field, hand-rolled for the example;\n"
   "/// real code uses protoc-generated messages (Marshaler /\n"
   "/// Unmarshaler), which plug in exactly the same way.\n"
   "class Text implements Marshaler, Unmarshaler {\n"
   "  String value;\n"
   "  Text([this.value = '']);\n"
   "  @override\n"
   "  Uint8List marshalDc() => utf8.encode(value);\n"
   "  @override\n"
   "  void unmarshalDc(List<int> bytes) => value = utf8.decode(bytes);\n"
   "}\n\n"
   "Future<void> main() async {\n"
   "  final (a, b) = memoryTransportPair();\n\n"
   "  final server = Server();\n"
   "  server.registerService(ServiceDesc('echo.Echo', [\n"
   "    Method('Unary', '/echo.Echo/Unary', Server.kindUnary,\n"
   "        (ctx, reqs, sink) async {\n"
   "      final req = Text();\n"
   "      await reqs.recvInto(req);\n"
   "      sink(Text('echo: ' + req.value).marshalDc());\n"
   "    }),\n"
   "  ]));\n"
   "  server.serveTransport(b);\n\n"
   "  final channel = Channel(a);\n"
   "  final resp = Text();\n"
   "  await channel.unary('/echo.Echo/Unary', Text('hello'), resp);\n"
   "  print(resp.value); // echo: hello\n"
   "}\n"))
(copy-dart-pub "LICENSE" "grpc-dart/LICENSE")
;; kafka_grpc: the two kafka stub files, with their runtime
;; imports rewritten from the in-tree ../grpcdc/ layout to the
;; published package:grpc_dc/grpcdc/ layout.
(define (copy-kafka-dart src-rel dest-rel)
  (define src (build-path out-dir src-rel))
  (when (file-exists? src)
    (emit-kafka-file dest-rel
      (string-replace (file->string src)
                      "../grpcdc/" "package:grpc_dc/grpcdc/"))))
(copy-kafka-dart "dart/grpcdc/kafka_messages.dart"
                 "kafka-dart/lib/grpcdc/kafka_messages.dart")
(copy-kafka-dart "dart/grpcdc/kafka_grpc_dc.dart"
                 "kafka-dart/lib/grpcdc/kafka_grpc_dc.dart")
(emit-kafka-file "kafka-dart/lib/kafka_grpc.dart"
  (string-append
   "// kafka_grpc: generated grpcdc.kafka.v1 stubs for Dart.\n"
   "// The runtime lives in package:grpc_dc.\n"
   "export 'grpcdc/kafka_messages.dart';\n"
   "export 'grpcdc/kafka_grpc_dc.dart';\n"))
(emit-kafka-file "kafka-dart/pubspec.yaml"
  (string-append
   "name: kafka_grpc\n"
   "version: " npm-version "\n"
   "description: \"Kafka over gRPC for Dart and Flutter: generated grpcdc.kafka.v1 clients (produce/consume/groups/topics) speaking gRPC over WebRTC DataChannels, via the grpc_dc runtime.\"\n"
   "homepage: https://github.com/browser-grpc/grpc-over-datachannels\n"
   "repository: https://github.com/browser-grpc/grpc-over-datachannels\n"
   "issue_tracker: https://github.com/browser-grpc/grpc-over-datachannels/issues\n"
   "environment:\n  sdk: \">=3.0.0 <4.0.0\"\n"
   "dependencies:\n  grpc_dc: ^" npm-version "\n"))
(emit-kafka-file "kafka-dart/README.md"
  (string-append "# kafka_grpc (Dart)\n\n" kafka-desc " (Dart).\n\n"
                 "Install: `dart pub add kafka_grpc` (depends on `grpc_dc`).\n"))
(emit-kafka-file "kafka-dart/CHANGELOG.md"
  (string-append "# Changelog\n\n## " npm-version "\n\n"
                 "- First pub.dev release: generated `grpcdc.kafka.v1`\n"
                 "  Dart stubs from grpc-over-datachannels v" npm-version ".\n"))
(copy-dart-pub "LICENSE" "kafka-dart/LICENSE")
;; --- Go (nested module at repo root, matching its path) ---
(copy-go-file "go/kafka/kafka_pb.go" "kafka/kafka_pb.go")
(copy-go-file "go/kafka/kafka_grpc_dc.go" "kafka/kafka_grpc_dc.go")
(emit-go-file "kafka/go.mod"
  (string-append
   "module github.com/browser-grpc/grpc-over-datachannels/kafka\n\ngo 1.21\n\n"
   "require github.com/browser-grpc/grpc-over-datachannels/go v" npm-version "\n"))
;; ---------------------------------------------------------------------------
;; Separate eventbus-grpc packages, mirroring kafka-grpc: the
;; generated grpcdc.events.v1 stubs ship as their own package in
;; every ecosystem (packages/eventbus-<lang>), depending on
;; grpc-dc. Additive split (user-approved): the same stubs also
;; remain inside the grpc-dc runtime trees, so nothing breaks
;; for existing imports; new code can depend on the small
;; package alone. The per-language broker stays in the runtime.
;; ---------------------------------------------------------------------------
(define (emit-eventbus-file dest-rel text) (emit-kafka-file dest-rel text))
(define (copy-eventbus-file src-rel dest-rel) (copy-kafka-file src-rel dest-rel))
(define eb-desc
  "Event bus over gRPC — generated grpcdc.events.v1 publish/subscribe clients over WebRTC DataChannels, via the grpc-dc runtime")
;; --- npm / JSR ---
(copy-eventbus-file "js/src/events_pb.js" "eventbus-js/events_pb.js")
(copy-eventbus-file "js/src/events_grpc_dc.js" "eventbus-js/events_grpc_dc.js")
(emit-eventbus-file "eventbus-js/index.js"
  "export * from \"./events_pb.js\";\nexport * from \"./events_grpc_dc.js\";\n")
(define (eb-npm-manifest name dep-name)
  (string-append
   "{\n  \"name\": \"" name "\",\n"
   "  \"version\": \"" npm-version "\",\n"
   "  \"description\": \"" eb-desc " (JavaScript, browser + Node)\",\n"
   "  \"type\": \"module\",\n  \"main\": \"index.js\",\n"
   "  \"files\": [\"index.js\", \"events_pb.js\", \"events_grpc_dc.js\"],\n"
   "  \"dependencies\": {\"" dep-name "\": \"^" npm-version "\"},\n"
   "  \"license\": \"Apache-2.0\",\n"
   "  \"repository\": {\"type\": \"git\", \"url\": \"git+https://github.com/browser-grpc/grpc-over-datachannels.git\"}\n}\n"))
(emit-eventbus-file "eventbus-js/package.json" (eb-npm-manifest "eventbus-grpc" "grpc-dc"))
(emit-eventbus-file "eventbus-js/package.github.json"
  (eb-npm-manifest "@browser-grpc/eventbus-grpc" "@browser-grpc/grpc-dc"))
(emit-eventbus-file "eventbus-js/jsr.json"
  (string-append
   "{\n  \"name\": \"@browser-grpc/eventbus-grpc\",\n"
   "  \"version\": \"" npm-version "\",\n"
   "  \"license\": \"Apache-2.0\",\n"
   "  \"exports\": \"./index.js\"\n}\n"))
;; --- PyPI ---
(copy-eventbus-file "python/grpcdc/events_pb.py" "eventbus-python/grpcdc/events_pb.py")
(copy-eventbus-file "python/grpcdc/events_grpc_dc.py" "eventbus-python/grpcdc/events_grpc_dc.py")
;; No grpcdc/__init__.py here either (see kafka-python).
(emit-eventbus-file "eventbus-python/README.md"
  (string-append "# eventbus-grpc (Python)\n\n" eb-desc ".\n\nInstall: `pip install eventbus-grpc` (depends on `grpc-dc`).\n"))
(emit-eventbus-file "eventbus-python/pyproject.toml"
  (string-append
   "[build-system]\nrequires = [\"setuptools>=61\"]\nbuild-backend = \"setuptools.build_meta\"\n\n"
   "[project]\nname = \"eventbus-grpc\"\nversion = \"" npm-version "\"\n"
   "description = \"" eb-desc " (Python)\"\nreadme = \"README.md\"\nrequires-python = \">=3.9\"\n"
   "license = {text = \"Apache-2.0\"}\ndependencies = [\"grpc-dc>=" npm-version "\"]\n\n"
   "[tool.setuptools.packages.find]\ninclude = [\"grpcdc*\"]\n"))
;; --- RubyGems ---
(copy-eventbus-file "ruby/grpcdc/events_pb.rb" "eventbus-ruby/lib/grpcdc/events_pb.rb")
(copy-eventbus-file "ruby/grpcdc/events_grpc_dc.rb" "eventbus-ruby/lib/grpcdc/events_grpc_dc.rb")
(emit-eventbus-file "eventbus-ruby/lib/eventbus_grpc.rb"
  "require_relative \"grpcdc/events_pb\"\nrequire_relative \"grpcdc/events_grpc_dc\"\n")
(emit-eventbus-file "eventbus-ruby/eventbus-grpc.gemspec"
  (string-append
   "Gem::Specification.new do |spec|\n"
   "  spec.name = \"eventbus-grpc\"\n  spec.version = \"" npm-version "\"\n"
   "  spec.authors = [\"John Davis\"]\n  spec.email = [\"jdavis@pcprogramming.com\"]\n"
   "  spec.summary = \"Event bus over gRPC — generated grpcdc.events.v1 Ruby clients\"\n"
   "  spec.description = \"" eb-desc " (Ruby).\"\n"
   "  spec.homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "  spec.license = \"Apache-2.0\"\n  spec.required_ruby_version = \">= 3.0\"\n"
   "  spec.metadata = { \"homepage_uri\" => spec.homepage, \"source_code_uri\" => \"https://github.com/browser-grpc/grpc-over-datachannels/tree/main/packages/eventbus-ruby\" }\n"
   "  spec.files = Dir[\"lib/**/*.rb\", \"README.md\", \"LICENSE\"]\n  spec.require_paths = [\"lib\"]\n"
   "  spec.add_runtime_dependency \"grpc-dc\", \"= " npm-version "\"\nend\n"))
(emit-eventbus-file "eventbus-ruby/README.md"
  (string-append "# eventbus-grpc (Ruby)\n\n" eb-desc " (Ruby).\n\n"
                 "Install: `gem install eventbus-grpc` (depends on `grpc-dc`).\n"))
(copy-eventbus-file "LICENSE" "eventbus-ruby/LICENSE")
;; --- NuGet ---
(for ([f (in-list (directory-list (build-path out-dir "csharp/grpcdc/events/v1")))]
      #:when (path-has-extension? f #".cs"))
  (copy-eventbus-file (build-path "csharp/grpcdc/events/v1" f)
                (build-path "eventbus-csharp" f)))
(emit-eventbus-file "eventbus-csharp/EventBusGrpc.csproj"
  (string-append
   "<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n"
   "    <TargetFrameworks>netstandard2.0;net8.0</TargetFrameworks>\n    <LangVersion>latest</LangVersion>\n"
   "    <PackageId>EventBusGrpc</PackageId>\n    <Version>" npm-version "</Version>\n"
   "    <Authors>John Davis</Authors>\n    <Description>" eb-desc " (.NET).</Description>\n"
   "    <PackageLicenseExpression>Apache-2.0</PackageLicenseExpression>\n"
   "    <RepositoryUrl>https://github.com/browser-grpc/grpc-over-datachannels</RepositoryUrl>\n"
   "  </PropertyGroup>\n  <ItemGroup>\n"
   "    <PackageReference Include=\"GrpcDc\" Version=\"" npm-version "\" />\n"
   "  </ItemGroup>\n</Project>\n"))
;; --- Maven ---
(for ([f (in-list (directory-list (build-path out-dir "java/grpcdc/events/v1")))]
      #:when (path-has-extension? f #".java"))
  (copy-eventbus-file (build-path "java/grpcdc/events/v1" f)
                (build-path "eventbus-java/grpcdc/events/v1" f)))
(emit-eventbus-file "eventbus-java/pom.xml"
  (string-append
   "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n  <modelVersion>4.0.0</modelVersion>\n"
   "  <groupId>io.github.browser-grpc</groupId>\n  <artifactId>eventbus-grpc</artifactId>\n"
   "  <version>" npm-version "</version>\n"
   "  <name>eventbus-grpc</name>\n  <description>" eb-desc " (Java).</description>\n"
   "  <url>https://github.com/browser-grpc/grpc-over-datachannels</url>\n"
   "  <licenses><license><name>Apache-2.0</name></license></licenses>\n"
   "  <developers><developer><id>unicomp21</id><name>John Davis</name><email>jdavis@pcprogramming.com</email></developer></developers>\n"
   "  <scm><connection>scm:git:https://github.com/browser-grpc/grpc-over-datachannels.git</connection><developerConnection>scm:git:https://github.com/browser-grpc/grpc-over-datachannels.git</developerConnection><url>https://github.com/browser-grpc/grpc-over-datachannels</url></scm>\n"
   "  <properties><maven.compiler.release>17</maven.compiler.release><project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties>\n"
   "  <dependencies><dependency><groupId>io.github.browser-grpc</groupId><artifactId>grpc-dc</artifactId><version>" npm-version "</version></dependency></dependencies>\n"
   "  <build><sourceDirectory>${project.basedir}</sourceDirectory><plugins>\n"
   "    <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.13.0</version></plugin>\n"
   "    <plugin><artifactId>maven-source-plugin</artifactId><version>3.3.1</version><configuration><excludes><exclude>target/**</exclude></excludes></configuration><executions><execution><id>attach-sources</id><goals><goal>jar-no-fork</goal></goals></execution></executions></plugin>\n"
   "    <plugin><artifactId>maven-javadoc-plugin</artifactId><version>3.10.0</version><configuration><additionalOptions><additionalOption>-Xdoclint:none</additionalOption></additionalOptions><quiet>true</quiet></configuration><executions><execution><id>attach-javadocs</id><goals><goal>jar</goal></goals></execution></executions></plugin>\n"
   "    <plugin><groupId>org.sonatype.central</groupId><artifactId>central-publishing-maven-plugin</artifactId><version>0.8.0</version><extensions>true</extensions><configuration><publishingServerId>central</publishingServerId><autoPublish>true</autoPublish><waitUntil>published</waitUntil></configuration></plugin>\n"
   "  </plugins></build>\n"
   "  <profiles><profile><id>release</id><build><plugins><plugin><artifactId>maven-gpg-plugin</artifactId><version>3.2.7</version><executions><execution><id>sign-artifacts</id><phase>verify</phase><goals><goal>sign</goal></goals></execution></executions><configuration><gpgArguments><arg>--pinentry-mode</arg><arg>loopback</arg></gpgArguments></configuration></plugin></plugins></build></profile></profiles>\n"
   "</project>\n"))
;; --- Cargo ---
(copy-eventbus-file "rust/gen/events_pb.rs" "eventbus-rust/src/events_pb.rs")
(copy-eventbus-file "rust/gen/events_grpc_dc.rs" "eventbus-rust/src/events_grpc_dc.rs")
(emit-eventbus-file "eventbus-rust/src/pb_message_impl.rs"
  (string-append
   "// grpc_dc::Message adapters for the events messages (same\n"
   "// macro bridge the in-repo eventbus tests use).\n"
   "use crate::events_pb::{Event, PublishReply, PublishRequest, SubscribeRequest, TagValue};\n"
   "use grpc_dc::Message;\n\n"
   "macro_rules! impl_message {\n"
   "    ($t:ty) => {\n"
   "        impl Message for $t {\n"
   "            fn encode(&self) -> Vec<u8> { <$t>::encode(self) }\n"
   "            fn decode(bytes: &[u8]) -> Result<Self, grpc_dc::Status> {\n"
   "                <$t>::decode(bytes).map_err(grpc_dc::Status::invalid_argument)\n"
   "            }\n"
   "        }\n"
   "    };\n"
   "}\n"
   "impl_message!(TagValue);\n"
   "impl_message!(PublishRequest);\n"
   "impl_message!(PublishReply);\n"
   "impl_message!(SubscribeRequest);\n"
   "impl_message!(Event);\n"))
(emit-eventbus-file "eventbus-rust/src/lib.rs"
  "pub mod events_pb;\npub mod events_grpc_dc;\n\npub use events_pb as pb;\n\nmod pb_message_impl;\n")
(emit-eventbus-file "eventbus-rust/Cargo.toml"
  (string-append
   "[package]\nname = \"eventbus-grpc\"\nversion = \"" npm-version "\"\nedition = \"2021\"\n"
   "license = \"Apache-2.0\"\ndescription = \"" eb-desc " (Rust).\"\n"
   "homepage = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "repository = \"https://github.com/browser-grpc/grpc-over-datachannels\"\n"
   "readme = \"README.md\"\n\n"
   "[dependencies]\ngrpc-dc = { version = \"" npm-version "\", path = \"../grpc-rust\" }\n"))
(emit-eventbus-file "eventbus-rust/README.md"
  (string-append "# eventbus-grpc (Rust)\n\n" eb-desc " (Rust).\n\n"
                 "```toml\n[dependencies]\neventbus-grpc = \"" npm-version "\"\n```\n\n"
                 "(depends on the `grpc-dc` crate).\n"))
(copy-eventbus-file "LICENSE" "eventbus-rust/LICENSE")
;; --- pub.dev (Dart) ---
(copy-kafka-dart "dart/grpcdc/events_messages.dart"
                 "eventbus-dart/lib/grpcdc/events_messages.dart")
(copy-kafka-dart "dart/grpcdc/events_grpc_dc.dart"
                 "eventbus-dart/lib/grpcdc/events_grpc_dc.dart")
(emit-eventbus-file "eventbus-dart/lib/eventbus_grpc.dart"
  (string-append
   "// eventbus_grpc: generated grpcdc.events.v1 stubs for Dart.\n"
   "// The runtime lives in package:grpc_dc.\n"
   "export 'grpcdc/events_messages.dart';\n"
   "export 'grpcdc/events_grpc_dc.dart';\n"))
(emit-eventbus-file "eventbus-dart/pubspec.yaml"
  (string-append
   "name: eventbus_grpc\n"
   "version: " npm-version "\n"
   "description: \"Event bus over gRPC for Dart and Flutter: generated grpcdc.events.v1 publish/subscribe clients speaking gRPC over WebRTC DataChannels, via the grpc_dc runtime.\"\n"
   "homepage: https://github.com/browser-grpc/grpc-over-datachannels\n"
   "repository: https://github.com/browser-grpc/grpc-over-datachannels\n"
   "issue_tracker: https://github.com/browser-grpc/grpc-over-datachannels/issues\n"
   "environment:\n  sdk: \">=3.0.0 <4.0.0\"\n"
   "dependencies:\n  grpc_dc: ^" npm-version "\n"))
(emit-eventbus-file "eventbus-dart/README.md"
  (string-append "# eventbus_grpc (Dart)\n\n" eb-desc " (Dart).\n\n"
                 "Install: `dart pub add eventbus_grpc` (depends on `grpc_dc`).\n"))
(emit-eventbus-file "eventbus-dart/CHANGELOG.md"
  (string-append "# Changelog\n\n## " npm-version "\n\n"
                 "- First pub.dev release: generated `grpcdc.events.v1`\n"
                 "  Dart stubs from grpc-over-datachannels v" npm-version ".\n"))
(copy-dart-pub "LICENSE" "eventbus-dart/LICENSE")
;; --- Go (nested module at repo root, matching its path) ---
(copy-go-file "go/eventbus/events_pb.go" "eventbus/events_pb.go")
(copy-go-file "go/eventbus/events_grpc_dc.go" "eventbus/events_grpc_dc.go")
(emit-go-file "eventbus/go.mod"
  (string-append
   "module github.com/browser-grpc/grpc-over-datachannels/eventbus\n\ngo 1.21\n\n"
   "require github.com/browser-grpc/grpc-over-datachannels/go v" npm-version "\n"))
(call-with-output-file (build-path kafka-root "README.md")
  #:exists 'replace
  (lambda (out) (display
   (string-append
   "# Separate kafka-grpc and eventbus-grpc packages\n\n"
   "Each `kafka-<lang>` tree here is a standalone package of the\n"
   "generated `grpcdc.kafka.v1` stubs for one ecosystem, depending\n"
   "on that ecosystem's `grpc-dc` package at the same version.\n"
   "The `eventbus-<lang>` trees do the same for the generated\n"
   "`grpcdc.events.v1` stubs (package name `eventbus-grpc`, Dart\n"
   "`eventbus_grpc`):\n\n"
   "| Tree | Package | Depends on |\n|---|---|---|\n"
   "| kafka-js | npm `kafka-grpc` / GitHub `@browser-grpc/kafka-grpc` | `grpc-dc` / `@browser-grpc/grpc-dc` |\n"
   "| kafka-python | PyPI `kafka-grpc` | `grpc-dc` |\n"
   "| kafka-ruby | RubyGems/GitHub `kafka-grpc` | `grpc-dc` |\n"
   "| kafka-csharp | NuGet/GitHub `KafkaGrpc` | `GrpcDc` |\n"
   "| kafka-java | Maven `io.github.browser-grpc:kafka-grpc` | `io.github.browser-grpc:grpc-dc` |\n"
   "| kafka-rust | crates.io `kafka-grpc` | `grpc-dc` |\n"
   "| (repo root) kafka/ | Go module `github.com/browser-grpc/grpc-over-datachannels/kafka` | `.../go` |\n"
   "| (repo root) eventbus/ | Go module `github.com/browser-grpc/grpc-over-datachannels/eventbus` | `.../go` |\n"
   "| kafka-dart | pub.dev `kafka_grpc` | pub.dev `grpc_dc` |\n\n"
   "Kotlin, Scala, PHP, Lua, Swift, Zig, C and C++ carry the\n"
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
         (regexp-match? #rx"(^|[\"'`(/ \t])racket/[a-z0-9_.*-]+[.]rkt"
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
