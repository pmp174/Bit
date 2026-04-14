/*
 * Geforce NV2A PGRAPH OpenGL Renderer
 *
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <http://www.gnu.org/licenses/>.
 */

#include "qemu/osdep.h"
#include "hw/display/vga_int.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#include "hw/xbox/nv2a/pgraph/util.h"
#include "renderer.h"

#include <math.h>

#ifdef __APPLE__
#include <IOSurface/IOSurface.h>
#include <OpenGL/CGLIOSurface.h>
#include <OpenGL/CGLCurrent.h>
#endif

#ifdef __APPLE__
/* IOSurface-backed readback for Apple Silicon where GL readback returns zeros */
static IOSurfaceRef g_iosurface = NULL;
static GLuint g_iosurface_tex = 0;
static GLuint g_iosurface_fbo = 0;
static int g_iosurface_width = 0;
static int g_iosurface_height = 0;
static pthread_mutex_t g_iosurface_lock = PTHREAD_MUTEX_INITIALIZER;

static void iosurface_ensure(int width, int height)
{
    if (g_iosurface && g_iosurface_width == width && g_iosurface_height == height) {
        return;
    }

    /* Clean up old resources */
    if (g_iosurface_fbo) { glDeleteFramebuffers(1, &g_iosurface_fbo); g_iosurface_fbo = 0; }
    if (g_iosurface_tex) { glDeleteTextures(1, &g_iosurface_tex); g_iosurface_tex = 0; }
    if (g_iosurface) { CFRelease(g_iosurface); g_iosurface = NULL; }

    /* Create IOSurface — shared CPU/GPU memory */
    {
        const void *keys[] = {
            kIOSurfaceWidth,
            kIOSurfaceHeight,
            kIOSurfaceBytesPerElement,
            kIOSurfaceBytesPerRow,
            kIOSurfacePixelFormat,
        };
        int w_val = width, h_val = height, bpe_val = 4, bpr_val = width * 4;
        int pf_val = 'BGRA';
        CFNumberRef vals[] = {
            CFNumberCreate(NULL, kCFNumberIntType, &w_val),
            CFNumberCreate(NULL, kCFNumberIntType, &h_val),
            CFNumberCreate(NULL, kCFNumberIntType, &bpe_val),
            CFNumberCreate(NULL, kCFNumberIntType, &bpr_val),
            CFNumberCreate(NULL, kCFNumberIntType, &pf_val),
        };
        CFDictionaryRef props = CFDictionaryCreate(NULL,
            keys, (const void **)vals, 5,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        g_iosurface = IOSurfaceCreate(props);
        CFRelease(props);
        for (int i = 0; i < 5; i++) CFRelease(vals[i]);
    }
    if (!g_iosurface) {
        fprintf(stderr, "[NV2A GL] ERROR: Failed to create IOSurface %dx%d\n", width, height);
        return;
    }

    /* Create GL texture backed by IOSurface */
    glGenTextures(1, &g_iosurface_tex);
    glBindTexture(GL_TEXTURE_RECTANGLE, g_iosurface_tex);
    CGLError cgl_err = CGLTexImageIOSurface2D(
        CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE,
        GL_RGBA8, width, height,
        GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
        g_iosurface, 0);
    if (cgl_err != kCGLNoError) {
        fprintf(stderr, "[NV2A GL] ERROR: CGLTexImageIOSurface2D failed: %d\n", cgl_err);
        glDeleteTextures(1, &g_iosurface_tex);
        g_iosurface_tex = 0;
        CFRelease(g_iosurface);
        g_iosurface = NULL;
        return;
    }
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    /* Create FBO targeting the IOSurface texture */
    glGenFramebuffers(1, &g_iosurface_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, g_iosurface_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_RECTANGLE, g_iosurface_tex, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "[NV2A GL] ERROR: IOSurface FBO incomplete: 0x%X\n", status);
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    g_iosurface_width = width;
    g_iosurface_height = height;
    fprintf(stderr, "[NV2A GL] IOSurface created: %dx%d (surface=%p, tex=%u, fbo=%u)\n",
            width, height, (void *)g_iosurface, g_iosurface_tex, g_iosurface_fbo);
}

/* Called from the display bridge to read the IOSurface pixels */
bool nv2a_iosurface_read_pixels(uint32_t *dst, int *out_width, int *out_height)
{
    pthread_mutex_lock(&g_iosurface_lock);
    if (!g_iosurface || !g_iosurface_width || !g_iosurface_height) {
        pthread_mutex_unlock(&g_iosurface_lock);
        return false;
    }

    int w = g_iosurface_width;
    int h = g_iosurface_height;

    IOSurfaceLock(g_iosurface, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(g_iosurface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(g_iosurface);

    /* Flip Y: GL has Y=0 at bottom, screen has Y=0 at top */
    for (int row = 0; row < h; row++) {
        memcpy(&dst[row * w], base + (h - 1 - row) * bytesPerRow, w * 4);
    }

    IOSurfaceUnlock(g_iosurface, kIOSurfaceLockReadOnly, NULL);
    pthread_mutex_unlock(&g_iosurface_lock);

    *out_width = w;
    *out_height = h;
    return true;
}
#endif /* __APPLE__ */

void pgraph_gl_init_display(NV2AState *d)
{
    struct PGRAPHState *pg = &d->pgraph;
    PGRAPHGLState *r = pg->gl_renderer_state;

    glo_set_current(g_nv2a_context_display);

    glGenTextures(1, &r->gl_display_buffer);
    r->gl_display_buffer_internal_format = 0;
    r->gl_display_buffer_width = 0;
    r->gl_display_buffer_height = 0;
    r->gl_display_buffer_format = 0;
    r->gl_display_buffer_type = 0;

    const char *vs =
        "#version 330\n"
        "void main()\n"
        "{\n"
        "    float x = -1.0 + float((gl_VertexID & 1) << 2);\n"
        "    float y = -1.0 + float((gl_VertexID & 2) << 1);\n"
        "    gl_Position = vec4(x, y, 0, 1);\n"
        "}\n";
    /* FIXME: improve interlace handling, pvideo */

    const char *fs =
        "#version 330\n"
        "uniform sampler2D tex;\n"
        "uniform bool pvideo_enable;\n"
        "uniform sampler2D pvideo_tex;\n"
        "uniform vec2 pvideo_in_pos;\n"
        "uniform vec4 pvideo_pos;\n"
        "uniform vec3 pvideo_scale;\n"
        "uniform bool pvideo_color_key_enable;\n"
        "uniform vec3 pvideo_color_key;\n"
        "uniform vec2 display_size;\n"
        "uniform float line_offset;\n"
        "layout(location = 0) out vec4 out_Color;\n"
        "void main()\n"
        "{\n"
        "    vec2 texCoord = gl_FragCoord.xy/display_size;\n"
        "    float rel = display_size.y/textureSize(tex, 0).y/line_offset;\n"
        "    texCoord.y = rel*(1.0f - texCoord.y);\n"
        "    out_Color.rgba = texture(tex, texCoord);\n"
        "    if (pvideo_enable) {\n"
        "        vec2 screenCoord = gl_FragCoord.xy - 0.5;\n"
        "        vec4 output_region = vec4(pvideo_pos.xy, pvideo_pos.xy + pvideo_pos.zw);\n"
        "        bvec4 clip = bvec4(lessThan(screenCoord, output_region.xy),\n"
        "                           greaterThan(screenCoord, output_region.zw));\n"
        "        if (!any(clip) && (!pvideo_color_key_enable || out_Color.rgb == pvideo_color_key)) {\n"
        "            vec2 out_xy = (screenCoord - pvideo_pos.xy) * pvideo_scale.z;\n"
        "            vec2 in_st = (pvideo_in_pos + out_xy * pvideo_scale.xy) / textureSize(pvideo_tex, 0);\n"
        "            in_st.y *= -1.0;\n"
        "            out_Color.rgba = texture(pvideo_tex, in_st);\n"
        "        }\n"
        "    }\n"
        "}\n";

    r->disp_rndr.prog = pgraph_gl_compile_shader(vs, fs);
    r->disp_rndr.tex_loc = glGetUniformLocation(r->disp_rndr.prog, "tex");
    r->disp_rndr.pvideo_enable_loc = glGetUniformLocation(r->disp_rndr.prog, "pvideo_enable");
    r->disp_rndr.pvideo_tex_loc = glGetUniformLocation(r->disp_rndr.prog, "pvideo_tex");
    r->disp_rndr.pvideo_in_pos_loc = glGetUniformLocation(r->disp_rndr.prog, "pvideo_in_pos");
    r->disp_rndr.pvideo_pos_loc = glGetUniformLocation(r->disp_rndr.prog, "pvideo_pos");
    r->disp_rndr.pvideo_scale_loc = glGetUniformLocation(r->disp_rndr.prog, "pvideo_scale");
    r->disp_rndr.pvideo_color_key_enable_loc = glGetUniformLocation(r->disp_rndr.prog, "pvideo_color_key_enable");
    r->disp_rndr.pvideo_color_key_loc = glGetUniformLocation(r->disp_rndr.prog, "pvideo_color_key");
    r->disp_rndr.display_size_loc = glGetUniformLocation(r->disp_rndr.prog, "display_size");
    r->disp_rndr.line_offset_loc = glGetUniformLocation(r->disp_rndr.prog, "line_offset");

    glGenVertexArrays(1, &r->disp_rndr.vao);
    glBindVertexArray(r->disp_rndr.vao);
    glGenBuffers(1, &r->disp_rndr.vbo);
    glBindBuffer(GL_ARRAY_BUFFER, r->disp_rndr.vbo);
    glBufferData(GL_ARRAY_BUFFER, 0, NULL, GL_STATIC_DRAW);
    glGenFramebuffers(1, &r->disp_rndr.fbo);
    glGenTextures(1, &r->disp_rndr.pvideo_tex);
    { GLenum _e = glGetError(); if (_e != GL_NO_ERROR) fprintf(stderr, "[NV2A GL] WARNING: display.c:%d GL error 0x%04X\n", __LINE__, _e); while ((_e = glGetError()) != GL_NO_ERROR) {} }

    glo_set_current(g_nv2a_context_render);
}

void pgraph_gl_finalize_display(PGRAPHState *pg)
{
    PGRAPHGLState *r = pg->gl_renderer_state;

    glo_set_current(g_nv2a_context_display);

    glDeleteTextures(1, &r->gl_display_buffer);
    r->gl_display_buffer = 0;

    glDeleteProgram(r->disp_rndr.prog);
    r->disp_rndr.prog = 0;

    glDeleteVertexArrays(1, &r->disp_rndr.vao);
    r->disp_rndr.vao = 0;

    glDeleteBuffers(1, &r->disp_rndr.vbo);
    r->disp_rndr.vbo = 0;

    glDeleteFramebuffers(1, &r->disp_rndr.fbo);
    r->disp_rndr.fbo = 0;

    glDeleteTextures(1, &r->disp_rndr.pvideo_tex);
    r->disp_rndr.pvideo_tex = 0;

    glo_set_current(g_nv2a_context_render);
}

static uint8_t *convert_texture_data__CR8YB8CB8YA8(const uint8_t *data,
                                                   unsigned int width,
                                                   unsigned int height,
                                                   unsigned int pitch)
{
    uint8_t *converted_data = (uint8_t *)g_malloc(width * height * 4);
    int x, y;
    for (y = 0; y < height; y++) {
        const uint8_t *line = &data[y * pitch];
        const uint32_t row_offset = y * width;
        for (x = 0; x < width; x++) {
            uint8_t *pixel = &converted_data[(row_offset + x) * 4];
            convert_yuy2_to_rgb(line, x, &pixel[0], &pixel[1], &pixel[2]);
            pixel[3] = 255;
        }
    }
    return converted_data;
}

static float pvideo_calculate_scale(unsigned int din_dout,
                                           unsigned int output_size)
{
    float calculated_in = din_dout * (output_size - 1);
    calculated_in = floorf(calculated_in / (1 << 20) + 0.5f);
    return (calculated_in + 1.0f) / output_size;
}

static void render_display_pvideo_overlay(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHGLState *r = pg->gl_renderer_state;

    // FIXME: This check against PVIDEO_SIZE_IN does not match HW behavior.
    // Many games seem to pass this value when initializing or tearing down
    // PVIDEO. On its own, this generally does not result in the overlay being
    // hidden, however there are certain games (e.g., Ultimate Beach Soccer)
    // that use an unknown mechanism to hide the overlay without explicitly
    // stopping it.
    // Since the value seems to be set to 0xFFFFFFFF only in cases where the
    // content is not valid, it is probably good enough to treat it as an
    // implicit stop.
    bool enabled = (d->pvideo.regs[NV_PVIDEO_BUFFER] & NV_PVIDEO_BUFFER_0_USE)
        && d->pvideo.regs[NV_PVIDEO_SIZE_IN] != 0xFFFFFFFF;
    glUniform1ui(r->disp_rndr.pvideo_enable_loc, enabled);
    if (!enabled) {
        return;
    }

    hwaddr base = d->pvideo.regs[NV_PVIDEO_BASE];
    hwaddr limit = d->pvideo.regs[NV_PVIDEO_LIMIT];
    hwaddr offset = d->pvideo.regs[NV_PVIDEO_OFFSET];

    int in_width =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_SIZE_IN], NV_PVIDEO_SIZE_IN_WIDTH);
    int in_height =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_SIZE_IN], NV_PVIDEO_SIZE_IN_HEIGHT);

    int in_s = GET_MASK(d->pvideo.regs[NV_PVIDEO_POINT_IN],
                        NV_PVIDEO_POINT_IN_S);
    int in_t = GET_MASK(d->pvideo.regs[NV_PVIDEO_POINT_IN],
                        NV_PVIDEO_POINT_IN_T);

    int in_pitch =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_FORMAT], NV_PVIDEO_FORMAT_PITCH);
    int in_color =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_FORMAT], NV_PVIDEO_FORMAT_COLOR);

    unsigned int out_width =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_SIZE_OUT], NV_PVIDEO_SIZE_OUT_WIDTH);
    unsigned int out_height =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_SIZE_OUT], NV_PVIDEO_SIZE_OUT_HEIGHT);

    float scale_x = 1.0f;
    float scale_y = 1.0f;
    unsigned int ds_dx = d->pvideo.regs[NV_PVIDEO_DS_DX];
    unsigned int dt_dy = d->pvideo.regs[NV_PVIDEO_DT_DY];
    if (ds_dx != NV_PVIDEO_DIN_DOUT_UNITY) {
        scale_x = pvideo_calculate_scale(ds_dx, out_width);
    }
    if (dt_dy != NV_PVIDEO_DIN_DOUT_UNITY) {
        scale_y = pvideo_calculate_scale(dt_dy, out_height);
    }

    // On HW, setting NV_PVIDEO_SIZE_IN larger than NV_PVIDEO_SIZE_OUT results
    // in them being capped to the output size, content is not scaled. This is
    // particularly important as NV_PVIDEO_SIZE_IN may be set to 0xFFFFFFFF
    // during initialization or teardown.
    if (in_width > out_width) {
        in_width = floorf((float)out_width * scale_x + 0.5f);
    }
    if (in_height > out_height) {
        in_height = floorf((float)out_height * scale_y + 0.5f);
    }

    /* TODO: support other color formats */
    assert(in_color == NV_PVIDEO_FORMAT_COLOR_LE_CR8YB8CB8YA8);

    unsigned int out_x =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_POINT_OUT], NV_PVIDEO_POINT_OUT_X);
    unsigned int out_y =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_POINT_OUT], NV_PVIDEO_POINT_OUT_Y);

    unsigned int color_key_enabled =
        GET_MASK(d->pvideo.regs[NV_PVIDEO_FORMAT], NV_PVIDEO_FORMAT_DISPLAY);
    glUniform1ui(r->disp_rndr.pvideo_color_key_enable_loc,
                 color_key_enabled);

    unsigned int color_key = d->pvideo.regs[NV_PVIDEO_COLOR_KEY] & 0xFFFFFF;
    glUniform3f(r->disp_rndr.pvideo_color_key_loc,
                GET_MASK(color_key, NV_PVIDEO_COLOR_KEY_RED) / 255.0,
                GET_MASK(color_key, NV_PVIDEO_COLOR_KEY_GREEN) / 255.0,
                GET_MASK(color_key, NV_PVIDEO_COLOR_KEY_BLUE) / 255.0);

    assert(offset + in_pitch * in_height <= limit);
    hwaddr end = base + offset + in_pitch * in_height;
    assert(end <= memory_region_size(d->vram));

    pgraph_apply_scaling_factor(pg, &out_x, &out_y);
    pgraph_apply_scaling_factor(pg, &out_width, &out_height);

    // Translate for the GL viewport origin.
    out_y = MAX(r->gl_display_buffer_height - 1 - (int)(out_y + out_height), 0);

    glActiveTexture(GL_TEXTURE0 + 1);
    glBindTexture(GL_TEXTURE_2D, r->disp_rndr.pvideo_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    uint8_t *tex_rgba = convert_texture_data__CR8YB8CB8YA8(
        d->vram_ptr + base + offset, in_width, in_height, in_pitch);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, in_width, in_height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, tex_rgba);
    g_free(tex_rgba);
    glUniform1i(r->disp_rndr.pvideo_tex_loc, 1);
    glUniform2f(r->disp_rndr.pvideo_in_pos_loc, in_s / 16.f, in_t / 8.f);
    glUniform4f(r->disp_rndr.pvideo_pos_loc,
                out_x, out_y, out_width, out_height);
    glUniform3f(r->disp_rndr.pvideo_scale_loc,
                scale_x, scale_y, 1.0f / pg->surface_scale_factor);
}

static void render_display(NV2AState *d, SurfaceBinding *surface)
{
    struct PGRAPHState *pg = &d->pgraph;
    PGRAPHGLState *r = pg->gl_renderer_state;

    unsigned int width, height;
    VGADisplayParams vga_display_params;
    d->vga.get_resolution(&d->vga, (int*)&width, (int*)&height);
    d->vga.get_params(&d->vga, &vga_display_params);
    int line_offset = vga_display_params.line_offset ? surface->pitch / vga_display_params.line_offset : 1;

    /* Adjust viewport height for interlaced mode, used only in 1080i */
    if (d->vga.cr[NV_PRMCIO_INTERLACE_MODE] != NV_PRMCIO_INTERLACE_MODE_DISABLED) {
        height *= 2;
    }

    pgraph_apply_scaling_factor(pg, &width, &height);

    glBindFramebuffer(GL_FRAMEBUFFER, r->disp_rndr.fbo);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, r->gl_display_buffer);
    bool recreate = (
        surface->fmt.gl_internal_format != r->gl_display_buffer_internal_format
        || width != r->gl_display_buffer_width
        || height != r->gl_display_buffer_height
        || surface->fmt.gl_format != r->gl_display_buffer_format
        || surface->fmt.gl_type != r->gl_display_buffer_type
        );

    if (recreate) {
        /* XXX: There's apparently a bug in some Intel OpenGL drivers for
         * Windows that will leak this texture when its orphaned after use in
         * another context, apparently regardless of which thread it's created
         * or released on.
         *
         * Driver: 27.20.100.8729 9/11/2020 W10 x64
         * Track: https://community.intel.com/t5/Graphics/OpenGL-Windows-drivers-for-Intel-HD-630-leaking-GPU-memory-when/td-p/1274423
         */
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        r->gl_display_buffer_internal_format = surface->fmt.gl_internal_format;
        r->gl_display_buffer_width = width;
        r->gl_display_buffer_height = height;
        r->gl_display_buffer_format = surface->fmt.gl_format;
        r->gl_display_buffer_type = surface->fmt.gl_type;
        glTexImage2D(GL_TEXTURE_2D, 0,
            r->gl_display_buffer_internal_format,
            r->gl_display_buffer_width,
            r->gl_display_buffer_height,
            0,
            r->gl_display_buffer_format,
            r->gl_display_buffer_type,
            NULL);
    }

    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D, r->gl_display_buffer, 0);
    GLenum DrawBuffers[1] = {GL_COLOR_ATTACHMENT0};
    glDrawBuffers(1, DrawBuffers);
    assert(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);

    glBindTexture(GL_TEXTURE_2D, surface->gl_buffer);
    glBindVertexArray(r->disp_rndr.vao);
    glBindBuffer(GL_ARRAY_BUFFER, r->disp_rndr.vbo);
    glUseProgram(r->disp_rndr.prog);
    glProgramUniform1i(r->disp_rndr.prog, r->disp_rndr.tex_loc, 0);
    glUniform2f(r->disp_rndr.display_size_loc, width, height);
    glUniform1f(r->disp_rndr.line_offset_loc, line_offset);
    render_display_pvideo_overlay(d);

    glViewport(0, 0, width, height);
    glColorMask(true, true, true, true);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D, 0, 0);
}

static void gl_fence(void)
{
    GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    int result = glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT,
                                         (GLuint64)(5000000000));
    assert(result == GL_CONDITION_SATISFIED || result == GL_ALREADY_SIGNALED);
    glDeleteSync(fence);
}

void pgraph_gl_sync(NV2AState *d)
{
    VGADisplayParams vga_display_params;
    d->vga.get_params(&d->vga, &vga_display_params);

    SurfaceBinding *surface = pgraph_gl_surface_get_within(d, d->pcrtc.start + vga_display_params.line_offset);
    if (surface == NULL || !surface->color || !surface->width || !surface->height) {
        static int sync_miss_count = 0;
        if (++sync_miss_count <= 5 || (sync_miss_count % 120) == 0) {
            fprintf(stderr, "[NV2A GL] pgraph_gl_sync: no surface (surface=%p, miss #%d)\n",
                    (void *)surface, sync_miss_count);
        }
        qemu_event_set(&d->pgraph.sync_complete);
        return;
    }

    static int sync_hit_count = 0;
    if (++sync_hit_count <= 5 || (sync_hit_count % 120) == 0) {
        fprintf(stderr, "[NV2A GL] pgraph_gl_sync: rendering surface %dx%d gl_buf=%u (hit #%d)\n",
                surface->width, surface->height, surface->gl_buffer, sync_hit_count);
    }

    /* FIXME: Sanity check surface dimensions */

    /* Download the surface from GL to VRAM on the render context.
     * Apple's Metal-backed GL can't share textures across contexts, so the
     * display context approach (render_display + IOSurface blit) produces zeros.
     * Instead, force a surface download on the render context where the data
     * lives, then the OpenEmu display bridge reads directly from VRAM. */
    surface->draw_dirty = true;
    pgraph_gl_surface_download_if_dirty(d, surface);
    gl_fence();

    qatomic_set(&d->pgraph.sync_pending, false);
    qemu_event_set(&d->pgraph.sync_complete);
}

int pgraph_gl_get_framebuffer_surface(NV2AState *d)
{
    PGRAPHState *pg = &d->pgraph;
    PGRAPHGLState *r = pg->gl_renderer_state;

    qemu_mutex_lock(&d->pfifo.lock);
    // FIXME: Possible race condition with pgraph, consider lock

    VGADisplayParams vga_display_params;
    d->vga.get_params(&d->vga, &vga_display_params);

    SurfaceBinding *surface = pgraph_gl_surface_get_within(
        d, d->pcrtc.start + vga_display_params.line_offset);
    if (surface == NULL || !surface->color) {
        qemu_mutex_unlock(&d->pfifo.lock);
        return 0;
    }

    assert(surface->color);
    assert(surface->fmt.gl_attachment == GL_COLOR_ATTACHMENT0);
    assert(surface->fmt.gl_format == GL_RGBA
        || surface->fmt.gl_format == GL_RGB
        || surface->fmt.gl_format == GL_BGR
        || surface->fmt.gl_format == GL_BGRA
        );

    surface->frame_time = pg->frame_time;
    qemu_event_reset(&d->pgraph.sync_complete);
    qatomic_set(&pg->sync_pending, true);
    pfifo_kick(d);
    qemu_mutex_unlock(&d->pfifo.lock);
    qemu_event_wait(&d->pgraph.sync_complete);

    return r->gl_display_buffer;
}
