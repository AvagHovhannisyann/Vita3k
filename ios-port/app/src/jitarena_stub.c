// jitarena_stub.c — last-resort definitions of the JIT arena ABI.
//
// Linked LAST, from its own archive, so the native core's real implementation
// always wins when it is present (the linker only pulls an archive member to
// resolve a still-undefined symbol). If you see the status string below on
// device, the core arena is genuinely not linked in — the app says so rather
// than pretending JIT is available.
#include "JitArena.h"

int           v3k_ios_jit_init(unsigned long bytes) { (void)bytes; return V3K_JIT_NO_IMPL; }
int           v3k_ios_jit_ready(void)   { return 0; }
void         *v3k_ios_jit_rx(void)      { return 0; }
void         *v3k_ios_jit_rw(void)      { return 0; }
unsigned long v3k_ios_jit_size(void)    { return 0; }
unsigned long v3k_ios_jit_used(void)    { return 0; }
void          v3k_ios_jit_flush(void)   {}
const char   *v3k_ios_jit_status(void)  { return "no arena implementation linked (stub)"; }
