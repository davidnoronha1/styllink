package dev.styllink;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.Build;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.View;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;

/**
 * Full-screen pad. Every pen sample (including the historical ones Android
 * batches into a MotionEvent) goes to the server in the page's wire format:
 * u32 send time (0.1 ms), then per sample u16 x, u16 y, u16 pressure,
 * i8 tiltX, i8 tiltY, u8 flags, u8 age (0.5 ms).
 */
final class PadView extends View {
    interface Host {
        Link link();
        boolean fingerDrawing();
        boolean trail();
        int trailDurationMs();
    }

    private static final int IN_RANGE = 1, TOUCH = 2, BARREL = 4, ERASER = 8;
    private static final int MAX_BATCH = 64;
    private static final long EXIT_DELAY_MS = 40;

    private final Host host;
    private final byte[] buf = new byte[4 + 10 * MAX_BATCH];
    private final ByteBuffer bb = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN);
    private final float density;
    private final float textScale;

    private static final class Seg {
        float x0, y0, x1, y1, w;
        long t;
    }

    private final ArrayDeque<Seg> segs = new ArrayDeque<>();
    private final Paint ink = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint notice = new Paint(Paint.ANTI_ALIAS_FLAG);
    private float lastX, lastY;
    private boolean lastInk;
    private boolean online;

    // Android reports HOVER_EXIT right before a stylus touches down; sending
    // that as "out of range" would make the PC see the pen leave and come back
    // on every stroke. So out-of-range is sent only if nothing follows soon.
    private float exitX, exitY;
    private int exitFlags;
    private final Runnable sendExit = () -> sendSingle(exitX, exitY, exitFlags);

    @Override
    protected void onDetachedFromWindow() {
        removeCallbacks(sendExit);
        super.onDetachedFromWindow();
    }

    PadView(Context c, Host host) {
        super(c);
        this.host = host;
        density = getResources().getDisplayMetrics().density;
        textScale = getResources().getDisplayMetrics().scaledDensity;
        ink.setStyle(Paint.Style.STROKE);
        ink.setStrokeCap(Paint.Cap.ROUND);
        ink.setColor(0xFFE6EDF3);

    }

    void setOnline(boolean v) {
        if (v != online) {
            online = v;
            invalidate();
        }
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        // Deliver pointer events as soon as they arrive instead of once per
        // display frame (the native equivalent of pointerrawupdate).
        if (Build.VERSION.SDK_INT >= 31) requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER);
    }

    private static boolean isPen(int tool) {
        return tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER;
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int tool = e.getToolType(0);
        int action = e.getActionMasked();
        boolean pen = isPen(tool);
        if (!pen && !(tool == MotionEvent.TOOL_TYPE_FINGER && host.fingerDrawing())) return true; // palms etc.
        switch (action) {
            case MotionEvent.ACTION_DOWN:
                removeCallbacks(sendExit);
                requestUnbufferedDispatch(e);
                send(e, true, true);
                break;
            case MotionEvent.ACTION_MOVE:
                send(e, true, true);
                break;
            case MotionEvent.ACTION_UP:
                send(e, pen, false); // a pen keeps hovering; a finger leaves
                break;
            case MotionEvent.ACTION_CANCEL:
                send(e, false, false);
                break;
            default:
                break; // extra fingers: ignored
        }
        return true;
    }

    @Override
    public boolean onHoverEvent(MotionEvent e) {
        if (!isPen(e.getToolType(0))) return super.onHoverEvent(e);
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_HOVER_ENTER:
            case MotionEvent.ACTION_HOVER_MOVE:
                removeCallbacks(sendExit);
                send(e, true, false);
                return true;
            case MotionEvent.ACTION_HOVER_EXIT:
                exitX = e.getX();
                exitY = e.getY();
                exitFlags = e.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER ? ERASER : 0;
                removeCallbacks(sendExit);
                postDelayed(sendExit, EXIT_DELAY_MS);
                return true;
            default:
                return true;
        }
    }

    private static long nowNanos() {
        return Build.VERSION.SDK_INT >= 33 ? SystemClock.uptimeNanos() : SystemClock.uptimeMillis() * 1_000_000L;
    }

    private static long eventNanos(MotionEvent e, int h, boolean current) {
        if (Build.VERSION.SDK_INT >= 34)
            return current ? e.getEventTimeNanos() : e.getHistoricalEventTimeNanos(h);
        return (current ? e.getEventTime() : e.getHistoricalEventTime(h)) * 1_000_000L;
    }

    private static int u16(float v) {
        return Math.round(Math.max(0f, Math.min(1f, v)) * 65535f);
    }

    private void putSample(float x, float y, float pressure, float tilt, float orient, int flags, long ageNanos) {
        float w = Math.max(1, getWidth()), h = Math.max(1, getHeight());
        // Android: tilt from vertical + orientation; convert to the PointerEvent
        // tiltX/tiltY convention the server expects (as Chromium does).
        double st = Math.sin(tilt), ct = Math.cos(tilt);
        int tx = (int) Math.round(Math.toDegrees(Math.atan2(Math.sin(-orient) * st, ct)));
        int ty = (int) Math.round(Math.toDegrees(Math.atan2(Math.cos(-orient) * st, ct)));
        float p = (flags & TOUCH) != 0 ? (pressure > 0 ? pressure : 0.5f) : 0f;
        bb.putShort((short) u16(x / w));
        bb.putShort((short) u16(y / h));
        bb.putShort((short) u16(p));
        bb.put((byte) Math.max(-90, Math.min(90, tx)));
        bb.put((byte) Math.max(-90, Math.min(90, ty)));
        bb.put((byte) flags);
        bb.put((byte) Math.max(0, Math.min(255, ageNanos / 500_000L)));
    }

    private void send(MotionEvent e, boolean inRange, boolean touching) {
        int tool = e.getToolType(0);
        int flags = 0;
        if (inRange) flags |= IN_RANGE;
        if (inRange && touching) flags |= TOUCH;
        if ((e.getButtonState() & MotionEvent.BUTTON_STYLUS_PRIMARY) != 0) flags |= BARREL;
        if (tool == MotionEvent.TOOL_TYPE_ERASER) flags |= ERASER;

        long now = nowNanos();
        int hist = e.getHistorySize();

        bb.clear();
        bb.putInt((int) (now / 100_000L));
        long t = SystemClock.uptimeMillis();
        for (int i = 0; i <= hist; i++) {
            boolean cur = i == hist;
            float x = cur ? e.getX() : e.getHistoricalX(i);
            float y = cur ? e.getY() : e.getHistoricalY(i);
            float p = cur ? e.getPressure() : e.getHistoricalPressure(i);
            float tilt = cur ? e.getAxisValue(MotionEvent.AXIS_TILT) : e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, i);
            float orient = cur ? e.getOrientation() : e.getHistoricalOrientation(i);
            // Historical samples precede the final tip-up/cancel transition.
            int sampleFlags = flags;
            if (!cur && (e.getActionMasked() == MotionEvent.ACTION_UP
                    || e.getActionMasked() == MotionEvent.ACTION_CANCEL)) sampleFlags |= IN_RANGE | TOUCH;
            putSample(x, y, p, tilt, orient, sampleFlags, now - eventNanos(e, i, cur));
            if (host.trail()) trail(x, y, p, (sampleFlags & TOUCH) != 0, t);
            if (bb.position() == buf.length || cur) {
                host.link().sendBinary(buf, bb.position());
                bb.clear();
                bb.putInt((int) (now / 100_000L));
            }
        }
        if (!segs.isEmpty()) postInvalidateOnAnimation();
    }

    private void sendSingle(float x, float y, int flags) {
        bb.clear();
        long now = nowNanos();
        bb.putInt((int) (now / 100_000L));
        putSample(x, y, 0, 0, 0, flags, 0);
        host.link().sendBinary(buf, bb.position());
        lastInk = false;
    }

    private void trail(float x, float y, float p, boolean ink, long t) {
        if (ink && lastInk) {
            Seg s = new Seg();
            s.x0 = lastX;
            s.y0 = lastY;
            s.x1 = x;
            s.y1 = y;
            s.w = (1 + 4 * (p > 0 ? p : 0.5f)) * density;
            s.t = t;
            segs.addLast(s);
            if (segs.size() > 4000) segs.pollFirst();
        }
        lastX = x;
        lastY = y;
        lastInk = ink;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        canvas.drawColor(Color.BLACK);

        long now = SystemClock.uptimeMillis();
        int fadeMs = host.trailDurationMs();
        while (!segs.isEmpty() && now - segs.peekFirst().t > fadeMs) segs.pollFirst();
        for (Seg s : segs) {
            ink.setAlpha((int) (255 * (1 - (now - s.t) / (float) fadeMs)));
            ink.setStrokeWidth(s.w);
            canvas.drawLine(s.x0, s.y0, s.x1, s.y1, ink);
        }
        if (!online) drawDisconnected(canvas);
        if (!segs.isEmpty()) postInvalidateOnAnimation();
    }

    private void drawDisconnected(Canvas canvas) {
        float cx = getWidth() / 2f, cy = getHeight() / 2f;
        float halfWidth = Math.min(190 * density, getWidth() / 2f - 16 * density);
        notice.setStyle(Paint.Style.FILL);
        notice.setColor(0xFF151719);
        canvas.drawRoundRect(cx - halfWidth, cy - 80 * density,
                cx + halfWidth, cy + 80 * density, 16 * density, 16 * density, notice);

        // Gray Wi-Fi symbol with a slash: visible without relying on color.
        float iy = cy - 26 * density;
        notice.setColor(0xFF858B93);
        notice.setStyle(Paint.Style.STROKE);
        notice.setStrokeWidth(2.5f * density);
        notice.setStrokeCap(Paint.Cap.ROUND);
        canvas.drawArc(cx - 22 * density, iy - 20 * density,
                cx + 22 * density, iy + 24 * density, 220, 100, false, notice);
        canvas.drawArc(cx - 13 * density, iy - 10 * density,
                cx + 13 * density, iy + 16 * density, 220, 100, false, notice);
        canvas.drawLine(cx - 20 * density, iy - 20 * density,
                cx + 20 * density, iy + 18 * density, notice);
        notice.setStyle(Paint.Style.FILL);
        canvas.drawCircle(cx, iy + 12 * density, 2.5f * density, notice);
        notice.setTextAlign(Paint.Align.CENTER);
        notice.setColor(0xFFAFB4BB);
        notice.setTextSize(18 * textScale);
        canvas.drawText("Not connected", cx, cy + 22 * density, notice);
        notice.setColor(0xFF858B93);
        notice.setTextSize(14 * textScale);
        String hint = "Open Menu to connect to your PC";
        float available = Math.max(1, halfWidth * 2 - 24 * density);
        if (notice.measureText(hint) > available)
            notice.setTextSize(notice.getTextSize() * available / notice.measureText(hint));
        canvas.drawText(hint, cx, cy + 48 * density, notice);
    }
}
