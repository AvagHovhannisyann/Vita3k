// CoreStub.c — placeholder implementations of the native Vita3K core entry
// points, used for the UI-preview build. When the real Vita3K core library is
// linked in, it provides the strong versions of these symbols instead (and its
// vita3k_ios_present() returns 1), and this file is dropped from the build.
#include <stdint.h>

int vita3k_ios_present(void) { return 0; }                 // 0 = core not linked
const char *vita3k_ios_version(void) { return "front-end preview — core not linked"; }
int  vita3k_ios_boot(const char *title_id, void *metal_layer) { (void)title_id; (void)metal_layer; return -1; }
void vita3k_ios_send_buttons(uint32_t mask) { (void)mask; }
void vita3k_ios_shutdown(void) {}
