# Rendezvous auth example: WebAuthn issuer → bearer token → rendezvous

The rendezvous listener can require callers to authenticate
without the rendezvous server ever touching WebAuthn. A
backend **issuer** verifies the WebAuthn ceremony over HTTPS
and mints a rendezvous bearer token; the browser presents
that token per call over the DataChannel, and the rendezvous
server only verifies the token's HMAC.

```
browser --WebAuthn (HTTPS)--> issuer --mints--> token
browser --token over DataChannel--> rendezvous server (HMAC verify only)
```

Run it:

```sh
node examples/rendezvous-auth/server.mjs
# open http://localhost:8080/ in your browser
```

WebAuthn requires a secure context: `localhost` works out of
the box; a deployed origin needs HTTPS (and the page origin
becomes the WebAuthn `rpId`). In the page: register a
passkey, then *log in + call Echo* — the unary response
echoes the token subject (`sub=alice`).

| File | What |
|---|---|
| [issuer.mjs](issuer.mjs) | Stdlib-only WebAuthn verification (challenge/origin/rpId, attestation `none`, ES256 assertion) + token minting via the generated `issueRendezvousToken` |
| [server.mjs](server.mjs) | HTTP page/descriptor/auth routes + `serveRendezvous(..., { auth })` Echo listener |
| [client.html](client.html) | Passkey register/login, then `rendezvousChannel(descriptor, { token })` |
| [issuer.test.mjs](issuer.test.mjs) | Browser-free test: a synthetic WebCrypto credential registers, logs in, and the minted token verifies |

```sh
node --test examples/rendezvous-auth/issuer.test.mjs
```

Token shape (same on the JS, Go, and Rust stacks):
`base64url(protobuf claims) + "." + base64url(HMAC-SHA256(secret, claims))`
with claims `sub/iss/aud/exp/nbf/iat/scopes[]/jti`. The
server rejects bad or expired tokens with `UNAUTHENTICATED`
and under-scoped ones with `PERMISSION_DENIED`; handlers see
verified claims as `ctx.claims`. Set `RENDEZVOUS_SECRET` in
production — the issuer and the rendezvous server must share
it, and it must not be the dev default.
