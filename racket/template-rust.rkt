#lang racket

;;; template-rust.rkt — emitter body spliced into protoc-gen-grpc-dc-rust.
;;; (metagen.rkt strips the #lang / #require / #provide lines and inlines
;;;  this body into the generated plugin, after spec/pb/desc bodies.)
;;;
;;; Generated code assumes the runtime crate is named `grpc_dc` and that
;;; protobuf message types live in the module named by the protoc plugin
;;; parameter `message_module` (default `crate::pb`), each implementing
;;; `grpc_dc::Message`.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-rust-file)

(define (rust-deprecated m indent)
  (run-segments rust-deprecated-program m "" #f (list indent)))
(define (rust-client-method m msgmod)
  (run-segments rust-client-method-program m "" #f (list msgmod)))
(define (rust-client-options-method m msgmod)
  (run-segments rust-client-options-method-program m "" #f (list msgmod)))
(define (rust-trait-method/deprecated m msgmod)
  (run-segments rust-trait-method-deprecated-program m "" #f (list msgmod)))
(define (rust-trait-method m msgmod)
  (run-segments rust-trait-method-program m "" #f (list msgmod)))
(define (rust-register-method m service-var)
  (run-segments rust-register-method-program m "" #f (list service-var)))
(define (rust-service svc msgmod)
  (run-segments rust-service-program svc (hash-ref svc 'name) #f (list msgmod)))
(define (rs-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-rust-pb-file "unresolved type ~a" type-name))))

(define (rs-pb-elem-type model f)
  (run-segments rs-pb-elem-type-program f "" model))
(define current-rust-no-std (make-parameter #f))
(define current-rust-struct-codec (make-parameter #f))

(define (rs-pb-type model f)
  (run-segments rs-pb-type-program f "" model))
(define (rs-pb-default model f)
  (run-segments rs-pb-default-program f "" model))
(define (rs-pb-varint-expr f v)
  (run-segments rs-pb-varint-expr-program f "" #f (list v)))
(define (rs-pb-varint-decode f v)
  (run-segments rs-pb-varint-decode-program f "" #f (list v)))
(define (rs-pb-encode-singular model f v indent)
  (run-segments rs-pb-encode-singular-program f "" model (list v indent)))
(define (rs-pb-encode-field model f)
  (run-segments rs-pb-encode-field-program f "" model))
(define (rs-pb-decode-singular model f target src indent)
  (run-segments rs-pb-decode-singular-program f "" model (list target src indent)))
(define (rs-pb-oneof-clearing model f)
  (run-segments rs-pb-oneof-clearing-program f "" model))
(define (rs-pb-decode-case model f)
  (run-segments rs-pb-decode-case-program f "" model))
(define (rs-pb-map-helpers model entry)
  (run-segments rs-pb-map-helpers-program entry "" model))
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
  (run-segments rs-pb-message-program msg "" model))
(define (rs-pb-enum model e)
  (run-segments rs-pb-enum-named-program e "" model
                (list (if (string=? (hash-ref model 'package) "")
                          (hash-ref e 'name)
                          (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name))))))
(define (rs-pb-enum-named model full e)
  (run-segments rs-pb-enum-named-program e "" model (list full)))
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
            (if (current-rust-struct-codec)
                (string-append
                 "fn struct_check(bytes: &[u8], off: usize, n: usize) -> Result<(), String> {\n    if off.checked_add(n).map_or(true, |end| end > bytes.len()) { return Err(\"struct codec: out of bounds\".to_string()); }\n    Ok(())\n}\n\n"
                 (apply string-append
                        (map (lambda (m) (rs-struct-message file-model m))
                             (filter (lambda (m) (not (hash-ref m 'map-entry))) messages))))
                "")
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
                "/// Tracing (trace=hooks@@TRACING_BETA@@): register an observer via `set_tracer`.\n"
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
                    (member (hash-ref params 'rust_no_std "false") '("true" "1"))]
                   [seg-rust-no-std
                    (member (hash-ref params 'rust_no_std "false") '("true" "1"))]
                   [current-rust-struct-codec
                    (equal? (hash-ref params 'struct_codec #f) "true")])
      (emit-rust-pb-file file-model)))
  (if pb-file (list stub pb-file) stub))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): same packed layout as the Go
;; struct codec (see template-go.rkt), so Go and Rust transcode
;; byte-identically. Inherent methods per message:
;; marshal_struct / unmarshal_struct.
(define (rs-struct-type-name model full)
  (define pkg (hash-ref model 'package))
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (rs-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (rs-struct-varint-type? t) (member t '(3 4 5 8 13 14 17 18)))
(define (rs-struct-fixed32-type? t) (member t '(2 7 15)))
(define (rs-struct-fixed64-type? t) (member t '(1 6 16)))

(define (rs-struct-slot-size f)
  (define t (hash-ref f 'type))
  (cond [(rs-struct-varint-type? t) 8]
        [(rs-struct-fixed32-type? t) 4]
        [(rs-struct-fixed64-type? t) 8]
        [else 8]))

(define (rs-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (rs-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (rs-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (rs-struct-map-key-field model f)
  (define em (hash-ref (rs-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (rs-struct-map-val-field model f)
  (define em (hash-ref (rs-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (rs-struct-present f fn)
  (define t (hash-ref f 'type))
  (cond [(= (hash-ref f 'label) 3) (format "!self.~a.is_empty()" fn)]
        [(= t 11) (format "self.~a.is_some()" fn)]
        [(member t '(9 12)) (format "!self.~a.is_empty()" fn)]
        [(= t 8) (format "self.~a" fn)]
        [(= t 14) (format "self.~a.to_i32() != 0" fn)]
        [(member t '(1 2)) (format "self.~a != 0.0" fn)]
        [else (format "self.~a != 0" fn)]))

(define (rs-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(rs-struct-fixed32-type? t)
         (if (= t 2)
             (format "buf[off..off + 4].copy_from_slice(&~a.to_bits().to_le_bytes());" v)
             (format "buf[off..off + 4].copy_from_slice(&(~a as u32).to_le_bytes());" v))]
        [(rs-struct-fixed64-type? t)
         (if (= t 1)
             (format "buf[off..off + 8].copy_from_slice(&~a.to_bits().to_le_bytes());" v)
             (format "buf[off..off + 8].copy_from_slice(&(~a as u64).to_le_bytes());" v))]
        [(= t 8) (format "if ~a { buf[off] = 1; }" v)]
        [(= t 14) (format "buf[off..off + 8].copy_from_slice(&(~a.to_i32() as i64 as u64).to_le_bytes());" v)]
        [else (format "buf[off..off + 8].copy_from_slice(&(~a as i64 as u64).to_le_bytes());" v)]))

(define (rs-struct-scalar-decode model f target)
  (define t (hash-ref f 'type))
  (cond [(rs-struct-fixed32-type? t)
         (if (= t 2)
             (format "~a = f32::from_bits(u32::from_le_bytes(bytes[off..off + 4].try_into().unwrap()));" target)
             (format "~a = u32::from_le_bytes(bytes[off..off + 4].try_into().unwrap()) as ~a;" target
                     (rs-pb-elem-type model f)))]
        [(rs-struct-fixed64-type? t)
         (if (= t 1)
             (format "~a = f64::from_bits(u64::from_le_bytes(bytes[off..off + 8].try_into().unwrap()));" target)
             (format "~a = u64::from_le_bytes(bytes[off..off + 8].try_into().unwrap()) as ~a;" target
                     (rs-pb-elem-type model f)))]
        [(= t 8) (format "~a = bytes[off] != 0;" target)]
        [(= t 14) (format "~a = ~a::from_i32(u64::from_le_bytes(bytes[off..off + 8].try_into().unwrap()) as i64 as i32);" target
                        (rs-pb-elem-type model f))]
        [else (format "~a = u64::from_le_bytes(bytes[off..off + 8].try_into().unwrap()) as ~a;" target
                      (rs-pb-elem-type model f))]))

(define (rs-struct-value-size model f v)
  (define t (hash-ref f 'type))
  (cond [(member t '(9 12)) (format "~a.len()" v)]
        [(= t 11) (format "match &~a { Some(x) => x.struct_size(), None => 0 }" v)]
        [(rs-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (rs-struct-value-write model f v)
  (define t (hash-ref f 'type))
  (cond [(member t '(9 12)) (format "buf[vp..vp + ~a.len()].copy_from_slice(~a); vp += ~a.len();" v
                                    (if (= t 9) (format "&~a.as_bytes()" v) (format "&~a" v)) v)]
        [(= t 11) (format "if let Some(x) = &~a { let b = x.marshal_struct(); buf[vp..vp + b.len()].copy_from_slice(&b); vp += b.len(); }" v)]
        [else (format "~a vp += ~a;" (rs-struct-scalar-write-at f v "vp")
                      (if (rs-struct-fixed32-type? t) 4 8))]))

(define (rs-struct-scalar-write-at f v at)
  (define t (hash-ref f 'type))
  (cond [(rs-struct-fixed32-type? t)
         (if (= t 2)
             (format "buf[~a..~a + 4].copy_from_slice(&~a.to_bits().to_le_bytes());" at at v)
             (format "buf[~a..~a + 4].copy_from_slice(&(~a as u32).to_le_bytes());" at at v))]
        [(rs-struct-fixed64-type? t)
         (if (= t 1)
             (format "buf[~a..~a + 8].copy_from_slice(&~a.to_bits().to_le_bytes());" at at v)
             (format "buf[~a..~a + 8].copy_from_slice(&(~a as u64).to_le_bytes());" at at v))]
        [(= t 8) (format "if ~a { buf[~a] = 1; }" v at)]
        [(= t 14) (format "buf[~a..~a + 8].copy_from_slice(&(~a.to_i32() as i64 as u64).to_le_bytes());" at at v)]
        [else (format "buf[~a..~a + 8].copy_from_slice(&(~a as i64 as u64).to_le_bytes());" at at v)]))

(define (rs-struct-message model msg)
  (apply string-append
         (cons (rs-struct-message-one model msg)
               (map (lambda (n) (rs-struct-message model n)) (hash-ref msg 'nested)))))

(define (rs-struct-message-one model msg)
  (define type-name (rs-struct-type-name model (hash-ref msg 'full-name)))
  (define fields (rs-struct-sorted-fields msg))
  (define nfields (length fields))
  (define words (max 1 (quotient (+ nfields 31) 32)))
  (define header-size (+ 12 (* 4 words)))
  (define fixed-total (apply + (map rs-struct-slot-size fields)))
  (define fixed-end (+ header-size fixed-total))
  (define (foff i)
    (+ header-size (apply + (map rs-struct-slot-size (take fields i)))))
  (define out (open-output-string))
  (fprintf out "impl ~a {\n    pub const STRUCT_FINGERPRINT: u32 = 0x~x;\n\n" type-name
           (rs-struct-fingerprint (hash-ref msg 'full-name)))
  ;; size
  (fprintf out "    fn struct_size(&self) -> usize {\n        let mut size = ~a;\n" fixed-end)
  (for ([f (in-list fields)])
    (define fn (seg-rs-field-name f))
    (define t (hash-ref f 'type))
    (cond [(rs-struct-map-entry model f)
           (define kf (rs-struct-map-key-field model f))
           (define vf (rs-struct-map-val-field model f))
           (fprintf out "        for (k, v) in &self.~a { size += 8 + ~a + ~a; }\n" fn
                    (rs-struct-value-size model kf "k")
                    (if (= (hash-ref vf 'type) 11) "v.struct_size()" (rs-struct-value-size model vf "v")))]
          [(= (hash-ref f 'label) 3)
           (cond [(member t '(9 12))
                  (fprintf out "        size += 8 * self.~a.len();\n        for e in &self.~a { size += e.len(); }\n" fn fn)]
                 [(= t 11)
                  (fprintf out "        size += 8 * self.~a.len();\n        for e in &self.~a { size += e.struct_size(); }\n" fn fn)]
                 [else
                  (fprintf out "        size += self.~a.len() * ~a;\n" fn
                           (if (rs-struct-fixed32-type? t) 4 8))])]
          [(= t 11) (fprintf out "        if let Some(v) = &self.~a { size += v.struct_size(); }\n" fn)]
          [(member t '(9 12)) (fprintf out "        size += self.~a.len();\n" fn)]
          [else (void)]))
  (fprintf out "        size += self.unknown_fields.len();\n        size\n    }\n\n")
  ;; marshal
  (fprintf out "    pub fn marshal_struct(&self) -> Vec<u8> {\n")
  (fprintf out "        let size = self.struct_size();\n        let mut buf = vec![0u8; size];\n")
  (fprintf out "        buf[0..4].copy_from_slice(b\"DCS1\");\n        buf[4..8].copy_from_slice(&(size as u32).to_le_bytes());\n")
  (fprintf out "        buf[8..12].copy_from_slice(&Self::STRUCT_FINGERPRINT.to_le_bytes());\n")
  (for ([w (in-range words)])
    (fprintf out "        let mut presence~a: u32 = 0;\n" w))
  (for ([f (in-list fields)] [i (in-naturals)])
    (fprintf out "        if ~a { presence~a |= 1 << ~a; }\n"
             (rs-struct-present f (seg-rs-field-name f)) (quotient i 32) (modulo i 32)))
  (for ([w (in-range words)])
    (fprintf out "        buf[~a..~a].copy_from_slice(&presence~a.to_le_bytes());\n"
             (+ 12 (* 4 w)) (+ 16 (* 4 w)) w))
  (fprintf out "        let mut vp = ~a;\n" fixed-end)
  (for ([f (in-list fields)] [i (in-naturals)])
    (define fn (seg-rs-field-name f))
    (define t (hash-ref f 'type))
    (define off (foff i))
    (cond [(rs-struct-map-entry model f)
           (define kf (rs-struct-map-key-field model f))
           (define vf (rs-struct-map-val-field model f))
           (fprintf out "        if !self.~a.is_empty() {\n            buf[~a..~a].copy_from_slice(&(vp as u32).to_le_bytes());\n            buf[~a..~a].copy_from_slice(&(self.~a.len() as u32).to_le_bytes());\n"
                    fn off (+ off 4) (+ off 4) (+ off 8) fn)
           (fprintf out "            let mut keys: Vec<&~a> = self.~a.keys().collect();\n            keys.sort();\n"
                    (rs-pb-type model (hash-set kf 'label 1)) fn)
           (fprintf out "            for k in keys {\n                let v = &self.~a[k];\n                buf[vp..vp + 4].copy_from_slice(&(~a as u32).to_le_bytes());\n                buf[vp + 4..vp + 8].copy_from_slice(&(~a as u32).to_le_bytes());\n                vp += 8;\n                ~a\n                ~a\n            }\n        }\n"
                    fn (rs-struct-value-size model kf "k")
                    (if (= (hash-ref vf 'type) 11) "v.struct_size()" (rs-struct-value-size model vf "v"))
                    (if (member (hash-ref kf 'type) '(9 12))
                        (rs-struct-value-write model kf "k")
                        (format "~a vp += ~a;" (rs-struct-scalar-write-at kf "(*k)" "vp")
                                (if (rs-struct-fixed32-type? (hash-ref kf 'type)) 4 8)))
                    (if (= (hash-ref vf 'type) 11)
                        "let b = v.marshal_struct(); buf[vp..vp + b.len()].copy_from_slice(&b); vp += b.len();"
                        (if (member (hash-ref vf 'type) '(9 12))
                            (rs-struct-value-write model vf "v")
                            (format "~a vp += ~a;" (rs-struct-scalar-write-at vf "(*v)" "vp")
                                    (if (rs-struct-fixed32-type? (hash-ref vf 'type)) 4 8)))))]
          [(= (hash-ref f 'label) 3)
           (cond [(member t '(9 12))
                  (fprintf out "        if !self.~a.is_empty() {\n            buf[~a..~a].copy_from_slice(&(vp as u32).to_le_bytes());\n            buf[~a..~a].copy_from_slice(&(self.~a.len() as u32).to_le_bytes());\n            let mut doff = vp + 8 * self.~a.len();\n            for e in &self.~a {\n                buf[vp..vp + 4].copy_from_slice(&(doff as u32).to_le_bytes());\n                buf[vp + 4..vp + 8].copy_from_slice(&(e.len() as u32).to_le_bytes());\n                doff += e.len();\n                vp += 8;\n            }\n            for e in &self.~a { buf[vp..vp + e.len()].copy_from_slice(~a); vp += e.len(); }\n        }\n"
                           fn off (+ off 4) (+ off 4) (+ off 8) fn fn fn fn
                           (if (= t 9) "e.as_bytes()" "e"))]
                 [(= t 11)
                  (fprintf out "        if !self.~a.is_empty() {\n            buf[~a..~a].copy_from_slice(&(vp as u32).to_le_bytes());\n            buf[~a..~a].copy_from_slice(&(self.~a.len() as u32).to_le_bytes());\n            let mut doff = vp + 8 * self.~a.len();\n            for e in &self.~a {\n                let es = e.struct_size();\n                buf[vp..vp + 4].copy_from_slice(&(doff as u32).to_le_bytes());\n                buf[vp + 4..vp + 8].copy_from_slice(&(es as u32).to_le_bytes());\n                doff += es;\n                vp += 8;\n            }\n            for e in &self.~a { let b = e.marshal_struct(); buf[vp..vp + b.len()].copy_from_slice(&b); vp += b.len(); }\n        }\n"
                           fn off (+ off 4) (+ off 4) (+ off 8) fn fn fn fn)]
                 [else
                  (fprintf out "        if !self.~a.is_empty() {\n            buf[~a..~a].copy_from_slice(&(vp as u32).to_le_bytes());\n            buf[~a..~a].copy_from_slice(&(self.~a.len() as u32).to_le_bytes());\n            for e in &self.~a { ~a vp += ~a; }\n        }\n"
                           fn off (+ off 4) (+ off 4) (+ off 8) fn fn
                           (rs-struct-scalar-write-at f "(*e)" "vp")
                           (if (rs-struct-fixed32-type? t) 4 8))])]
          [(= t 11)
           (fprintf out "        if let Some(v) = &self.~a {\n            buf[~a..~a].copy_from_slice(&(vp as u32).to_le_bytes());\n            buf[~a..~a].copy_from_slice(&(v.struct_size() as u32).to_le_bytes());\n            let b = v.marshal_struct();\n            buf[vp..vp + b.len()].copy_from_slice(&b);\n            vp += b.len();\n        }\n"
                    fn off (+ off 4) (+ off 4) (+ off 8))]
          [(member t '(9 12))
           (fprintf out "        if !self.~a.is_empty() {\n            buf[~a..~a].copy_from_slice(&(vp as u32).to_le_bytes());\n            buf[~a..~a].copy_from_slice(&(self.~a.len() as u32).to_le_bytes());\n            buf[vp..vp + self.~a.len()].copy_from_slice(~a);\n            vp += self.~a.len();\n        }\n"
                    fn off (+ off 4) (+ off 4) (+ off 8) fn fn
                    (if (= t 9) (format "&self.~a.as_bytes()" fn) (format "&self.~a" fn)) fn)]
          [else
           (fprintf out "        { let off = ~a; ~a }\n" off
                    (rs-struct-scalar-encode f (format "self.~a" fn)))])
    )
  (fprintf out "        buf[vp..vp + self.unknown_fields.len()].copy_from_slice(&self.unknown_fields);\n        buf\n    }\n\n")
  ;; unmarshal
  (fprintf out "    pub fn unmarshal_struct(bytes: &[u8]) -> Result<Self, String> {\n")
  (fprintf out "        if bytes.len() < ~a || &bytes[0..4] != b\"DCS1\" { return Err(\"struct codec: bad header\".to_string()); }\n" header-size)
  (fprintf out "        if u32::from_le_bytes(bytes[8..12].try_into().unwrap()) != Self::STRUCT_FINGERPRINT { return Err(\"struct codec: schema fingerprint mismatch\".to_string()); }\n")
  (fprintf out "        if u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize != bytes.len() { return Err(\"struct codec: length mismatch\".to_string()); }\n")
  (fprintf out "        let mut msg = Self::default();\n        let mut vend = ~a;\n" fixed-end)
  (for ([f (in-list fields)] [i (in-naturals)])
    (fprintf out "        if u32::from_le_bytes(bytes[~a..~a].try_into().unwrap()) & (1 << ~a) != 0 {\n"
             (+ 12 (* 4 (quotient i 32))) (+ 16 (* 4 (quotient i 32))) (modulo i 32))
    (display (rs-struct-decode-field model f (seg-rs-field-name f) (foff i)) out)
    (fprintf out "        }\n"))
  (fprintf out "        if vend < bytes.len() { msg.unknown_fields = bytes[vend..].to_vec(); }\n")
  (fprintf out "        Ok(msg)\n    }\n}\n\n")
  (get-output-string out))

(define (rs-struct-decode-field model f fn foff)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define slot (format "u32::from_le_bytes(bytes[~a..~a].try_into().unwrap()) as usize" foff (+ foff 4)))
  (define slot4 (format "u32::from_le_bytes(bytes[~a..~a].try_into().unwrap()) as usize" (+ foff 4) (+ foff 8)))
  (cond
    [(rs-struct-map-entry model f)
     (define kf (rs-struct-map-key-field model f))
     (define vf (rs-struct-map-val-field model f))
     (define kt (rs-pb-elem-type model (hash-set kf 'label 1)))
     (define vt (if (= (hash-ref vf 'type) 11)
                    (rs-struct-type-name model (hash-ref vf 'type-name))
                    (rs-pb-elem-type model (hash-set vf 'label 1))))
     (fprintf out "            let off = ~a;\n            let n = ~a;\n" slot slot4)
     (fprintf out "            let mut p = off;\n")
     (fprintf out "            for _ in 0..n {\n")
     (fprintf out "                struct_check(bytes, p, 8)?;\n")
     (fprintf out "                let kl = u32::from_le_bytes(bytes[p..p + 4].try_into().unwrap()) as usize;\n")
     (fprintf out "                let vl = u32::from_le_bytes(bytes[p + 4..p + 8].try_into().unwrap()) as usize;\n")
     (fprintf out "                p += 8;\n                struct_check(bytes, p, kl + vl)?;\n")
     (fprintf out "                let mut k: ~a = Default::default();\n                { let off = p; ~a }\n" kt (rs-struct-value-read model kf "k" "kl"))
     (fprintf out "                let mut v: ~a = Default::default();\n                { let off = p + kl; ~a }\n" vt (rs-struct-value-read model vf "v" "vl"))
     (fprintf out "                msg.~a.insert(k, v);\n                p += kl + vl;\n            }\n" fn)
     (fprintf out "            if p > vend { vend = p; }\n")]
    [(= (hash-ref f 'label) 3)
     (fprintf out "            let off = ~a;\n            let n = ~a;\n" slot slot4)
     (cond
       [(member t '(9 12))
        (fprintf out "            for idx in 0..n {\n")
        (fprintf out "                let eo = u32::from_le_bytes(bytes[off + 8 * idx..off + 8 * idx + 4].try_into().unwrap()) as usize;\n")
        (fprintf out "                let el = u32::from_le_bytes(bytes[off + 8 * idx + 4..off + 8 * idx + 8].try_into().unwrap()) as usize;\n")
        (fprintf out "                struct_check(bytes, eo, el)?;\n")
        (fprintf out "                msg.~a.push(~a);\n" fn
                 (if (= t 9)
                     "String::from_utf8_lossy(&bytes[eo..eo + el]).into_owned()"
                     "bytes[eo..eo + el].to_vec()"))
        (fprintf out "                if eo + el > vend { vend = eo + el; }\n            }\n")]
       [(= t 11)
        (fprintf out "            for idx in 0..n {\n")
        (fprintf out "                let eo = u32::from_le_bytes(bytes[off + 8 * idx..off + 8 * idx + 4].try_into().unwrap()) as usize;\n")
        (fprintf out "                let el = u32::from_le_bytes(bytes[off + 8 * idx + 4..off + 8 * idx + 8].try_into().unwrap()) as usize;\n")
        (fprintf out "                if el > 0 {\n")
        (fprintf out "                    struct_check(bytes, eo, el)?;\n")
        (fprintf out "                    msg.~a.push(~a::unmarshal_struct(&bytes[eo..eo + el])?);\n" fn
                 (rs-struct-type-name model (hash-ref f 'type-name)))
        (fprintf out "                    if eo + el > vend { vend = eo + el; }\n                }\n            }\n")]
       [else
        (define esz (if (rs-struct-fixed32-type? t) 4 8))
        (fprintf out "            struct_check(bytes, off, n * ~a)?;\n" esz)
        (fprintf out "            for idx in 0..n {\n")
        (fprintf out "                let off = off + idx * ~a;\n" esz)
        (fprintf out "                let mut v: ~a = Default::default();\n" (rs-pb-elem-type model f))
        (fprintf out "                ~a\n" (rs-struct-scalar-decode model f "v"))
        (fprintf out "                msg.~a.push(v);\n" fn)
        (fprintf out "            }\n")
        (fprintf out "            if off + n * ~a > vend { vend = off + n * ~a; }\n" esz esz)])]
    [(= t 11)
     (fprintf out "            let off = ~a;\n            let el = ~a;\n" slot slot4)
     (fprintf out "            struct_check(bytes, off, el)?;\n")
     (fprintf out "            msg.~a = Some(Box::new(~a::unmarshal_struct(&bytes[off..off + el])?));\n" fn
              (rs-struct-type-name model (hash-ref f 'type-name)))
     (fprintf out "            if off + el > vend { vend = off + el; }\n")]
    [(member t '(9 12))
     (fprintf out "            let off = ~a;\n            let el = ~a;\n" slot slot4)
     (fprintf out "            struct_check(bytes, off, el)?;\n")
     (if (= t 9)
         (fprintf out "            msg.~a = String::from_utf8_lossy(&bytes[off..off + el]).into_owned();\n" fn)
         (fprintf out "            msg.~a = bytes[off..off + el].to_vec();\n" fn))
     (fprintf out "            if off + el > vend { vend = off + el; }\n")]
    [else
     (fprintf out "            let off = ~a;\n" foff)
     (fprintf out "            ~a\n" (rs-struct-scalar-decode model f (format "msg.~a" fn)))])
  (get-output-string out))

(define (rs-struct-value-read model f target lenvar)
  (define t (hash-ref f 'type))
  (cond [(member t '(9 12))
         (format "~a = ~a;" target
                 (if (= t 9)
                     (format "String::from_utf8_lossy(&bytes[off..off + ~a]).into_owned()" lenvar)
                     (format "bytes[off..off + ~a].to_vec()" lenvar)))]
        [(= t 11)
         (format "if ~a > 0 { ~a = ~a::unmarshal_struct(&bytes[off..off + ~a])?; }" lenvar target
                 (rs-struct-type-name model (hash-ref f 'type-name)) lenvar)]
        [else (rs-struct-scalar-decode model f target)]))
