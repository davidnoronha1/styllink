package dev.styllink;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Shows the "h264" stream: MediaCodec decodes straight into the surface,
 * preferring a hardware decoder with the low-latency feature, and each
 * picture is released for display the moment it is decoded.
 */
final class AvcRenderer {
    interface Acker {
        void ack(int frameId);
    }

    private final MediaCodec codec;
    private final HandlerThread thread = new HandlerThread("styllink-avc");
    private final LinkedBlockingQueue<Integer> inputs = new LinkedBlockingQueue<>();
    private final boolean[] dup = new boolean[256];
    private final int width, height;
    final String name;

    /** The best H.264 decoder: hardware, then low-latency capable. */
    static String pickDecoder() {
        String best = null;
        int bestScore = -1;
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (info.isEncoder()) continue;
            for (String type : info.getSupportedTypes()) {
                if (!type.equalsIgnoreCase(MediaFormat.MIMETYPE_VIDEO_AVC)) continue;
                int score = 0;
                if (info.isHardwareAccelerated()) score += 2;
                try {
                    if (info.getCapabilitiesForType(type).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency))
                        score += 1;
                } catch (IllegalArgumentException ignored) {
                }
                if (score > bestScore) {
                    bestScore = score;
                    best = info.getName();
                }
            }
        }
        return best;
    }

    static boolean available() {
        return pickDecoder() != null;
    }

    AvcRenderer(Surface surface, int width, int height, Acker acker) throws java.io.IOException {
        this.width = width;
        this.height = height;
        String n = pickDecoder();
        codec = n != null ? MediaCodec.createByCodecName(n) : MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        name = codec.getName();
        thread.start();
        codec.setCallback(new MediaCodec.Callback() {
            @Override
            public void onInputBufferAvailable(MediaCodec mc, int index) {
                inputs.offer(index);
            }

            @Override
            public void onOutputBufferAvailable(MediaCodec mc, int index, MediaCodec.BufferInfo info) {
                try {
                    mc.releaseOutputBuffer(index, true); // display now
                } catch (IllegalStateException e) {
                    return;
                }
                int id = (int) (info.presentationTimeUs / 1000);
                if (!dup[id & 255]) acker.ack(id);
            }

            @Override
            public void onError(MediaCodec mc, MediaCodec.CodecException e) {
            }

            @Override
            public void onOutputFormatChanged(MediaCodec mc, MediaFormat format) {
            }
        }, new Handler(thread.getLooper()));
        MediaFormat f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
        f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        f.setInteger(MediaFormat.KEY_PRIORITY, 0); // realtime
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, Math.max(1 << 20, width * height));
        try {
            f.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE); // decode as fast as possible
            codec.configure(f, surface, null, 0);
        } catch (IllegalArgumentException | IllegalStateException e) {
            f.removeKey(MediaFormat.KEY_OPERATING_RATE);
            codec.configure(f, surface, null, 0);
        }
        codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT);
        codec.start();
    }

    boolean matches(int w, int h) {
        return w == width && h == height;
    }

    /** Queues one access unit. Returns false if the decoder fell behind. */
    boolean feed(byte[] data, int off, int len, int frameId, boolean key, boolean isDup) throws InterruptedException {
        Integer index = inputs.poll(500, TimeUnit.MILLISECONDS);
        if (index == null) return false;
        ByteBuffer in = codec.getInputBuffer(index);
        if (in == null || in.capacity() < len) return false;
        in.clear();
        in.put(data, off, len);
        dup[frameId & 255] = isDup;
        codec.queueInputBuffer(index, 0, len, (frameId & 0x7fffffffL) * 1000L, key ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0);
        return true;
    }

    void release() {
        try {
            codec.stop();
        } catch (IllegalStateException ignored) {
        }
        codec.release();
        thread.quitSafely();
    }
}
