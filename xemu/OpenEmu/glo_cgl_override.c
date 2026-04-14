/*
 * CGL-based replacement for xemu's SDL gloffscreen
 *
 * The OpenEmu helper process has no window server access, so SDL_CreateWindow
 * fails with exit(1). This provides CGL-based offscreen GL contexts instead.
 *
 * These symbols override the SDL-based ones in gloffscreen_sdl.c because
 * bridge objects are linked before the static library.
 *
 * Copyright (c) 2024 OpenEmu Team
 * SPDX-License-Identifier: BSD-3-Clause
 */

#define GL_SILENCE_DEPRECATION

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

// Must match the struct layout expected by gloffscreen.h
typedef struct _GloContext {
    CGLContextObj cgl_context;
} GloContext;

// Track the first context for sharing
static CGLContextObj g_first_context = NULL;

GloContext *glo_context_create(void)
{
    GloContext *context = (GloContext *)calloc(1, sizeof(GloContext));
    if (!context) return NULL;

    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
        kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
        kCGLPFADepthSize, (CGLPixelFormatAttribute)24,
        kCGLPFAStencilSize, (CGLPixelFormatAttribute)8,
        kCGLPFAAccelerated,
        kCGLPFAAllowOfflineRenderers,
        (CGLPixelFormatAttribute)0
    };

    CGLPixelFormatObj pix;
    GLint npix;
    CGLError err = CGLChoosePixelFormat(attrs, &pix, &npix);
    if (err != kCGLNoError || npix == 0) {
        // Fallback: try GL 3.2 Core instead of 4.1
        CGLPixelFormatAttribute attrs2[] = {
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
            kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
            kCGLPFADepthSize, (CGLPixelFormatAttribute)24,
            kCGLPFAStencilSize, (CGLPixelFormatAttribute)8,
            kCGLPFAAccelerated,
            kCGLPFAAllowOfflineRenderers,
            (CGLPixelFormatAttribute)0
        };
        err = CGLChoosePixelFormat(attrs2, &pix, &npix);
        if (err != kCGLNoError || npix == 0) {
            fprintf(stderr, "[GLO CGL] CGLChoosePixelFormat failed: %d\n", err);
            free(context);
            return NULL;
        }
    }

    // Share with the first context to allow texture sharing between contexts
    err = CGLCreateContext(pix, g_first_context, &context->cgl_context);
    CGLDestroyPixelFormat(pix);
    if (err != kCGLNoError) {
        fprintf(stderr, "[GLO CGL] CGLCreateContext failed: %d\n", err);
        free(context);
        return NULL;
    }

    if (!g_first_context) {
        g_first_context = context->cgl_context;
    }

    // Make new context current
    CGLSetCurrentContext(context->cgl_context);

    // Drain any initial GL errors from context creation
    GLenum init_err;
    while ((init_err = glGetError()) != GL_NO_ERROR) {
        fprintf(stderr, "[GLO CGL] Drained initial GL error 0x%04X from new context\n", init_err);
    }

    const char *vendor = (const char *)glGetString(GL_VENDOR);
    const char *renderer_str = (const char *)glGetString(GL_RENDERER);
    const char *version = (const char *)glGetString(GL_VERSION);
    fprintf(stderr, "[GLO CGL] Created GL context %p (shared=%d)\n",
            (void *)context->cgl_context,
            context->cgl_context != g_first_context);
    fprintf(stderr, "[GLO CGL]   Vendor:   %s\n", vendor ? vendor : "(null)");
    fprintf(stderr, "[GLO CGL]   Renderer: %s\n", renderer_str ? renderer_str : "(null)");
    fprintf(stderr, "[GLO CGL]   Version:  %s\n", version ? version : "(null)");

    return context;
}

void glo_set_current(GloContext *context)
{
    if (context == NULL) {
        CGLSetCurrentContext(NULL);
    } else {
        CGLSetCurrentContext(context->cgl_context);
        // Drain any pending GL errors so callers start with clean state
        GLenum err;
        while ((err = glGetError()) != GL_NO_ERROR) {
            fprintf(stderr, "[GLO CGL] Drained GL error 0x%04X on set_current(%p)\n",
                    err, (void *)context->cgl_context);
        }
    }
}

void glo_context_destroy(GloContext *context)
{
    if (!context) return;
    if (context->cgl_context == g_first_context) {
        // Don't destroy the shared root context
        g_first_context = NULL;
    }
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context->cgl_context);
    free(context);
}

bool glo_check_extension(const char *ext_name)
{
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    if (extensions && strstr(extensions, ext_name)) {
        return true;
    }

    // GL 3.0+ core profile: use glGetStringi
    GLint num_extensions = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &num_extensions);
    for (GLint i = 0; i < num_extensions; i++) {
        const char *ext = (const char *)glGetStringi(GL_EXTENSIONS, i);
        if (ext && strcmp(ext, ext_name) == 0) {
            return true;
        }
    }

    return false;
}

void glo_readpixels(unsigned int gl_format, unsigned int gl_type,
                    unsigned int bytes_per_pixel, unsigned int stride,
                    unsigned int width, unsigned int height, bool vflip,
                    void *data)
{
    // Simple glReadPixels wrapper
    glReadPixels(0, 0, width, height, gl_format, gl_type, data);
}
