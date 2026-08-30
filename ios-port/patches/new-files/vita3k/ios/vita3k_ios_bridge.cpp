// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

// vita3k_ios_bridge.cpp — the iOS equivalent of the Android app's JNI layer
// (vita3k/android/jni/, especially native_bootstrap.cpp's
// initialize_session() and main_android.cpp's per-title launch sequence).
// It boots the emulator core as a library linked directly into the app, the
// same way the Android build does (there is no desktop Qt main() in this
// picture), and exposes the small C ABI that ios-port/app/src/Vita3KCore.m
// already calls:
//
//   vita3k_ios_present / vita3k_ios_version / vita3k_ios_boot /
//   vita3k_ios_send_buttons / vita3k_ios_shutdown
//
// This is a plain .cpp, NOT .mm: it includes vita3k core headers (which pull
// in mem/include/mem/ptr.h's `class Ptr`) and must never also see
// <Foundation/Foundation.h> in the same translation unit -- see the big
// comment at the top of ios_bridge_apple.mm for why (MacTypes.h's
// `typedef char *Ptr` vs. this codebase's `class Ptr`, both at global scope).
// Anything that needs an actual Apple API call (path lookup, CAMetalLayer
// inspection) is delegated to the small extern "C" helpers in
// ios_bridge_apple.mm instead.
//
// STATUS: first cut. This compiles and links against the real core (see the
// link report next to this file) and drives it through the same
// app::init -> AppSessionController -> renderer::init sequence the Android
// bridge uses, but a lot is deliberately minimal for a first pass:
//   - Only the Vulkan/MoltenVK renderer path is exercised (SDL video is never
//     initialized -- the CAMetalLayer comes from the host app, not from an
//     SDL window, mirroring how AndroidDisplayHandle carries a pre-resolved
//     SDL_Window rather than deriving one).
//   - SDL is initialized for SDL_INIT_AUDIO only (the default audio backend,
//     Config::CurrentConfig::audio_backend, is "SDL"). Gamepad/haptic/sensor
//     SDL subsystems are NOT started; physical-controller and motion input
//     are out of scope here and are a follow-up (see the link report's next
//     steps) -- button state comes solely from vita3k_ios_send_buttons.
//   - Analog sticks and touch are not wired up yet (Vita3KCore's
//     sendLeftStickX:/sendRightStickX:/sendTouchFront: are no-ops on the
//     Objective-C side already).
//   - No user account flow beyond app::ensure_current_user's default.
#include <app/functions.h>
#include <app/session_controller.h>
#include <config/functions.h>
#include <config/state.h>
#include <config/version.h>
#include <ctrl/state.h>
#include <emuenv/app_launch_request.h>
#include <emuenv/state.h>
#include <modules/module_parent.h>
#include <archive.h>
#include <packages/functions.h>
#include <touch/functions.h>
#include <touch/state.h>
#include <renderer/frame_host.h>
#include <renderer/functions.h>
#include <util/exit_code.h>
#include <util/fs.h>
#include <util/log.h>

#include <SDL3/SDL.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

// Implemented in ios_bridge_apple.mm -- see that file's header comment for
// why this can't just be `#import`-ed here.
extern "C" {
char *ios_bridge_copy_documents_vita3k_path(void);
char *ios_bridge_copy_bundle_resource_path(void);
void ios_bridge_metal_drawable_size(void *metal_layer, int *out_w, int *out_h);
}

namespace {

// ---------------------------------------------------------------------
// FrameHost: hands the host app's CAMetalLayer to the renderer through
// renderer::IOSDisplayHandle (renderer/include/renderer/frame_host.h). This
// is the iOS analogue of AndroidFrameHost in android/jni/main_android.cpp --
// where that one wraps an SDL_Window it created itself, this one wraps a
// CAMetalLayer* the host app already owns and keeps drawing into
// independently of anything SDL-related. It reaches the actual Objective-C
// object only through ios_bridge_metal_drawable_size() (see the top-of-file
// comment on why this file can't touch Foundation/QuartzCore directly).
class IOSFrameHost final : public renderer::FrameHost {
public:
    explicit IOSFrameHost(void *metal_layer)
        : m_metal_layer(metal_layer) {
    }

    renderer::DisplayHandle handle() const override {
        return renderer::IOSDisplayHandle{ m_metal_layer };
    }

    int drawable_width() const override {
        int w = 960, h = 544;
        ios_bridge_metal_drawable_size(m_metal_layer, &w, &h);
        return w;
    }

    int drawable_height() const override {
        int w = 960, h = 544;
        ios_bridge_metal_drawable_size(m_metal_layer, &w, &h);
        return h;
    }

    std::vector<std::string> font_dirs() const override {
        // Best-effort: any fonts the app bundle ships (e.g. a bundled
        // substitute for the PS Vita system font) live in the main bundle's
        // resource directory. Revisit once font packaging for the iOS app
        // is finalized -- this mirrors AndroidFrameHost::font_dirs()
        // returning a single well-known directory rather than a search path.
        char *resource_path = ios_bridge_copy_bundle_resource_path();
        if (!resource_path)
            return {};
        std::string path = resource_path;
        std::free(resource_path);
        return { path + "/" };
    }

    // No GL context of any kind on this path (Vulkan/MoltenVK only), so the
    // make_current/done_current/swap_buffers/set_vsync base-class no-ops are
    // correct as-is -- nothing to override here.

private:
    void *m_metal_layer = nullptr;
};

// ---------------------------------------------------------------------
// Bridge-wide session state. There is exactly one EmuEnvState / session for
// the lifetime of the process, matching how android_session_state() is a
// single global in the Android bridge (see android/jni/android_state.h/.cpp)
// -- the iOS app hosts one emulator session at a time, same as the Android
// activity does.
struct BridgeState {
    std::mutex mutex;
    Root root_paths;
    std::unique_ptr<EmuEnvState> emuenv;
    std::unique_ptr<app::AppSessionController> session_controller;
    std::unique_ptr<IOSFrameHost> frame_host;
    std::thread run_thread;
    std::atomic<bool> one_time_init_done{ false };
    std::atomic<bool> paths_logging_done{ false };
};

BridgeState &bridge_state() {
    static BridgeState state;
    return state;
}

// One-time process-wide setup: build Root paths under Documents/vita3k,
// bring up logging, construct EmuEnvState + Config, run app::init, enumerate
// the (single, on-device) Vulkan adapter, register HLE modules, and scan the
// apps list -- the iOS equivalent of
// android/jni/native_bootstrap.cpp's initialize_session() +
// prepare_frontend_runtime(). Must be called with bridge_state().mutex held.
// Just the paths and logging: enough to install firmware or inspect the data
// tree, without standing up a whole EmuEnvState. Firmware install must NOT
// depend on the full init, because part of that init (loading users, scanning
// apps) is what firmware is a prerequisite for -- requiring it would be a
// chicken-and-egg. Must be called with bridge_state().mutex held.
bool paths_logging_init_locked(BridgeState &state) {
    if (state.paths_logging_done.load(std::memory_order_acquire))
        return true;

    char *data_root_c = ios_bridge_copy_documents_vita3k_path();
    if (!data_root_c)
        return false;
    const fs::path data_root = fs_utils::utf8_to_path(std::string(data_root_c));
    std::free(data_root_c);

    // static_assets_path: point at the app bundle's resource dir (the iOS
    // stand-in for "the directory the desktop exe ships next to", which is
    // where app::init_paths() points static_assets_path on every other
    // platform). Everything else lives under Documents/vita3k so it
    // survives app updates and is visible to the front end / Files app.
    char *bundle_resource_path_c = ios_bridge_copy_bundle_resource_path();
    const fs::path static_assets_path = bundle_resource_path_c
        ? fs_utils::utf8_to_path(std::string(bundle_resource_path_c))
        : fs::path{};
    std::free(bundle_resource_path_c);

    state.root_paths.set_static_assets_path(static_assets_path);
    state.root_paths.set_vita_fs_path(data_root);
    state.root_paths.set_log_path(data_root);
    state.root_paths.set_config_path(data_root);
    state.root_paths.set_shared_path(data_root);
    state.root_paths.set_cache_path(data_root / "cache" / "");
    state.root_paths.set_patch_path(data_root / "patch" / "");

    boost::system::error_code ec;
    fs::create_directories(state.root_paths.get_vita_fs_path(), ec);
    fs::create_directories(state.root_paths.get_cache_path(), ec);
    fs::create_directories(state.root_paths.get_log_path() / "shaderlog", ec);
    fs::create_directories(state.root_paths.get_log_path() / "texturelog", ec);
    fs::create_directories(state.root_paths.get_patch_path(), ec);
    fs::create_directories(state.root_paths.get_shared_path() / "textures", ec);

    if (logging::init(state.root_paths, true) != Success)
        return false;

    LOG_INFO("{}", window_title);
    LOG_INFO("iOS bridge: data root '{}'", data_root);

    state.paths_logging_done.store(true, std::memory_order_release);
    return true;
}

bool one_time_init_locked(BridgeState &state) {
    if (state.one_time_init_done.load(std::memory_order_acquire))
        return true;
    if (!paths_logging_init_locked(state))
        return false;

    boost::system::error_code ec;

    if (!SDL_Init(SDL_INIT_AUDIO)) {
        LOG_ERROR("SDL_Init(SDL_INIT_AUDIO) failed: {}", SDL_GetError());
        // Not fatal on its own -- the SDL audio backend will simply fail to
        // open a device later and the title runs silent. Keep going.
    }

    state.emuenv = std::make_unique<EmuEnvState>();

    Config cfg{};
    char arg0[] = "vita3k";
    char *argv[] = { arg0, nullptr };
    if (config::init_config(cfg, 1, argv, state.root_paths, false) != Success) {
        LOG_ERROR("Failed to initialize config.");
        state.emuenv.reset();
        return false;
    }

    fs::create_directories(cfg.get_vita_fs_path(), ec);

    if (!app::init(*state.emuenv, cfg, state.root_paths)) {
        LOG_ERROR("Failed to initialize emulated environment.");
        state.emuenv.reset();
        return false;
    }

    state.emuenv->vulkan_device_info = std::make_unique<renderer::VulkanDeviceInfo>(renderer::enumerate_vulkan_devices());

    if (state.emuenv->cfg.controller_binds.empty() || state.emuenv->cfg.controller_binds.size() != 15
        || state.emuenv->cfg.controller_axis_binds.empty() || state.emuenv->cfg.controller_axis_binds.size() != 6) {
        app::reset_controller_binding(*state.emuenv);
    }

    init_libraries(*state.emuenv);

    if (!app::init_apps_list(*state.emuenv))
        LOG_ERROR("Failed to initialize apps list (continuing -- boot may still work if the title is on disk).");

    app::load_users(*state.emuenv);
    if (!app::ensure_current_user(*state.emuenv)) {
        LOG_ERROR("Failed to initialize active user.");
        return false;
    }

    state.session_controller = std::make_unique<app::AppSessionController>(*state.emuenv);

    state.one_time_init_done.store(true, std::memory_order_release);
    return true;
}

// Runs on a background thread (vita3k_ios_boot must return quickly -- it is
// called from the view controller on the main thread, mirroring how
// Android's SDL_main already runs off the UI thread). Mirrors the
// begin_launch -> initialize_renderer -> initialize_runtime -> load_and_run
// sequence in android/jni/main_android.cpp's SDL_main, minus the SDL window
// creation and the SDL event-polling loop (there is no SDL window on this
// path, and input arrives via vita3k_ios_send_buttons instead of SDL events).
void run_title_thread(std::string title_id) {
    BridgeState &state = bridge_state();

    app::AppSessionController *controller = nullptr;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        controller = state.session_controller.get();
    }
    if (!controller)
        return;

    EmuEnvState &emuenv = *state.emuenv;

    AppLaunchRequest launch_request{};
    launch_request.app_path = title_id;

    LOG_INFO("iOS bridge: booting '{}'", title_id);

    if (!controller->begin_launch(launch_request, true)) {
        LOG_ERROR("iOS bridge: could not find/launch app '{}'.", title_id);
        return;
    }

    if (!controller->initialize_renderer(*state.frame_host)) {
        LOG_ERROR("iOS bridge: failed to initialize renderer.");
        controller->stop(app::AppSessionStopReason::LaunchFailure);
        return;
    }

    if (!controller->initialize_runtime()) {
        LOG_ERROR("iOS bridge: failed late initialization.");
        controller->stop(app::AppSessionStopReason::LaunchFailure);
        return;
    }

    if (!controller->load_and_run()) {
        LOG_ERROR("iOS bridge: failed to load or start the app session.");
        controller->stop(app::AppSessionStopReason::LaunchFailure);
        return;
    }

    LOG_INFO("iOS bridge: '{}' running (title '{}').", title_id, emuenv.current_app_title);

    // load_and_run() has already started the render thread and the guest's
    // CPU threads; there is nothing left for this thread to pump (no SDL
    // event queue on this path), so it can simply end here. The session
    // stays alive until vita3k_ios_shutdown() calls controller->stop().
}

} // namespace

extern "C" {

int vita3k_ios_present(void) {
    return 1;
}

const char *vita3k_ios_version(void) {
    return window_title;
}

int vita3k_ios_boot(const char *title_id, void *metal_layer) {
    if (!title_id || !title_id[0])
        return -1;

    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);

    if (!one_time_init_locked(state))
        return -1;

    // If a title is already running, stop it first -- begin_launch() refuses
    // to start a second session while one is active (see
    // AppSessionController::begin_launch's Idle-phase check).
    if (state.session_controller && state.session_controller->has_active_session()) {
        state.session_controller->stop(app::AppSessionStopReason::Relaunch);
        if (state.run_thread.joinable())
            state.run_thread.join();
    }

    state.frame_host = std::make_unique<IOSFrameHost>(metal_layer);

    if (state.run_thread.joinable())
        state.run_thread.join();
    state.run_thread = std::thread(run_title_thread, std::string(title_id));

    return 0;
}

void vita3k_ios_send_buttons(uint32_t mask) {
    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.emuenv)
        return;

    // Same injection point the Qt front end's keyboard-as-controller path
    // uses (gui-qt/src/ctrl_keyboard_filter.cpp): CtrlState::keyboard_state
    // is OR'd into the polled button state every frame regardless of
    // whether any SDL_Gamepad is attached (see ctrl/src/ctrl.cpp's
    // apply_keyboard()), which is exactly the "no SDL controller, just
    // deliver a button mask" seam this bridge needs. V3KButton's bit layout
    // (Vita3KCore.h) already matches SceCtrlButtons, so no remapping needed.
    std::lock_guard<std::mutex> ctrl_lock(state.emuenv->ctrl.mutex);
    auto &kb = state.emuenv->ctrl.keyboard_state;
    kb.buttons = mask;
    kb.buttons_ext = mask;
}

// Install a PS Vita firmware PUP into vs0/os0/sa0/pd0 under the data root.
//
// Without this the front end could only ever COPY a PUP into Documents and
// hope: nothing in the emulator ever picked it up, so vs0 stayed empty and
// every commercial title would fail to boot on a missing module. Runs
// synchronously (the caller runs it off the main thread) and reports progress
// 0..100 through the callback so the UI can show a bar -- decrypting and
// extracting a PUP takes a while on a phone.
//
// Returns 0 on success. `out_version` receives the installed firmware version
// string (e.g. "3.60") when there is room for it.
int vita3k_ios_install_firmware(const char *pup_path,
                                void (*progress)(unsigned int, void *), void *ctx,
                                char *out_version, unsigned long out_cap) {
    if (out_version && out_cap)
        out_version[0] = '\0';
    if (!pup_path || !*pup_path)
        return -1;

    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!paths_logging_init_locked(state))
        return -2;

    const fs::path pup = fs_utils::utf8_to_path(std::string(pup_path));
    boost::system::error_code ec;
    if (!fs::exists(pup, ec)) {
        LOG_ERROR("iOS bridge: firmware PUP not found at '{}'", pup);
        return -3;
    }

    LOG_INFO("iOS bridge: installing firmware from '{}'", pup);
    std::string version;
    try {
        version = install_pup(state.root_paths.get_vita_fs_path(), pup,
            [progress, ctx](uint32_t pct) { if (progress) progress(pct, ctx); });
    } catch (const std::exception &e) {
        // A truncated or wrong-keyed PUP throws from deep inside the decrypt /
        // FAT-extract path. Report it instead of taking the process down.
        LOG_ERROR("iOS bridge: firmware install failed: {}", e.what());
        return -4;
    }

    if (version.empty()) {
        LOG_ERROR("iOS bridge: firmware install produced no version -- treating as failure");
        return -5;
    }
    LOG_INFO("iOS bridge: firmware {} installed", version);
    if (out_version && out_cap) {
        std::snprintf(out_version, static_cast<size_t>(out_cap), "%s", version.c_str());
    }
    return 0;
}

// Analog sticks. Values are -1..1 with +y down, matching how the on-screen
// sticks report and how SceCtrl encodes them (ctrl.cpp's float_to_byte maps
// -1..1 onto 0..255 with 0x80 centre). These ride the same virtual-keyboard
// seam as the buttons: ctrl.cpp's apply_keyboard() adds keyboard_state.axes
// into the polled axes every frame whether or not an SDL gamepad exists.
void vita3k_ios_send_analog(float lx, float ly, float rx, float ry) {
    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.emuenv)
        return;
    const auto clamp1 = [](float v) { return v < -1.f ? -1.f : (v > 1.f ? 1.f : v); };
    std::lock_guard<std::mutex> ctrl_lock(state.emuenv->ctrl.mutex);
    auto &kb = state.emuenv->ctrl.keyboard_state;
    kb.axes[0] = clamp1(lx);
    kb.axes[1] = clamp1(ly);
    kb.axes[2] = clamp1(rx);
    kb.axes[3] = clamp1(ry);
}

// Front/rear touchscreen. `nx`/`ny` are normalised to the WHOLE drawable, not
// to the game viewport -- touch.cpp's recover_touch_events() does the
// viewport->Vita-panel mapping itself, so passing viewport-relative
// coordinates here would double-correct. `phase`: 0 = down, 1 = move, 2 = up.
//
// Note on synchronisation: TouchState carries no mutex, and the emulation
// thread reads finger_buffer/finger_count during vsync without one. On other
// platforms these arrive as SDL events drained on that same thread, so the
// question does not come up; here the UI thread writes them. The bridge mutex
// below serialises producers, but a concurrent read on the emulation thread is
// still possible. It is bounded and benign -- the buffer is a fixed 8 entries
// and finger_count never exceeds it, so the worst case is one frame of stale
// or duplicated touch data, never an out-of-bounds access. Called out rather
// than papered over.
void vita3k_ios_send_touch(unsigned long long finger_id, float nx, float ny, int phase) {
    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.emuenv)
        return;

    SDL_TouchFingerEvent ev{};
    ev.type = (phase == 0) ? SDL_EVENT_FINGER_DOWN
            : (phase == 2) ? SDL_EVENT_FINGER_UP
                           : SDL_EVENT_FINGER_MOTION;
    ev.fingerID = static_cast<SDL_FingerID>(finger_id);
    ev.x = nx;
    ev.y = ny;
    ev.pressure = 1.0f;

    state.emuenv->touch.renderer_focused = true;
    handle_touch_event(state.emuenv->touch, ev);
}

// Switch which Vita panel the touches land on: 0 = front, 1 = rear. Several
// games map actions to the rear panel that have no other input route.
void vita3k_ios_set_touch_panel(int rear) {
    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.emuenv)
        return;
    state.emuenv->touch.touchscreen_port = rear ? SCE_TOUCH_PORT_BACK : SCE_TOUCH_PORT_FRONT;
}

// Install a .vpk / .zip / .vci using VITA3K'S OWN INSTALLER rather than the
// front end's hand-rolled unzip.
//
// This matters more than it looks. install_archive() is what routes content by
// its param.sfo CATEGORY -- a patch ("gp") to ux0:/patch, DLC/themes ("ac") to
// ux0:/addcont or ux0:/theme, everything else to ux0:/app -- strips a nested
// content-path prefix so repacks that bury their payload under a folder still
// land correctly, rejects Vitamin dumps, decrypts NoNpDrm content, copies the
// license, and rescans the apps list afterwards. The front end's own extractor
// did none of that: it wrote every archive to ux0:/app/<TITLE_ID> after
// deleting whatever was there, so installing a patch silently destroyed the
// base game it was meant to patch.
//
// Returns the number of contents installed (> 0 on success), or negative on
// error. The first installed content's ids are copied into the out buffers.
int vita3k_ios_install_package(const char *archive_path,
                               void (*progress)(unsigned int, void *), void *ctx,
                               char *out_title_id, unsigned long tid_cap,
                               char *out_title, unsigned long title_cap,
                               char *out_category, unsigned long cat_cap) {
    const auto clear = [](char *b, unsigned long cap) { if (b && cap) b[0] = '\0'; };
    clear(out_title_id, tid_cap); clear(out_title, title_cap); clear(out_category, cat_cap);
    if (!archive_path || !*archive_path)
        return -1;

    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!one_time_init_locked(state) || !state.emuenv)
        return -2;

    const fs::path archive = fs_utils::utf8_to_path(std::string(archive_path));
    boost::system::error_code ec;
    if (!fs::exists(archive, ec)) {
        LOG_ERROR("iOS bridge: package not found at '{}'", archive);
        return -3;
    }

    LOG_INFO("iOS bridge: installing package '{}'", archive);
    std::vector<ContentInfo> installed;
    try {
        installed = install_archive(*state.emuenv, archive,
            [progress, ctx](ArchiveContents c) {
                if (progress && c.progress.has_value())
                    progress(static_cast<unsigned int>(*c.progress), ctx);
            },
            // Reinstall prompt: there is no modal to show from here, and the
            // user already chose to import this file, so accept.
            [](const std::string &title, const std::string &title_id) {
                LOG_INFO("iOS bridge: reinstalling {} ({})", title, title_id);
                return true;
            });
    } catch (const std::exception &e) {
        LOG_ERROR("iOS bridge: package install threw: {}", e.what());
        return -4;
    }

    int ok_count = 0;
    for (const ContentInfo &c : installed) {
        if (!c.state)
            continue;
        if (ok_count == 0) {
            const auto copy = [](char *b, unsigned long cap, const std::string &v) {
                if (b && cap) std::snprintf(b, static_cast<size_t>(cap), "%s", v.c_str());
            };
            copy(out_title_id, tid_cap, c.title_id);
            copy(out_title, title_cap, c.title);
            copy(out_category, cat_cap, c.category);
        }
        ok_count++;
        LOG_INFO("iOS bridge: installed {} [{}] category '{}' -> {}",
            c.title, c.title_id, c.category, c.path);
    }

    if (ok_count == 0) {
        LOG_ERROR("iOS bridge: nothing in '{}' installed successfully", archive);
        return -5;
    }

    // Rescan so the title can be booted in THIS session. init_apps_list() reads
    // a cache and would return the pre-install list; scan_apps() re-reads disk.
    if (!app::scan_apps(*state.emuenv))
        LOG_ERROR("iOS bridge: apps rescan after install failed");
    return ok_count;
}

// Import an already-extracted content folder (a game dumped off a real Vita and
// copied in through the Files app). Upstream exposes this as a drag-and-drop /
// --content-path install; there was no route to it at all on iOS.
int vita3k_ios_install_folder(const char *folder_path) {
    if (!folder_path || !*folder_path)
        return -1;
    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!one_time_init_locked(state) || !state.emuenv)
        return -2;

    const fs::path folder = fs_utils::utf8_to_path(std::string(folder_path));
    boost::system::error_code ec;
    if (!fs::is_directory(folder, ec))
        return -3;

    uint32_t n = 0;
    try {
        n = install_contents(*state.emuenv, folder);
    } catch (const std::exception &e) {
        LOG_ERROR("iOS bridge: folder install threw: {}", e.what());
        return -4;
    }
    if (n == 0)
        return -5;
    if (!app::scan_apps(*state.emuenv))
        LOG_ERROR("iOS bridge: apps rescan after folder install failed");
    return static_cast<int>(n);
}

// Re-read ux0:/app from disk. Needed after the user adds a game by hand through
// the Files app: the core builds its apps list once per process from a cache,
// so without this a folder pasted in later lists in the UI but fails to boot
// with "not found in apps list".
int vita3k_ios_rescan_apps(void) {
    BridgeState &state = bridge_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.emuenv)
        return 0;          // nothing initialised yet; the first init will scan
    return app::scan_apps(*state.emuenv) ? 1 : -1;
}

void vita3k_ios_shutdown(void) {
    BridgeState &state = bridge_state();
    std::thread thread_to_join;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.session_controller)
            state.session_controller->stop(app::AppSessionStopReason::FrontendShutdown);
        thread_to_join = std::move(state.run_thread);
    }
    if (thread_to_join.joinable())
        thread_to_join.join();
}

} // extern "C"
