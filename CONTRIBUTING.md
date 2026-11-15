# Contributing

Development happens in this repository (GitLab). The repositories under the GitHub `browser-grpc` org are generated public exports of this tree — changes made directly in an export are overwritten at the next release, so please open issues and merge requests here.

When you report a bug, include:

- The package and version (for example `grpc-dc` 0.42.0), language, and runtime (browser + version, or OS).
- A minimal `.proto` and the smallest call sequence that reproduces it.
- What you expected, what happened, and any status code or log output.

Most of the public surface is generated: runtimes and stubs come from the Racket generators under `racket/`. Edit the generator, run `make generate`, and let `make check-generated` confirm the tree is byte-stable; do not hand-edit generated files (they carry a `DO NOT EDIT` header). `make test` runs the full matrix (inside the `grpc-dc-ci` image from `Dockerfile.ci` it needs no host toolchains).
