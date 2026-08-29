// sdl_ios_stub.c — the two SDL3 platform hooks this build's libSDL3.a is
// missing for iOS: SDL_UpdateTrays (called unconditionally from
// SDL_PumpEventMaintenance, part of SDL_events.c's always-compiled event
// pump -- reached even with only SDL_INIT_AUDIO going through
// SDL_Init/SDL_PollEvent-adjacent bookkeeping) and
// SDL_SYS_ShowFileDialogWithProperties (the per-platform backend for the
// public SDL_ShowFileDialogWithProperties -- vita3k's own file pickers on
// iOS are UIDocumentPicker at the app layer, never this SDL API, but the
// dispatcher object referencing it still gets pulled in).
//
// SDL itself ships exactly this behavior already, as its "dummy" backend
// (src/tray/dummy/SDL_tray.c, src/dialog/dummy/SDL_dummydialog.c) for
// platforms with no native tray/file-dialog concept -- which iOS is. This
// file is a minimal reimplementation of those two dummy entry points
// (rather than pulling in SDL's private headers/build machinery for a
// two-function difference) so this build's libSDL3.a -- which apparently
// omitted the dummy backend for iOS specifically -- links.
#include <SDL3/SDL_dialog.h>
#include <SDL3/SDL_error.h>
#include <SDL3/SDL_tray.h>

void SDL_UpdateTrays(void) {
    // No tray on iOS; nothing to pump.
}

void SDL_DestroyTray(SDL_Tray *tray) {
    (void)tray;
}

void SDL_SYS_ShowFileDialogWithProperties(SDL_FileDialogType type, SDL_DialogFileCallback callback,
    void *userdata, SDL_PropertiesID props) {
    (void)type;
    (void)props;
    SDL_Unsupported();
    if (callback)
        callback(userdata, NULL, -1);
}
