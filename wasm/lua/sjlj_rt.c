/* Wasm EH setjmp/longjmp runtime helpers called by LLVM's
 * WebAssemblyLowerEmscriptenEHSjLj pass (ABI per WebAssembly
 * tool-conventions SetjmpLongjmp.md); zig's wasi-libc does not
 * ship these, so provide them in-module. */
#include <stddef.h>
#include <stdint.h>

struct jmp_buf_impl {
    void *func_invocation_id;
    uint32_t label;
    struct arg {
        void *env;
        int val;
    } arg;
};

void __wasm_setjmp(void *env, uint32_t label, void *func_invocation_id) {
    struct jmp_buf_impl *jb = env;
    if (label == 0 || func_invocation_id == NULL) __builtin_trap();
    jb->func_invocation_id = func_invocation_id;
    jb->label = label;
}

uint32_t __wasm_setjmp_test(void *env, void *func_invocation_id) {
    struct jmp_buf_impl *jb = env;
    if (jb->label == 0 || func_invocation_id == NULL) __builtin_trap();
    if (jb->func_invocation_id == func_invocation_id) return jb->label;
    return 0;
}

void __wasm_longjmp(void *env, int val) {
    struct jmp_buf_impl *jb = env;
    if (val == 0) val = 1;
    jb->arg.env = env;
    jb->arg.val = val;
    __builtin_wasm_throw(1, &jb->arg); /* 1 == C_LONGJMP tag */
}
