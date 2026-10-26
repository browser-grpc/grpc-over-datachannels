#lang racket

;;; template-rust.rkt — emitter body spliced into protoc-gen-grpc-dc-rust.
;;; (metagen.rkt strips the #lang / #require / #provide lines and inlines
;;;  this body into the generated plugin, after spec/pb/desc bodies.)
;;;
;;; Generated code assumes the runtime crate is named `grpc_dc` and that
;;; protobuf message types live in the module named by the protoc plugin
;;; parameter `message_module` (default `crate::pb`), each implementing
;;; `grpc_dc::Message`.

(require "spec.rkt" "desc.rkt")
(provide emit-rust-file)

(define (snake-case s)
  (list->string
   (for/fold ([out '()] [prev-lower? #f] #:result (reverse out))
             ([c (in-string s)])
     (cond [(char-upper-case? c)
            (values (cons (char-downcase c)
                          (if (and prev-lower? (not (null? out))) (cons #\_ out) out))
                    #f)]
           [else (values (cons c out) #t)]))))

(define (rust-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a#[deprecated = \"deprecated in the proto schema\"]\n" indent)
      ""))

(define (rust-client-method m msgmod)
  (define name (hash-ref m 'name))
  (define fn-name (snake-case name))
  (define req (format "~a::~a" msgmod (hash-ref m 'input)))
  (define resp (format "~a::~a" msgmod (hash-ref m 'output)))
  (define path (hash-ref m 'path))
  (define depr (rust-deprecated m "    "))
  (case (hash-ref m 'kind)
    [(unary)
     (format "~a    pub async fn ~a(&self, req: ~a) -> Result<~a, ::grpc_dc::Status> {\n        self.channel.unary(~s, req).await\n    }\n"
             depr fn-name req resp path)]
    [(server-streaming)
     (format "~a    pub async fn ~a(&self, req: ~a) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status> {\n        self.channel.server_stream(~s, req).await\n    }\n"
             depr fn-name req resp path)]
    [(client-streaming)
     (format "~a    pub async fn ~a<S>(&self, reqs: S) -> Result<~a, ::grpc_dc::Status>\n    where S: ::grpc_dc::futures_core::Stream<Item = ~a> + Send + 'static {\n        self.channel.client_stream(~s, reqs).await\n    }\n"
             depr fn-name resp req path)]
    [(bidi)
     (format "~a    pub async fn ~a<S>(&self, reqs: S) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status>\n    where S: ::grpc_dc::futures_core::Stream<Item = ~a> + Send + 'static {\n        self.channel.bidi(~s, reqs).await\n    }\n"
             depr fn-name resp req path)]))

(define (rust-client-options-method m msgmod)
  (define name (hash-ref m 'name))
  (define fn-name (snake-case name))
  (define req (format "~a::~a" msgmod (hash-ref m 'input)))
  (define resp (format "~a::~a" msgmod (hash-ref m 'output)))
  (define path (hash-ref m 'path))
  (define depr (rust-deprecated m "    "))
  (case (hash-ref m 'kind)
    [(unary)
     (format "~a    pub async fn ~a_with_options(&self, req: ~a, options: ::grpc_dc::CallOptions) -> Result<~a, ::grpc_dc::Status> {\n        self.channel.unary_with_options(~s, req, options).await\n    }\n"
             depr fn-name req resp path)]
    [(server-streaming)
     (format "~a    pub async fn ~a_with_options(&self, req: ~a, options: ::grpc_dc::CallOptions) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status> {\n        self.channel.server_stream_with_options(~s, req, options).await\n    }\n"
             depr fn-name req resp path)]
    [(client-streaming)
     (format "~a    pub async fn ~a_with_options<S>(&self, reqs: S, options: ::grpc_dc::CallOptions) -> Result<~a, ::grpc_dc::Status>\n    where S: ::grpc_dc::futures_core::Stream<Item = ~a> + Send + 'static {\n        self.channel.client_stream_with_options(~s, reqs, options).await\n    }\n"
             depr fn-name resp req path)]
    [(bidi)
     (format "~a    pub async fn ~a_with_options<S>(&self, reqs: S, options: ::grpc_dc::CallOptions) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status>\n    where S: ::grpc_dc::futures_core::Stream<Item = ~a> + Send + 'static {\n        self.channel.bidi_with_options(~s, reqs, options).await\n    }\n"
             depr fn-name resp req path)]))

(define (rust-trait-method/deprecated m msgmod)
  (string-append (rust-deprecated m "    ") (rust-trait-method m msgmod)))

(define (rust-trait-method m msgmod)
  (define fn-name (snake-case (hash-ref m 'name)))
  (define req (format "~a::~a" msgmod (hash-ref m 'input)))
  (define resp (format "~a::~a" msgmod (hash-ref m 'output)))
  (case (hash-ref m 'kind)
    [(unary)
     (format "    async fn ~a(&self, req: ~a, ctx: ::grpc_dc::CallCtx) -> Result<~a, ::grpc_dc::Status>;\n"
             fn-name req resp)]
    [(server-streaming)
     (format "    async fn ~a(&self, req: ~a, ctx: ::grpc_dc::CallCtx) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status>;\n"
             fn-name req resp)]
    [(client-streaming)
     (format "    async fn ~a(&self, reqs: ::grpc_dc::RequestStream<~a>, ctx: ::grpc_dc::CallCtx) -> Result<~a, ::grpc_dc::Status>;\n"
             fn-name req resp)]
    [(bidi)
     (format "    async fn ~a(&self, reqs: ::grpc_dc::RequestStream<~a>, ctx: ::grpc_dc::CallCtx) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status>;\n"
             fn-name req resp)]))

(define (rust-register-method m service-var)
  (define fn-name (snake-case (method-impl-name m)))
  (define helper (case (hash-ref m 'kind)
                   [(unary) "unary_method"]
                   [(server-streaming) "server_stream_method"]
                   [(client-streaming) "client_stream_method"]
                   [(bidi) "bidi_method"]))
  (format "        ::grpc_dc::~a(~s, { let svc = ~a.clone(); move |req, ctx| { let svc = svc.clone(); async move { svc.~a(req, ctx).await } } }),\n"
          helper (hash-ref m 'name) service-var fn-name))

(define (rust-service svc msgmod)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (string-append
   (format "pub struct ~aClient { channel: ::grpc_dc::Channel }\n\n" sname)
   (format "impl ~aClient {\n    pub fn new(channel: ::grpc_dc::Channel) -> Self { Self { channel } }\n" sname)
   (apply string-append (map (lambda (m) (rust-client-method m msgmod))
                              (append methods (alias-client-methods svc))))
   (apply string-append (map (lambda (m) (rust-client-options-method m msgmod))
                              (append methods (alias-client-methods svc))))
   "}\n\n"
   (format "#[::grpc_dc::async_trait]\npub trait ~a: Send + Sync + 'static {\n" sname)
   (apply string-append (map (lambda (m) (rust-trait-method/deprecated m msgmod)) methods))
   "}\n\n"
   (format "pub fn ~a_service<S: ~a>(svc: std::sync::Arc<S>) -> ::grpc_dc::ServiceDef {\n    ::grpc_dc::ServiceDef::new(~s, vec![\n"
           (snake-case sname) sname (hash-ref svc 'full-name))
   (apply string-append (map (lambda (m) (rust-register-method m "svc"))
                              (append methods (alias-server-methods svc))))
   "    ])\n}\n"))

;; ---------------------------------------------------------------------------
;; Generated message types (<base>_pb.rs): std-only protobuf wire
;; codec (structs + encode/decode), emitted from the shared
;; desc.rkt model. Mirrors the Lua/Zig emitters; cross-file types
;; resolve to crate::<base>_pb::<Type> sibling modules.
;; ---------------------------------------------------------------------------

(define rs-pb-varint-types '(5 3 13 4 17 18 8 14))
;; type -> (size kind)
(define rs-pb-fixed '((1 8 f64) (2 4 f32) (6 8 u64) (7 4 u32) (15 4 i32) (16 8 i64)))

(define (rs-pb-snake s)
  (string-join (map string-downcase (string-split s "_")) "_"))

(define (rs-pb-camel s)
  ;; SNAKE_UPPER or snake -> CamelCase for identifiers.
  (apply string-append
         (map (lambda (p)
                (if (string=? p "")
                    ""
                    (string-append (string (char-upcase (string-ref p 0)))
                                   (string-downcase (substring p 1)))))
              (string-split s "_"))))

(define rs-pb-rust-keywords
  '("type" "ref" "box" "self" "Self" "crate" "super" "move" "static"
    "mut" "fn" "struct" "enum" "impl" "trait" "loop" "match" "mod"
    "pub" "use" "where" "async" "await" "dyn" "abstract" "become"
    "do" "final" "macro" "override" "priv" "typeof" "unsized"
    "virtual" "yield" "try" "gen"))

(define (rs-pb-field-name f)
  (define name (rs-pb-snake (hash-ref f 'name)))
  ;; A proto field named like a Rust keyword (Payload.type) must
  ;; be emitted as a raw identifier everywhere it appears.
  (if (member name rs-pb-rust-keywords) (string-append "r#" name) name))

(define (rs-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (rs-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-rust-pb-file "unresolved type ~a" type-name))))

(define (rs-pb-entry-ref model entry)
  (define flat
    (rs-pb-flat (hash-ref entry 'pkg)
                (or (hash-ref entry 'full #f)
                    (if (eq? (hash-ref entry 'kind) 'enum)
                        (let ([e (hash-ref entry 'enum)])
                          (if (hash-ref entry 'msg)
                              (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                              (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                        (hash-ref (hash-ref entry 'msg) 'full-name)))))
  (if (or (eq? (hash-ref entry 'kind) 'map)
          (equal? (hash-ref entry 'file) (hash-ref model 'name)))
      flat
      (format "crate::~a_pb::~a"
              (path->string (path-replace-extension
                             (file-name-from-path (hash-ref entry 'file)) ""))
              (if (eq? (hash-ref entry 'kind) 'enum)
                  (hash-ref (hash-ref entry 'enum) 'name)
                  flat))))

(define (rs-pb-scalar-type f)
  (case (hash-ref f 'type)
    [(1) "f64"]
    [(2) "f32"]
    [(3 4 6 16 18) "i64-or-u64"]
    [(8) "bool"]
    [(9) "String"]
    [(12) "Vec<u8>"]
    [else "i32"]))

(define (rs-pb-elem-type model f)
  (define type (hash-ref f 'type))
  (cond [(= type 11) (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name)))]
        [(= type 14) (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name)))]
        [(memv type '(4 6)) "u64"]
        [(memv type '(3 16 18)) "i64"]
        [(= type 13) "u32"]
        [(= type 7) "u32"]
        [else (rs-pb-scalar-type f)]))

(define current-rust-no-std (make-parameter #f))

(define (rs-pb-map-type)
  (if (current-rust-no-std) "BTreeMap" "std::collections::HashMap"))

(define (rs-pb-type model f)
  (cond [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (rs-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (rs-pb-resolve model (hash-ref f 'type-name)))
         (define msg (hash-ref entry 'msg))
         (define kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
         (define vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
         (format "~a<~a, ~a>" (rs-pb-map-type) (rs-pb-elem-type model kf) (rs-pb-elem-type model vf))]
        [(= (hash-ref f 'label) 3) (format "Vec<~a>" (rs-pb-elem-type model f))]
        [(= (hash-ref f 'type) 11) (format "Option<Box<~a>>" (rs-pb-elem-type model f))]
        [else (rs-pb-elem-type model f)]))

(define (rs-pb-default model f)
  (cond [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (rs-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (format "~a::new()" (rs-pb-map-type))]
        [(= (hash-ref f 'label) 3) "Vec::new()"]
        [(= (hash-ref f 'type) 11) "None"]
        [(= (hash-ref f 'type) 9) "String::new()"]
        [(= (hash-ref f 'type) 12) "Vec::new()"]
        [(= (hash-ref f 'type) 8) "false"]
        [(= (hash-ref f 'type) 1) "0.0"]
        [(= (hash-ref f 'type) 2) "0.0"]
        [(= (hash-ref f 'type) 14)
         (define d (field-explicit-default f))
         (define entry (rs-pb-resolve model (hash-ref f 'type-name)))
         (if d
             (format "~a::~a" (rs-pb-entry-ref model entry) (rs-pb-camel d))
             (format "~a::~a" (rs-pb-entry-ref model entry)
                     (rs-pb-camel (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'name))))]
        [else (let ([d (field-explicit-default f)])
                (cond [(not d) "0"]
                      [(= (hash-ref f 'type) 9) (format "~a.to_string()" (format "~s" d))]
                      [(= (hash-ref f 'type) 8) d]
                      [else d]))]))

(define (rs-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(if ~a { 1u64 } else { 0u64 })" v)]
    [(17) (format "((((~a << 1) ^ (~a >> 31)) as u32) as u64)" v v)]
    [(18) (format "(((~a << 1) ^ (~a >> 63)) as u64)" v v)]
    [else (format "(~a as u64)" v)]))

(define (rs-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5 15) (format "(~a as u32 as i32)" v)]
    [(14) (format "(~a as i32)" v)]
    [(13 7) (format "(~a as u32)" v)]
    [(8) (format "(~a != 0)" v)]
    [(17) (format "(((~a as u32 >> 1) as i32) ^ (-(((~a as u32) & 1) as i32)))" v v)]
    [(18) (format "(((~a >> 1) as i64) ^ (-((~a & 1) as i64)))" v v)]
    [(4 6) (format "(~a as u64)" v)]
    [else (format "(~a as i64)" v)]))

(define (rs-pb-fixed-info f) (assv (hash-ref f 'type) rs-pb-fixed))
(define (rs-pb-wire f) (if (= (second (rs-pb-fixed-info f)) 8) 1 5))

(define (rs-pb-fixed-encode-expr f v)
  (case (third (rs-pb-fixed-info f))
    [(f64) (format "pb_append_fixed64(&mut out, ~a.to_bits());" v)]
    [(f32) (format "pb_append_fixed32(&mut out, ~a.to_bits());" v)]
    [(u64) (format "pb_append_fixed64(&mut out, ~a);" v)]
    [(i64) (format "pb_append_fixed64(&mut out, ~a as u64);" v)]
    [(u32) (format "pb_append_fixed32(&mut out, ~a);" v)]
    [(i32) (format "pb_append_fixed32(&mut out, ~a as u32);" v)]))

(define (rs-pb-fixed-decode-expr f src)
  (case (third (rs-pb-fixed-info f))
    [(f64) (format "f64::from_bits(~a)" src)]
    [(f32) (format "f32::from_bits(~a as u32)" src)]
    [(u64) (format "(~a as u64)" src)]
    [(i64) (format "(~a as u64 as i64)" src)]
    [(u32) (format "(~a as u32)" src)]
    [(i32) (format "(~a as u32 as i32)" src)]))

(define (rs-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type rs-pb-varint-types)
         (if proto2?
             (format "~a{ pb_append_tag(&mut out, ~a, 0); pb_append_varint(&mut out, ~a); }\n" indent n
                     (if (= type 14) (format "(~a as i32 as u64)" v) (rs-pb-varint-expr f v)))
             (format "~aif ~a { pb_append_tag(&mut out, ~a, 0); pb_append_varint(&mut out, ~a); }\n" indent
                     (if (= type 8) v (format "~a != ~a" v (rs-pb-default model (hash-set f 'label 1)))) n
                     (if (= type 14) (format "(~a as i32 as u64)" v) (rs-pb-varint-expr f v))))]
        [(assv type rs-pb-fixed)
         (if proto2?
             (format "~a{ pb_append_tag(&mut out, ~a, ~a); ~a }\n" indent n (rs-pb-wire f) (rs-pb-fixed-encode-expr f v))
             (format "~aif ~a != ~a { pb_append_tag(&mut out, ~a, ~a); ~a }\n" indent v (rs-pb-default model (hash-set f 'label 1)) n (rs-pb-wire f) (rs-pb-fixed-encode-expr f v)))]
        [(= type 9)
         (if proto2?
             (format "~apb_append_bytes_field(&mut out, ~a, ~a.as_bytes());\n" indent n v)
             (format "~apb_append_string_field(&mut out, ~a, &~a);\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~apb_append_bytes_field(&mut out, ~a, &~a);\n" indent n v)
             (format "~aif !~a.is_empty() { pb_append_bytes_field(&mut out, ~a, &~a); }\n" indent v n v))]
        [(= type 11) (format "~aif let Some(v) = &~a { pb_append_bytes_field(&mut out, ~a, &v.encode()); }\n" indent v n)]
        [else (error 'emit-rust-pb-file "unsupported field type ~a (groups)" type)]))

(define (rs-pb-set-expr sib)
  (define v (format "self.~a" (rs-pb-field-name sib)))
  (case (hash-ref sib 'type)
    [(11 10) (format "~a.is_some()" v)]
    [(9 12) (format "!~a.is_empty()" v)]
    [(8) v]
    [(14) (format "(~a as i32) != 0" v)]
    [(1 2) (format "~a != 0.0" v)]
    [else (format "~a != 0" v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (rs-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "        if !(~a) {\n~a        }\n"
              (string-join (map rs-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (rs-pb-encode-field model f)
  (define v (format "self.~a" (rs-pb-field-name f)))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (rs-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (rs-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "pb_encode_~a" (rs-pb-entry-ref model entry)))
         ;; Sorted key order on encode (protobuf canonical
         ;; form): HashMap iteration order is randomized, so an
         ;; unsorted loop makes encodings nondeterministic.
         (format "        { let mut keys: Vec<&_> = ~a.keys().collect(); keys.sort(); for k in keys { let val = &~a[k]; pb_append_bytes_field(&mut out, ~a, &~a(k, val)); } }\n" v v n helper)]
        [(not (= (hash-ref f 'label) 3)) (rs-pb-encode-singular model f v "        ")]
        [(memv type rs-pb-varint-types)
         (string-append
          (format "        if !~a.is_empty() {\n            let mut payload = Vec::new();\n" v)
          (format "            for x in &~a { pb_append_varint(&mut payload, ~a); }\n" v
                  (if (= type 14) "(*x as i32 as u64)" (rs-pb-varint-expr f "(*x)")))
          (format "            pb_append_bytes_field(&mut out, ~a, &payload);\n        }\n" n))]
        [(assv type rs-pb-fixed)
         (string-append
          (format "        if !~a.is_empty() {\n            let mut payload = Vec::new();\n" v)
          (format "            for x in &~a { ~a }\n" v (rs-pb-fixed-encode-expr-payload f "(*x)"))
          (format "            pb_append_bytes_field(&mut out, ~a, &payload);\n        }\n" n))]
        [(= type 9) (format "        for x in &~a { pb_append_bytes_field(&mut out, ~a, x.as_bytes()); }\n" v n)]
        [(= type 12) (format "        for x in &~a { pb_append_bytes_field(&mut out, ~a, x); }\n" v n)]
        [(= type 11) (format "        for x in &~a { pb_append_bytes_field(&mut out, ~a, &x.encode()); }\n" v n)]
        [else (error 'emit-rust-pb-file "unsupported repeated field type ~a" type)]))

(define (rs-pb-fixed-encode-expr-payload f v)
  (case (third (rs-pb-fixed-info f))
    [(f64) (format "payload.extend_from_slice(&~a.to_bits().to_le_bytes());" v)]
    [(f32) (format "payload.extend_from_slice(&~a.to_bits().to_le_bytes());" v)]
    [(u64 i64) (format "payload.extend_from_slice(&~a.to_le_bytes());" (if (eq? (third (rs-pb-fixed-info f)) 'i64) (format "(~a as u64)" v) v))]
    [(u32 i32) (format "payload.extend_from_slice(&~a.to_le_bytes());" (if (eq? (third (rs-pb-fixed-info f)) 'i32) (format "(~a as u32)" v) v))]))

(define (rs-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type rs-pb-varint-types)
         (format "~a~a = ~a;\n" indent target
                 (if (= type 14)
                     (format "~a::from_i32(~a as i32)" (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name))) src)
                     (rs-pb-varint-decode f src)))]
        [(assv type rs-pb-fixed)
         (format "~a~a = ~a;\n" indent target (rs-pb-fixed-decode-expr f src))]
        [(= type 9) (format "~a~a = String::from_utf8_lossy(&~a).into_owned();\n" indent target src)]
        [(= type 12) (format "~a~a = ~a;\n" indent target src)]
        [(= type 11)
         (format "~a~a = Some(Box::new(~a::decode(&~a)?));\n" indent target
                 (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name))) src)]
        [else (error 'emit-rust-pb-file "unsupported field type ~a" type)]))

(define (rs-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "                    msg.~a = ~a;\n" (rs-pb-field-name sib) (rs-pb-default model sib)))
              (oneof-siblings model f))))

(define (rs-pb-decode-case model f)
  (define v (format "msg.~a" (rs-pb-field-name f)))
  (define type (hash-ref f 'type))
  (define head (format "                ~a => {\n" (hash-ref f 'number)))
  (define tail "                }\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (rs-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (rs-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "pb_decode_~a" (rs-pb-entry-ref model entry)))
         (string-append head
                        (format "                    let (kk, vv) = ~a(&field.bytes_value)?;\n" helper)
                        (format "                    ~a.insert(kk, vv);\n" v)
                        tail)]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        (rs-pb-oneof-clearing model f)
                        (rs-pb-decode-singular model f v
                                               (cond [(memv type rs-pb-varint-types) "field.varint_value"]
                                                     [(assv type rs-pb-fixed) "field.fixed_value"]
                                                     [else "field.bytes_value"])
                                               "                    ")
                        tail)]
        [(memv type rs-pb-varint-types)
         (string-append head
                        "                    if field.wire == 2 {\n                        let mut sub = PbReader::new(&field.bytes_value);\n                        while !sub.done() {\n                            let raw = sub.varint()?;\n"
                        (format "                            ~a.push(~a);\n" v
                                (if (= type 14)
                                    (format "~a::from_i32(raw as i32)" (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name))))
                                    (rs-pb-varint-decode f "raw")))
                        "                        }\n                    } else {\n"
                        (format "                        ~a.push(~a);\n" v
                                (if (= type 14)
                                    (format "~a::from_i32(field.varint_value as i32)" (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name))))
                                    (rs-pb-varint-decode f "field.varint_value")))
                        "                    }\n"
                        tail)]
        [(assv type rs-pb-fixed)
         (string-append head
                        "                    if field.wire == 2 {\n                        let mut i = 0;\n                        while i < field.bytes_value.len() {\n"
                        (format "                            let mut padded = [0u8; 8];\n                            padded[..~a].copy_from_slice(&field.bytes_value[i..i + ~a]);\n                            let chunk = u64::from_le_bytes(padded);\n" (second (rs-pb-fixed-info f)) (second (rs-pb-fixed-info f)))
                        (if (= (second (rs-pb-fixed-info f)) 4)
                            (format "                            ~a.push(~a);\n" v (rs-pb-fixed-decode-expr-32 f "chunk"))
                            (format "                            ~a.push(~a);\n" v (rs-pb-fixed-decode-expr f "chunk")))
                        (format "                            i += ~a;\n                        }\n                    } else {\n" (second (rs-pb-fixed-info f)))
                        (format "                        ~a.push(~a);\n" v (rs-pb-fixed-decode-expr f "field.fixed_value"))
                        "                    }\n"
                        tail)]
        [(= type 9) (string-append head (format "                    ~a.push(String::from_utf8_lossy(&field.bytes_value).into_owned());\n" v) tail)]
        [(= type 12) (string-append head (format "                    ~a.push(field.bytes_value.clone());\n" v) tail)]
        [(= type 11)
         (string-append head
                        (format "                    ~a.push(~a::decode(&field.bytes_value)?);\n" v (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name))))
                        tail)]
        [else (error 'emit-rust-pb-file "unsupported repeated field type ~a" type)]))

(define (rs-pb-fixed-decode-expr-32 f src)
  (case (third (rs-pb-fixed-info f))
    [(f32) (format "f32::from_bits(~a as u32)" src)]
    [(u32) (format "(~a as u32)" src)]
    [(i32) (format "(~a as u32 as i32)" src)]
    [else (rs-pb-fixed-decode-expr f src)]))

(define (rs-pb-map-helpers model entry)
  (define msg (hash-ref entry 'msg))
  (define base (rs-pb-entry-ref model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-rust-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (string-append
   (format "fn pb_encode_~a(key: &~a, value: &~a) -> Vec<u8> {\n    let mut out = Vec::new();\n" base (rs-pb-elem-type model key-f) (rs-pb-elem-type model val-f))
   (rs-pb-encode-singular model (hash-set key-f 'label 1) "(*key)" "    ")
   (if (= (hash-ref val-f 'type) 11)
       (format "    pb_append_bytes_field(&mut out, ~a, &value.encode());\n" (hash-ref val-f 'number))
       (rs-pb-encode-singular model (hash-set val-f 'label 1) "(*value)" "    "))
   "    out\n}\n\n"
   (format "fn pb_decode_~a(data: &[u8]) -> Result<(~a, ~a), String> {\n" base (rs-pb-elem-type model key-f) (rs-pb-elem-type model val-f))
   (format "    let mut key: ~a = ~a;\n    let mut value: ~a = ~a;\n" (rs-pb-elem-type model key-f) (rs-pb-default model (hash-set key-f 'label 1)) (rs-pb-elem-type model val-f)
           (if (= (hash-ref val-f 'type) 11)
               (format "~a::default()" (rs-pb-elem-type model val-f))
               (rs-pb-default model (hash-set val-f 'label 1))))
   "    let mut r = PbReader::new(data);\n    while let Some(field) = r.next()? {\n        match field.number {\n"
   (format "            ~a => {\n~a            }\n" (hash-ref key-f 'number)
           (rs-pb-decode-singular-kv model (hash-set key-f 'label 1) "key" "field" "                "))
   (format "            ~a => {\n~a            }\n" (hash-ref val-f 'number)
           (rs-pb-decode-singular-kv model (hash-set val-f 'label 1) "value" "field" "                "))
   "            _ => {}\n        }\n    }\n    Ok((key, value))\n}\n\n"))

(define (rs-pb-decode-singular-kv model f target field indent)
  ;; Like rs-pb-decode-singular but operating on a PbField local.
  (define type (hash-ref f 'type))
  (define varint (format "~a.varint_value" field))
  (define fixed (format "~a.fixed_value" field))
  (define bytes (format "~a.bytes_value" field))
  (cond [(memv type rs-pb-varint-types)
         (format "~a~a = ~a;\n" indent target
                 (if (= type 14)
                     (format "~a::from_i32(~a as i32)" (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name))) varint)
                     (rs-pb-varint-decode f varint)))]
        [(assv type rs-pb-fixed)
         (format "~a~a = ~a;\n" indent target (rs-pb-fixed-decode-expr f fixed))]
        [(= type 9) (format "~a~a = String::from_utf8_lossy(&~a).into_owned();\n" indent target bytes)]
        [(= type 12) (format "~a~a = ~a.clone();\n" indent target bytes)]
        [(= type 11)
         (format "~a~a = ~a::decode(&~a)?;\n" indent target
                 (rs-pb-entry-ref model (rs-pb-resolve model (hash-ref f 'type-name))) bytes)]
        [else (error 'emit-rust-pb-file "unsupported map value type ~a" type)]))

(define rs-pb-support
  (string-append
   "fn pb_append_varint(out: &mut Vec<u8>, value: u64) {\n    let mut v = value;\n    while v > 0x7f {\n        out.push(((v & 0x7f) as u8) | 0x80);\n        v >>= 7;\n    }\n    out.push(v as u8);\n}\n\n"
   "fn pb_append_tag(out: &mut Vec<u8>, field: u32, wire: u32) {\n    pb_append_varint(out, ((field << 3) | wire) as u64);\n}\n\n"
   "fn pb_append_bytes_field(out: &mut Vec<u8>, field: u32, payload: &[u8]) {\n    pb_append_tag(out, field, 2);\n    pb_append_varint(out, payload.len() as u64);\n    out.extend_from_slice(payload);\n}\n\n"
   "fn pb_append_string_field(out: &mut Vec<u8>, field: u32, value: &str) {\n    if !value.is_empty() {\n        pb_append_bytes_field(out, field, value.as_bytes());\n    }\n}\n\n"
   "fn pb_append_fixed32(out: &mut Vec<u8>, value: u32) {\n    out.extend_from_slice(&value.to_le_bytes());\n}\n\n"
   "fn pb_append_fixed64(out: &mut Vec<u8>, value: u64) {\n    out.extend_from_slice(&value.to_le_bytes());\n}\n\n"
   "#[derive(Clone, Debug, Default)]\nstruct PbField {\n    number: u32,\n    wire: u32,\n    varint_value: u64,\n    bytes_value: Vec<u8>,\n    fixed_value: u64,\n    raw_value: Vec<u8>,\n}\n\n"
   "struct PbReader<'a> {\n    buf: &'a [u8],\n    pos: usize,\n}\n\n"
   "impl<'a> PbReader<'a> {\n    fn new(buf: &'a [u8]) -> Self {\n        PbReader { buf, pos: 0 }\n    }\n\n"
   "    fn done(&self) -> bool {\n        self.pos >= self.buf.len()\n    }\n\n"
   "    fn varint(&mut self) -> Result<u64, String> {\n        let mut result: u64 = 0;\n        let mut shift = 0;\n        loop {\n            if self.pos >= self.buf.len() {\n                return Err(\"truncated varint\".to_string());\n            }\n            let b = self.buf[self.pos];\n            self.pos += 1;\n            result |= ((b & 0x7f) as u64) << shift;\n            if b & 0x80 == 0 {\n                return Ok(result);\n            }\n            shift += 7;\n            if shift >= 70 {\n                return Err(\"varint too long\".to_string());\n            }\n        }\n    }\n\n"
   "    fn take(&mut self, n: usize) -> Result<Vec<u8>, String> {\n        if self.pos + n > self.buf.len() {\n            return Err(\"truncated field\".to_string());\n        }\n        let v = self.buf[self.pos..self.pos + n].to_vec();\n        self.pos += n;\n        Ok(v)\n    }\n\n"
   "    fn next(&mut self) -> Result<Option<PbField>, String> {\n        if self.done() {\n            return Ok(None);\n        }\n        let start = self.pos;\n        let tag = self.varint()?;\n        let mut field = PbField {\n            number: (tag >> 3) as u32,\n            wire: (tag & 7) as u32,\n            ..Default::default()\n        };\n        match field.wire {\n            0 => field.varint_value = self.varint()?,\n            2 => {\n                let n = self.varint()? as usize;\n                field.bytes_value = self.take(n)?;\n            }\n            1 => {\n                field.bytes_value = self.take(8)?;\n                field.fixed_value = u64::from_le_bytes(field.bytes_value[..8].try_into().unwrap());\n            }\n            5 => {\n                field.bytes_value = self.take(4)?;\n                field.fixed_value = u32::from_le_bytes(field.bytes_value[..4].try_into().unwrap()) as u64;\n            }\n            _ => return Err(\"bad wire type\".to_string()),\n        }\n        field.raw_value = self.buf[start..self.pos].to_vec();\n        Ok(Some(field))\n    }\n}\n\n"))

(define (rs-pb-message-struct model msg)
  (define name (rs-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))
  (define fields (hash-ref msg 'fields))
  (string-append
   (apply string-append
          (map (lambda (e)
                 (rs-pb-enum-named model (format "~a.~a" (hash-ref msg 'full-name) (hash-ref e 'name)) e))
               (hash-ref msg 'enums)))
   (format "#[derive(Clone, Debug, PartialEq)]\npub struct ~a {\n" name)
   (apply string-append
          (map (lambda (f) (format "    pub ~a: ~a,\n" (rs-pb-field-name f) (rs-pb-type model f))) fields))
   "    pub unknown_fields: Vec<u8>,\n}\n\n"
   (format "impl Default for ~a {\n    fn default() -> Self {\n        Self {\n" name)
   (apply string-append
          (map (lambda (f) (format "            ~a: ~a,\n" (rs-pb-field-name f) (rs-pb-default model f))) fields))
   "            unknown_fields: Vec::new(),\n        }\n    }\n}\n\n"
   (format "impl ~a {\n    pub fn encode(&self) -> Vec<u8> {\n        let mut out = Vec::new();\n" name)
   (apply string-append (map (lambda (f) (rs-pb-encode-guard model f (rs-pb-encode-field model f))) fields))
   "        out.extend_from_slice(&self.unknown_fields);\n"
   ;; (nested enums are emitted alongside their message below)
   "        out\n    }\n\n"
   "    pub fn decode(bytes: &[u8]) -> Result<Self, String> {\n        let mut msg = Self::default();\n        let mut reader = PbReader::new(bytes);\n        while let Some(field) = reader.next()? {\n            match field.number {\n"
   (apply string-append (map (lambda (f) (rs-pb-decode-case model f)) fields))
   "                _ => {\n                    msg.unknown_fields.extend_from_slice(&field.raw_value);\n                }\n"
   "            }\n        }\n        Ok(msg)\n    }\n}\n\n"
   (apply string-append (map (lambda (n) (rs-pb-message-struct model n)) (hash-ref msg 'nested)))))

(define (rs-pb-enum model e)
  (rs-pb-enum-named model
                    (if (string=? (hash-ref model 'package) "")
                        (hash-ref e 'name)
                        (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name)))
                    e))

(define (rs-pb-enum-named model full e)
  (define name (rs-pb-flat (hash-ref model 'package) full))
  (define values (hash-ref e 'values))
  (string-append
   (format "#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]\npub enum ~a {\n" name)
   (apply string-append
          (map (lambda (v i)
                 (format "    ~a~a = ~a,\n" (if (zero? i) "#[default]\n    " "") (rs-pb-camel (hash-ref v 'name)) (hash-ref v 'number)))
               values (range (length values))))
   "}\n\n"
   (format "impl ~a {\n    pub fn from_i32(v: i32) -> Self {\n        match v {\n" name)
   (apply string-append
          (map (lambda (v) (format "            ~a => ~a::~a,\n" (hash-ref v 'number) name (rs-pb-camel (hash-ref v 'name))))
               values))
   (format "            _ => ~a::~a,\n        }\n    }\n}\n\n" name (rs-pb-camel (hash-ref (car values) 'name)))))

(define (emit-rust-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-rust-pb-file/inner file-model)))

(define (emit-rust-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (rs-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (rs-pb-map-helpers file-model e) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define content
           (string-append
            "// @generated by protoc-gen-grpc-dc-rust. DO NOT EDIT.\n"
            (format "// source: ~a\n" (hash-ref file-model 'name))
            "// Cross-file message types resolve to crate::<base>_pb modules.\n"
            "#![allow(dead_code, clippy::all)]\n\n"
            (if (current-rust-no-std)
                "extern crate alloc;\nuse alloc::{boxed::Box, collections::BTreeMap, string::{String, ToString}, vec::Vec};\n\n"
                "")
            rs-pb-support
            (apply string-append (map (lambda (e) (rs-pb-enum file-model e)) enums))
            (apply string-append
                   (map (lambda (m) (rs-pb-message-struct file-model m))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            (apply string-append (reverse helpers))))
         (cons (string-append base "_pb.rs") content))))

(define (emit-rust-file file-model params)
  (define msgmod (hash-ref params 'message_module "crate::pb"))
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define stub
    (cons (string-append base "_grpc_dc.rs")
          (string-append
           "// @generated by protoc-gen-grpc-dc-rust. DO NOT EDIT.\n"
           (format "// source: ~a\n" (hash-ref file-model 'name))
           "#![allow(dead_code, unused_imports, clippy::all)]\n\n"
           ;; trace=hooks: re-export the tracer registrar from the
           ;; runtime; trace_methods bakes via a lazy static.
           (if (equal? (hash-ref params 'trace #f) "hooks")
               (string-append
                "/// Tracing (trace=hooks): register an observer via `set_tracer`.\n"
                "pub use ::grpc_dc::status::{set_tracer, set_trace_filter};\n\n"
                (let ([methods (hash-ref params 'trace_methods #f)])
                  (if methods
                      (format "/// Apply the baked-in trace filter (trace_methods).\n/// Idempotent; call once at startup.\npub fn apply_trace_filter() {\n    ::grpc_dc::status::set_trace_filter(~s);\n}\n\n" methods)
                      "")))
               "")
           (apply string-append
                  (map (lambda (s) (rust-service s msgmod))
                       (hash-ref file-model 'services))))))
  (define pb-file
    (parameterize ([current-rust-no-std
                    (member (hash-ref params 'rust_no_std "false") '("true" "1"))])
      (emit-rust-pb-file file-model)))
  (if pb-file (list stub pb-file) stub))
