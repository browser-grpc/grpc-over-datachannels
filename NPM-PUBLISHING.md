# Publishing grpc-dc to npm (maintainers)

Two paths exist. Path 1 is active today; path 2 replaces
it before npm retires token-based direct publishing in
January 2027 (the current granular token also expires
2027-01-22).

## Path 1: local token (current)

`scripts/release-push.sh` in the private source repo
publishes `js/` from the generated export during a
release, using the maintainer's granular access token
(scope: the `grpc-dc` package only). No action is needed
per release beyond being logged in.

## Path 2: Trusted Publishing via GitHub Actions

This export ships `.github/workflows/publish-npm.yml`
(manual dispatch only). It publishes `js/` with
`npm publish --provenance` using the workflow's OIDC
identity — no token is stored anywhere.

One-time setup on npmjs.com (package owner, passkey
required):

1. Open the `grpc-dc` package settings, Trusted Publisher.
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
