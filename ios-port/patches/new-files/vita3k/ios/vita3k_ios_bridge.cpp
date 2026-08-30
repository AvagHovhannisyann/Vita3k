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
#include <packages/functions.h>
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
