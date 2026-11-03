# Publishing grpc-dc to npm (maintainers)

The Trusted Publishing workflow (path 2) is the active
publish path since v0.37.1: `scripts/release-push.sh`
dispatches it during a release. The local-token path is
kept below as a fallback only; npm retires token-based
direct publishing in January 2027.

## Path 1: local token (fallback)

With a granular access token (all-packages, bypass 2FA)
in `~/.npmrc`: `npm publish --access public` in `js/`
and `packages/kafka-js` from the generated export.

## Path 2: Trusted Publishing via GitHub Actions

This export ships `.github/workflows/publish-npm.yml`
(manual dispatch only). It publishes `js/` (grpc-dc)
and `packages/kafka-js` (kafka-grpc) with
`npm publish --provenance` using the workflow's OIDC
identity — no token is stored anywhere.

One-time setup on npmjs.com (package owner, passkey
required), once per package:

1. Open the package settings (`grpc-dc` and
   `kafka-grpc`), Trusted Publisher.
2. Add GitHub Actions: repository
   `browser-grpc/grpc-over-datachannels`, workflow
   filename `publish-npm.yml`, no environment.
3. Recommended: set the package Publishing access to
   require two-factor authentication and disallow tokens
   once this path is verified.

Per release after setup: publish the GitHub release as
usual, then run Actions > publish-npm > Run workflow.
The version comes from `js/package.json` in the export,
already aligned with the release tag. Verify with
`npm view grpc-dc version`.

Fallback if OIDC is unavailable: staged publishing
(`npm stage publish` from `js/`, then approve the staged
package on npmjs.com with a passkey).
