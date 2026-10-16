package dev.styllink;

import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

/**
 * Shows the "tiles" stream: one texture the size of the stream; each changed
 * rectangle is uploaded with glTexSubImage2D and the frame is drawn when its
 * last rectangle arrives. Runs on the thread that reads the socket, so a
 * rectangle goes from the network to the GPU without a thread hop.
 *
 * Front-buffer mode renders straight into the buffer on screen
 * (EGL_SINGLE_BUFFER + EGL_ANDROID_front_buffer_auto_refresh): no queue and
 * no wait for a swap, at the cost of possible tearing inside the changed
 * area. Otherwise swaps are unthrottled (interval 0), so a newer frame
 * replaces a queued one instead of waiting behind it.
 */
final class TileRenderer {
    private static final int EGL_FRONT_BUFFER_AUTO_REFRESH_ANDROID = 0x314C;

    private final int width, height;
    private final boolean rgb565;
    private EGLDisplay dpy = EGL14.EGL_NO_DISPLAY;
    private EGLContext ctx = EGL14.EGL_NO_CONTEXT;
    private EGLSurface surf = EGL14.EGL_NO_SURFACE;
    private boolean front;
    private int program, texture, swizzleLoc;
    private final FloatBuffer quad;
    // Bounding box of this frame's rectangles (front buffer: draw only that).
    private int dx0, dy0, dx1, dy1;
    private ByteBuffer upload = ByteBuffer.allocateDirect(0);

    TileRenderer(Surface surface, int width, int height, boolean rgb565, boolean wantFront) {
        this.width = width;
        this.height = height;
        this.rgb565 = rgb565;
        dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] version = new int[2];
        if (!EGL14.eglInitialize(dpy, version, 0, version, 1)) throw new IllegalStateException("eglInitialize");
        int[] attribs = {
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT, EGL14.EGL_NONE};
        EGLConfig[] configs = new EGLConfig[1];
        int[] n = new int[1];
        if (!EGL14.eglChooseConfig(dpy, attribs, 0, configs, 0, 1, n, 0) || n[0] == 0)
            throw new IllegalStateException("eglChooseConfig");
        ctx = EGL14.eglCreateContext(dpy, configs[0], EGL14.EGL_NO_CONTEXT,
                new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
        if (ctx == EGL14.EGL_NO_CONTEXT) throw new IllegalStateException("eglCreateContext");

        if (wantFront) {
            surf = EGL14.eglCreateWindowSurface(dpy, configs[0], surface,
                    new int[]{EGL14.EGL_RENDER_BUFFER, EGL14.EGL_SINGLE_BUFFER, EGL14.EGL_NONE}, 0);
            if (surf != EGL14.EGL_NO_SURFACE && EGL14.eglMakeCurrent(dpy, surf, surf, ctx)
                    && EGL14.eglSurfaceAttrib(dpy, surf, EGL_FRONT_BUFFER_AUTO_REFRESH_ANDROID, 1)) {
                int[] rb = new int[1];
                EGL14.eglQuerySurface(dpy, surf, EGL14.EGL_RENDER_BUFFER, rb, 0);
                front = rb[0] == EGL14.EGL_SINGLE_BUFFER;
            }
            if (!front && surf != EGL14.EGL_NO_SURFACE) {
                EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
                EGL14.eglDestroySurface(dpy, surf);
                surf = EGL14.EGL_NO_SURFACE;
            }
        }
        if (!front) {
            surf = EGL14.eglCreateWindowSurface(dpy, configs[0], surface, new int[]{EGL14.EGL_NONE}, 0);
            if (surf == EGL14.EGL_NO_SURFACE || !EGL14.eglMakeCurrent(dpy, surf, surf, ctx))
                throw new IllegalStateException("eglCreateWindowSurface");
            EGL14.eglSwapInterval(dpy, 0);
        }

        program = link(
                "attribute vec2 pos; attribute vec2 uv; varying vec2 v;"
                        + "void main() { v = uv; gl_Position = vec4(pos, 0.0, 1.0); }",
                "precision mediump float; uniform sampler2D tex; uniform float swizzle; varying vec2 v;"
                        + "void main() { vec4 c = texture2D(tex, v);"
                        + " gl_FragColor = vec4(mix(c.rgb, c.bgr, swizzle), 1.0); }");
        GLES20.glUseProgram(program);
        swizzleLoc = GLES20.glGetUniformLocation(program, "swizzle");
        // BGRX bytes are uploaded as RGBA and swapped back in the shader.
        GLES20.glUniform1f(swizzleLoc, rgb565 ? 0f : 1f);
        quad = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
        quad.put(new float[]{-1, 1, 0, 0, -1, -1, 0, 1, 1, 1, 1, 0, 1, -1, 1, 1}).position(0);
        int pos = GLES20.glGetAttribLocation(program, "pos");
        int uv = GLES20.glGetAttribLocation(program, "uv");
        quad.position(0);
        GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 16, quad);
        GLES20.glEnableVertexAttribArray(pos);
        quad.position(2);
        GLES20.glVertexAttribPointer(uv, 2, GLES20.GL_FLOAT, false, 16, quad);
        GLES20.glEnableVertexAttribArray(uv);

        int[] t = new int[1];
        GLES20.glGenTextures(1, t, 0);
        texture = t[0];
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
        if (rgb565) {
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGB, width, height, 0,
                    GLES20.GL_RGB, GLES20.GL_UNSIGNED_SHORT_5_6_5, null);
        } else {
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0,
                    GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null);
        }
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, rgb565 ? 2 : 4);
        resetDamage();
    }

    boolean frontBuffered() {
        return front;
    }

    boolean matches(int w, int h, boolean is565) {
        return w == width && h == height && is565 == rgb565;
    }

    /** Uploads one rectangle of decoded pixels (tightly packed rows). */
    void rect(int x, int y, int w, int h, byte[] pixels, int len) {
        if (upload.capacity() < len) upload = ByteBuffer.allocateDirect(Math.max(len, upload.capacity() * 2));
        upload.clear();
        upload.put(pixels, 0, len).position(0);
        if (rgb565) {
            GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, x, y, w, h, GLES20.GL_RGB, GLES20.GL_UNSIGNED_SHORT_5_6_5, upload);
        } else {
            GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, x, y, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, upload);
        }
        dx0 = Math.min(dx0, x);
        dy0 = Math.min(dy0, y);
        dx1 = Math.max(dx1, x + w);
        dy1 = Math.max(dy1, y + h);
    }

    /** Puts the frame on screen. */
    void present() {
        int[] size = new int[2];
        EGL14.eglQuerySurface(dpy, surf, EGL14.EGL_WIDTH, size, 0);
        EGL14.eglQuerySurface(dpy, surf, EGL14.EGL_HEIGHT, size, 1);
        int sw = size[0], sh = size[1];
        GLES20.glViewport(0, 0, sw, sh);
        boolean exact = sw == width && sh == height;
        int filter = exact ? GLES20.GL_NEAREST : GLES20.GL_LINEAR;
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, filter);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, filter);
        if (front && dx1 > dx0) {
            // Only the changed area: less to tear, less to draw. One pixel of
            // margin covers the linear filter's reach.
            int x0 = (int) Math.floor((double) dx0 * sw / width) - 1;
            int x1 = (int) Math.ceil((double) dx1 * sw / width) + 1;
            int y0 = (int) Math.floor((double) dy0 * sh / height) - 1;
            int y1 = (int) Math.ceil((double) dy1 * sh / height) + 1;
            GLES20.glEnable(GLES20.GL_SCISSOR_TEST);
            GLES20.glScissor(x0, sh - y1, x1 - x0, y1 - y0);
        } else {
            GLES20.glDisable(GLES20.GL_SCISSOR_TEST);
        }
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        if (front) GLES20.glFlush();
        else EGL14.eglSwapBuffers(dpy, surf);
        resetDamage();
    }

    private void resetDamage() {
        dx0 = dy0 = Integer.MAX_VALUE;
        dx1 = dy1 = Integer.MIN_VALUE;
    }

    void release() {
        if (dpy == EGL14.EGL_NO_DISPLAY) return;
        EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
        if (surf != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(dpy, surf);
        if (ctx != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(dpy, ctx);
        EGL14.eglReleaseThread();
        dpy = EGL14.EGL_NO_DISPLAY;
    }

    private static int link(String vs, String fs) {
        int p = GLES20.glCreateProgram();
        GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vs));
        GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fs));
        GLES20.glLinkProgram(p);
        int[] ok = new int[1];
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) throw new IllegalStateException("link: " + GLES20.glGetProgramInfoLog(p));
        return p;
    }

    private static int shader(int type, String src) {
        int s = GLES20.glCreateShader(type);
        GLES20.glShaderSource(s, src);
        GLES20.glCompileShader(s);
        int[] ok = new int[1];
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) throw new IllegalStateException("shader: " + GLES20.glGetShaderInfoLog(s));
        return s;
    }
}
