// glad_gles_stub.c — link-time-only stubs for glad's desktop-OpenGL loader
// entry points (gladLoadGLLoader + every glad_gl* function pointer glutil's
// GL renderer backend calls through).
//
// WHY THIS EXISTS: renderer/src/{scene,shaders,renderer,state_set,sync,
// batch}.cpp all dispatch per-draw-call on `state.current_backend` (OpenGL
// vs Vulkan) at many call sites, not through one central factory -- unlike
// the one-time renderer::init() switch in creation.cpp (which IS guarded
// out for iOS, see the #if !defined(IOS) there), guarding every one of
// those per-call dispatch sites would mean patching hot rendering-path
// logic throughout the renderer, which is far from the "minimal, guarded"
// portability edits this port is going for. So instead: the GL object files
// stay in the link (their *symbols* are still referenced from those dozen
// call sites), but the actual GL entry points they'd call are these no-op
// stubs.
//
// This is SAFE only because nothing on iOS ever actually reaches them:
// creation.cpp's `case Backend::OpenGL:` is compiled out for IOS, so a
// GLState is never constructed and state.current_backend is always
// Backend::Vulkan (Config::CurrentConfig::backend_renderer defaults to
// "Vulkan" and nothing in this port offers OpenGL as a UI choice) -- so
// every gl::* dispatch branch is dead code at runtime, and these stubs are
// never actually invoked. They exist purely so the linker has *something*
// to resolve renderer::gl::*'s glad_gl* references against.
//
// Also worth noting: even setting that aside, this glad build targets
// desktop OpenGL (it declares glGetTexImage, glClearDepth, glPolygonMode --
// none of which exist in OpenGL ES), so it could never have been a real
// working GLES backend on iOS regardless -- there is no "build glad
// properly for iOS" fix available here, only "exclude the GL path" (done
// for the one-time switch) or "stub the leftover per-call references"
// (this file, for the rest).
//
// If OpenGL ever needs to actually work on iOS, the real fix is threading
// an `IOS`-guarded early-out through every renderer::gl::* dispatch call
// site (scene.cpp, shaders.cpp, renderer.cpp, state_set.cpp, sync.cpp,
// batch.cpp) the same way creation.cpp's factory switch is guarded now, not
// building a GLES version of this file.
#include <stddef.h>

int gladLoadGLLoader(void *loader) {
    (void)loader;
    return 0; // "no GL context available" -- matches what a real loader
              // would report if asked to load GL entry points on a platform
              // with none.
}

void glad_glActiveTexture(void) { }
void glad_glAttachShader(void) { }
void glad_glBindBuffer(void) { }
void glad_glBindBufferRange(void) { }
void glad_glBindFramebuffer(void) { }
void glad_glBindImageTexture(void) { }
void glad_glBindSampler(void) { }
void glad_glBindTexture(void) { }
void glad_glBindVertexArray(void) { }
void glad_glBlendEquation(void) { }
void glad_glBlendEquationSeparate(void) { }
void glad_glBlendFuncSeparate(void) { }
void glad_glBufferData(void) { }
void glad_glBufferStorage(void) { }
void glad_glCheckFramebufferStatus(void) { }
void glad_glClear(void) { }
void glad_glClearColor(void) { }
void glad_glClearDepthf(void) { }
void glad_glClearStencil(void) { }
void glad_glClearTexImage(void) { }
void glad_glClientWaitSync(void) { }
void glad_glColorMask(void) { }
void glad_glCompileShader(void) { }
void glad_glCompressedTexImage2D(void) { }
void glad_glCompressedTexSubImage2D(void) { }
void glad_glCopyImageSubData(void) { }
void glad_glCreateProgram(void) { }
void glad_glCreateShader(void) { }
void glad_glCullFace(void) { }
void glad_glDebugMessageCallback(void) { }
void glad_glDeleteBuffers(void) { }
void glad_glDeleteFramebuffers(void) { }
void glad_glDeleteProgram(void) { }
void glad_glDeleteShader(void) { }
void glad_glDeleteSync(void) { }
void glad_glDeleteTextures(void) { }
void glad_glDeleteVertexArrays(void) { }
void glad_glDepthFunc(void) { }
void glad_glDepthMask(void) { }
void glad_glDepthRange(void) { }
void glad_glDepthRangef(void) { }
void glad_glDetachShader(void) { }
void glad_glDisable(void) { }
void glad_glDrawArrays(void) { }
void glad_glDrawBuffers(void) { }
void glad_glDrawElements(void) { }
void glad_glDrawElementsInstanced(void) { }
void glad_glEnable(void) { }
void glad_glEnableVertexAttribArray(void) { }
void glad_glFenceSync(void) { }
void glad_glFinish(void) { }
void glad_glFramebufferTexture(void) { }
void glad_glGenBuffers(void) { }
void glad_glGenFramebuffers(void) { }
void glad_glGenTextures(void) { }
void glad_glGenVertexArrays(void) { }
void glad_glGetAttribLocation(void) { }
void glad_glGetBooleanv(void) { }
void glad_glGetError(void) { }
void glad_glGetFloatv(void) { }
void glad_glGetIntegerv(void) { }
void glad_glGetProgramInfoLog(void) { }
void glad_glGetProgramiv(void) { }
void glad_glGetShaderInfoLog(void) { }
void glad_glGetShaderiv(void) { }
void glad_glGetString(void) { }
void glad_glGetStringi(void) { }
void glad_glGetSynciv(void) { }
void glad_glGetTexImage(void) { }
void glad_glGetTextureSubImage(void) { }
void glad_glGetUniformLocation(void) { }
void glad_glIsEnabled(void) { }
void glad_glLineWidth(void) { }
void glad_glLinkProgram(void) { }
void glad_glMapBufferRange(void) { }
void glad_glMemoryBarrier(void) { }
void glad_glMultiDrawArrays(void) { }
void glad_glPixelStorei(void) { }
void glad_glPointSize(void) { }
void glad_glPolygonMode(void) { }
void glad_glPolygonOffset(void) { }
void glad_glReadPixels(void) { }
void glad_glScissor(void) { }
void glad_glShaderBinary(void) { }
void glad_glShaderSource(void) { }
void glad_glSpecializeShaderARB(void) { }
void glad_glStencilFuncSeparate(void) { }
void glad_glStencilMask(void) { }
void glad_glStencilMaskSeparate(void) { }
void glad_glStencilOpSeparate(void) { }
void glad_glTexImage2D(void) { }
void glad_glTexParameterf(void) { }
void glad_glTexParameteri(void) { }
void glad_glTexParameteriv(void) { }
void glad_glTexStorage2D(void) { }
void glad_glTexStorage3D(void) { }
void glad_glTexSubImage2D(void) { }
void glad_glTexSubImage3D(void) { }
void glad_glTextureBarrier(void) { }
void glad_glUniform1f(void) { }
void glad_glUniform1i(void) { }
void glad_glUniform1ui(void) { }
void glad_glUniform2f(void) { }
void glad_glUniform4f(void) { }
void glad_glUnmapBuffer(void) { }
void glad_glUseProgram(void) { }
void glad_glVertexAttribDivisor(void) { }
void glad_glVertexAttribIPointer(void) { }
void glad_glVertexAttribPointer(void) { }
void glad_glViewport(void) { }
