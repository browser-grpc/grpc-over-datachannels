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
                    (member (hash-ref params 'rust_no_std "false") '("true" "1"))]
                   [seg-rust-no-std
                    (member (hash-ref params 'rust_no_std "false") '("true" "1"))])
      (emit-rust-pb-file file-model)))
  (if pb-file (list stub pb-file) stub))
