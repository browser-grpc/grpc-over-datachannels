//! Rendezvous auth: the fixed cross-stack token vector (the JS
//! and Go suites verify this exact token), plus expired /
//! bad-signature / wrong-scope rejection. Token-level only:
//! no `webrtc` feature needed.

use grpc_dc::server::{
    decode_rendezvous_claims, encode_rendezvous_claims, issue_rendezvous_token, RendezvousAuth,
    RendezvousClaims,
};
use grpc_dc::{Code, Metadata};

const VECTOR_SECRET: &[u8] = b"rendezvous-auth-test-secret";
const VECTOR_TOKEN: &str = "CgVhbGljZRIGaXNzdWVyGgpyZW5kZXp2b3VzIICumaQPKIDiz6oGMIDiz6oGOgRyZWFkOgV3cml0ZUIFdmVjLTE.3KLgA4zxXSOPZn2jw1lNkYqm5Urijo37qwU0NVMkIWM";

fn vector_claims() -> RendezvousClaims {
    RendezvousClaims {
        sub: "alice".into(),
        iss: "issuer".into(),
        aud: "rendezvous".into(),
        exp: 4102444800,
        nbf: 1700000000,
        iat: 1700000000,
        scopes: vec!["read".into(), "write".into()],
        jti: "vec-1".into(),
    }
}

fn vector_auth() -> RendezvousAuth {
    let mut auth = RendezvousAuth::new(VECTOR_SECRET.to_vec());
    auth.issuer = "issuer".into();
    auth.audience = "rendezvous".into();
    auth
}

#[test]
fn fixed_cross_stack_vector_verifies() {
    let claims = vector_auth()
        .verify_token(VECTOR_TOKEN, Some(1700000100))
        .expect("vector verifies");
    assert_eq!(claims, vector_claims());
    assert_eq!(
        issue_rendezvous_token(VECTOR_SECRET, &vector_claims()),
        VECTOR_TOKEN
    );
    let bytes = encode_rendezvous_claims(&vector_claims());
    assert_eq!(
        hex(&bytes),
        "0a05616c69636512066973737565721a0a72656e64657a766f75732080ae99a40f2880e2cfaa063080e2cfaa063a04726561643a05777269746542057665632d31"
    );
    assert_eq!(decode_rendezvous_claims(&bytes).unwrap(), vector_claims());
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn expired_and_bad_signature_reject() {
    let err = vector_auth()
        .verify_token(VECTOR_TOKEN, Some(4102444800))
        .unwrap_err();
    assert_eq!(err.code, Code::Unauthenticated);
    let mut wrong = vector_auth();
    wrong.secret = b"wrong-secret".to_vec();
    let err = wrong.verify_token(VECTOR_TOKEN, Some(1700000100)).unwrap_err();
    assert_eq!(err.code, Code::Unauthenticated);
    let err = vector_auth().verify_token("not-a-token", Some(1700000100)).unwrap_err();
    assert_eq!(err.code, Code::Unauthenticated);
}

#[test]
fn metadata_scope_check() {
    let mut auth = vector_auth();
    auth.scopes
        .insert("/echo.Echo/Unary".into(), vec!["admin".into()]);
    let mut md = Metadata::new();
    md.insert("authorization".into(), format!("Bearer {VECTOR_TOKEN}"));
    // The vector is not yet valid at the real clock's past nbf
    // check inside verify_metadata only via wall-clock expiry:
    // exp is 2100 and nbf is 2023, so the wall clock accepts it.
    let err = auth.verify_metadata(&md, "/echo.Echo/Unary").unwrap_err();
    assert_eq!(err.code, Code::PermissionDenied);

    let mut ok_auth = vector_auth();
    ok_auth
        .scopes
        .insert("/echo.Echo/Unary".into(), vec!["read".into()]);
    let claims = ok_auth.verify_metadata(&md, "/echo.Echo/Unary").unwrap();
    assert_eq!(claims.sub, "alice");

    let err = ok_auth.verify_metadata(&Metadata::new(), "/echo.Echo/Unary").unwrap_err();
    assert_eq!(err.code, Code::Unauthenticated);
}
