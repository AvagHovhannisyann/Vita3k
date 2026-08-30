// CoreStub.c — placeholder implementations of the native Vita3K core entry
// points, used for the UI-preview build. When the real Vita3K core library is
// linked in, it provides the strong versions of these symbols instead (and its
// vita3k_ios_present() returns 1), and this file is dropped from the build.
#include <stdint.h>

int vita3k_ios_present(void) { return 0; }                 // 0 = core not linked
const char *vita3k_ios_version(void) { return "front-end preview — core not linked"; }
int  vita3k_ios_boot(const char *title_id, void *metal_layer) { (void)title_id; (void)metal_layer; return -1; }
void vita3k_ios_send_buttons(uint32_t mask) { (void)mask; }
void vita3k_ios_send_analog(float lx, float ly, float rx, float ry) { (void)lx; (void)ly; (void)rx; (void)ry; }
void vita3k_ios_send_touch(unsigned long long id, float nx, float ny, int phase) {
    (void)id; (void)nx; (void)ny; (void)phase;
}
void vita3k_ios_set_touch_panel(int rear) { (void)rear; }
void vita3k_ios_shutdown(void) {}
int  vita3k_ios_install_firmware(const char *pup_path, void (*progress)(unsigned int, void *),
                                 void *ctx, char *out_version, unsigned long out_cap) {
    (void)pup_path; (void)progress; (void)ctx;
    if (out_version && out_cap) out_version[0] = 0;
    return -1;                                             // no core: nothing to install into
}
