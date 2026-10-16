package dev.styllink;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.ActivityNotFoundException;
import android.provider.MediaStore;
import android.content.SharedPreferences;
import android.net.Uri;
import android.net.wifi.WifiManager;
import android.graphics.RectF;
import android.os.Bundle;
import android.view.Display;
import android.text.InputType;
import android.view.WindowInsets;
import android.view.Gravity;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.CheckBox;
import android.widget.Button;
import android.widget.Toast;
import android.widget.SeekBar;
import android.widget.ScrollView;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.FrameLayout;
import android.widget.TextView;

/**
 * StylLink pad. Besides sending pen samples, the app's job is to hold a
 * low-latency Wi-Fi lock while it is on screen: Android then turns Wi-Fi
 * power saving off, which a web page cannot ask for. Measured on the Moto Pad
 * 60 Pro, power save made the radio send in ~100 ms bursts with ~130 ms gaps.
 */
public final class MainActivity extends Activity implements Link.Listener, PadView.Host, ScreenView.Listener {
    private SharedPreferences prefs;
    private Link link;
    private PadView pad;
    private ScreenView screen;
    private FrameLayout canvasLayout;
    private int streamW, streamH;
    private WifiManager.WifiLock wifiLock;
    private TextView status;
    private boolean resumed;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        prefs = getSharedPreferences("styllink", MODE_PRIVATE);
        applyIntent(getIntent());
        link = new Link(this);
        pad = new PadView(this, this);
        screen = new ScreenView(this, this);
        canvasLayout = new FrameLayout(this);
        canvasLayout.setBackgroundColor(0xFF000000);
        canvasLayout.addView(screen, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        canvasLayout.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> {
            if (r - l != or - ol || b - t != ob - ot) v.post(this::layoutScreen);
        });
        pad.setSeeThrough(showScreen());
        canvasLayout.addView(pad, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        float density = getResources().getDisplayMetrics().density;
        Button menu = new Button(this);
        menu.setText("≡");
        menu.setTextSize(24);
        menu.setTextColor(0xFFB3B8BF);
        menu.setContentDescription("Menu — connection and settings");
        menu.setPadding(0, 0, 0, 0);
        menu.setMinWidth(0);
        menu.setMinimumWidth(0);
        menu.setMinHeight(0);
        menu.setMinimumHeight(0);
        android.graphics.drawable.GradientDrawable menuBackground = new android.graphics.drawable.GradientDrawable();
        menuBackground.setColor(0xFF202327);
        menuBackground.setCornerRadius(12 * density);
        android.content.res.ColorStateList rippleColor = android.content.res.ColorStateList.valueOf(0x336F7782);
        menu.setBackground(new android.graphics.drawable.RippleDrawable(rippleColor, menuBackground, null));
        FrameLayout.LayoutParams menuPosition = new FrameLayout.LayoutParams(
                (int) (48 * density), (int) (48 * density), Gravity.TOP | Gravity.END);
        menuPosition.topMargin = menuPosition.rightMargin = (int) (12 * density);
        canvasLayout.addView(menu, menuPosition);
        menu.setOnClickListener(v -> openSettings());
        setContentView(canvasLayout);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        lp.preferredDisplayModeId = fastestMode();
        getWindow().setAttributes(lp);

        WifiManager wm = getApplicationContext().getSystemService(WifiManager.class);
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "styllink:pen");
        wifiLock.setReferenceCounted(false);

        if (host().isEmpty()) pad.post(this::openSettings);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (applyIntent(intent) && resumed) {
            link.start(host(), token());
            startScreen();
        }
    }

    /** styllink://connect?h=<ip:port>&t=<token> */
    private boolean applyIntent(Intent intent) {
        Uri d = intent != null ? intent.getData() : null;
        if (d == null || !"styllink".equals(d.getScheme()) || !"connect".equals(d.getHost())) return false;
        String h = d.getQueryParameter("h"), t = d.getQueryParameter("t");
        if (h == null || h.isEmpty()) return false;
        SharedPreferences.Editor ed = prefs.edit().putString("host", h).putString("token", t != null ? t : "");
        // l=0 turns the low-latency Wi-Fi lock off (for A/B measurements).
        String l = d.getQueryParameter("l");
        if (l != null) ed.putBoolean("wifiLock", !"0".equals(l));
        ed.apply();
        if (wifiLock != null) applyLock();
        return true;
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        hideBars();
        applyLock();
        link.start(host(), token());
        startScreen();
    }

    @Override
    protected void onPause() {
        resumed = false;
        link.stop();
        screen.stop();
        if (wifiLock.isHeld()) wifiLock.release();
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideBars();
    }

    /** Takes effect while this app is in the foreground with the screen on. */
    private void applyLock() {
        if (resumed && prefs.getBoolean("wifiLock", true)) wifiLock.acquire();
        else if (wifiLock.isHeld()) wifiLock.release();
    }

    private void hideBars() {
        getWindow().setDecorFitsSystemWindows(false);
        WindowInsetsController c = getWindow().getInsetsController();
        if (c == null) return;
        c.hide(WindowInsets.Type.systemBars());
        c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
    }

    /** Highest refresh rate at the current resolution: less latency for pen and screen. */
    private int fastestMode() {
        Display d = getDisplay();
        if (d == null) return 0;
        Display.Mode cur = d.getMode(), best = cur;
        for (Display.Mode m : d.getSupportedModes()) {
            if (m.getPhysicalWidth() == cur.getPhysicalWidth() && m.getPhysicalHeight() == cur.getPhysicalHeight()
                    && m.getRefreshRate() > best.getRefreshRate()) best = m;
        }
        return best.getModeId();
    }

    private boolean showScreen() {
        return prefs.getBoolean("screen", true);
    }

    private void startScreen() {
        pad.setSeeThrough(showScreen());
        if (!showScreen() || !resumed) {
            screen.stop();
            streamW = streamH = 0;
            layoutScreen();
            return;
        }
        ScreenView.Options o = new ScreenView.Options();
        o.frontBuffer = prefs.getBoolean("frontBuffer", true);
        o.preferH264 = prefs.getBoolean("h264", false);
        screen.start(host(), token(), o);
    }

    /** Letterboxes the screen to the PC's shape and maps the pen onto it. */
    private void layoutScreen() {
        int W = canvasLayout.getWidth(), H = canvasLayout.getHeight();
        if (W == 0 || H == 0) return;
        if (streamW == 0 || streamH == 0) {
            pad.setContent(null);
            return;
        }
        float scale = Math.min(W / (float) streamW, H / (float) streamH);
        int w = Math.round(streamW * scale), h = Math.round(streamH * scale);
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) screen.getLayoutParams();
        if (lp.width != w || lp.height != h) {
            lp.width = w;
            lp.height = h;
            lp.gravity = Gravity.CENTER;
            screen.setLayoutParams(lp);
        }
        float left = (W - w) / 2f, top = (H - h) / 2f;
        pad.setContent(new RectF(left, top, left + w, top + h));
    }

    // ------------------------------------------------------------ ScreenView.Listener

    @Override
    public void onScreenFormat(int width, int height) {
        runOnUiThread(() -> {
            streamW = width;
            streamH = height;
            screen.setStreamSize(width, height);
            layoutScreen();
        });
    }

    @Override
    public void onScreenStatus(String s) {
        runOnUiThread(this::updateStatus);
    }

    private String host() {
        return prefs.getString("host", "");
    }

    private String token() {
        return prefs.getString("token", "");
    }

    // ------------------------------------------------------------ PadView.Host

    @Override
    public Link link() {
        return link;
    }

    @Override
    public boolean fingerDrawing() {
        return prefs.getBoolean("finger", false);
    }

    @Override
    public boolean trail() {
        return prefs.getBoolean("trail", true);
    }

    @Override
    public int trailDurationMs() {
        return Math.max(100, Math.min(5000, prefs.getInt("trailMs", 900)));
    }

    private void openCamera() {
        try {
            // The camera's QR scanner launches our browsable styllink:// link.
            // No captured image, camera permission or embedded camera is needed.
            startActivity(new Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA));
            Toast.makeText(this, "Scan the PC terminal QR, then tap its link to return to StylLink.",
                    Toast.LENGTH_LONG).show();
        } catch (ActivityNotFoundException e) {
            Toast.makeText(this, "No camera app found. Enter the PC address and token below.",
                    Toast.LENGTH_LONG).show();
            openSettings();
        }
    }

    public void openSettings() {
        int pad16 = (int) (16 * getResources().getDisplayMetrics().density);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad16 + pad16 / 2, pad16, pad16 + pad16 / 2, 0);

        status = new TextView(this);
        box.addView(status);
        updateStatus();

        Button cameraButton = new Button(this);
        cameraButton.setText("Open camera to scan QR");
        box.addView(cameraButton);
        TextView scanHint = new TextView(this);
        scanHint.setText("Scan the USB or Wi-Fi QR in the PC terminal and tap its styllink:// link. USB needs debugging and port forwarding; Wi-Fi needs a shared network.");
        box.addView(scanHint);

        EditText hostIn = new EditText(this);
        hostIn.setHint("PC address, e.g. 192.168.0.75:8080");
        hostIn.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        hostIn.setText(host());
        box.addView(hostIn);
        EditText tokenIn = new EditText(this);
        tokenIn.setHint("Token (from the terminal)");
        tokenIn.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        tokenIn.setText(token());
        box.addView(tokenIn);
        Button usbButton = new Button(this);
        usbButton.setText("Use USB · localhost:8080");
        usbButton.setOnClickListener(v -> {
            hostIn.setText("localhost:8080");
            hostIn.setSelection(hostIn.length());
        });
        box.addView(usbButton);
        CheckBox finger = new CheckBox(this);
        finger.setText("Finger drawing");
        finger.setChecked(fingerDrawing());
        box.addView(finger);
        CheckBox trailBox = new CheckBox(this);
        trailBox.setText("Ink trail preview");
        trailBox.setChecked(trail());
        box.addView(trailBox);
        TextView fadeLabel = new TextView(this);
        box.addView(fadeLabel);
        SeekBar fadeSlider = new SeekBar(this);
        fadeSlider.setMax(49);
        fadeSlider.setProgress(trailDurationMs() / 100 - 1);
        fadeSlider.setContentDescription("Trail fade duration");
        fadeLabel.setText(String.format(java.util.Locale.ROOT, "Trail fade: %.1f s", trailDurationMs() / 1000f));
        fadeSlider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                fadeLabel.setText(String.format(java.util.Locale.ROOT, "Trail fade: %.1f s", (progress + 1) / 10f));
            }
            @Override public void onStartTrackingTouch(SeekBar bar) {}
            @Override public void onStopTrackingTouch(SeekBar bar) {}
        });
        box.addView(fadeSlider);

        CheckBox screenBox = new CheckBox(this);
        screenBox.setText("Show PC screen");
        screenBox.setChecked(showScreen());
        box.addView(screenBox);
        CheckBox frontBox = new CheckBox(this);
        frontBox.setText("Front-buffer screen (lowest latency, may tear)");
        frontBox.setChecked(prefs.getBoolean("frontBuffer", true));
        box.addView(frontBox);
        CheckBox h264Box = new CheckBox(this);
        h264Box.setText("Prefer H.264 screen (video, weak Wi-Fi)");
        h264Box.setChecked(prefs.getBoolean("h264", false));
        box.addView(h264Box);

        CheckBox lockBox = new CheckBox(this);
        lockBox.setText("Low-latency Wi-Fi");
        lockBox.setChecked(prefs.getBoolean("wifiLock", true));
        box.addView(lockBox);

        ScrollView settingsScroll = new ScrollView(this);
        settingsScroll.addView(box);
        AlertDialog dialog = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("StylLink")
                .setView(settingsScroll)
                .setPositiveButton("Connect", (d, w) -> {
                    String h = hostIn.getText().toString().trim().replaceFirst("^\\w+://", "").replaceFirst("/.*$", "");
                    prefs.edit()
                            .putString("host", h)
                            .putString("token", tokenIn.getText().toString().trim())
                            .putBoolean("finger", finger.isChecked())
                            .putBoolean("trail", trailBox.isChecked())
                            .putInt("trailMs", (fadeSlider.getProgress() + 1) * 100)
                            .putBoolean("wifiLock", lockBox.isChecked())
                            .putBoolean("screen", screenBox.isChecked())
                            .putBoolean("frontBuffer", frontBox.isChecked())
                            .putBoolean("h264", h264Box.isChecked())
                            .apply();
                    applyLock();
                    link.start(host(), token());
                    startScreen();
                })
                .setNegativeButton("Close", (d, w) -> {
                    prefs.edit().putBoolean("finger", finger.isChecked()).putBoolean("trail", trailBox.isChecked())
                            .putInt("trailMs", (fadeSlider.getProgress() + 1) * 100)
                            .putBoolean("wifiLock", lockBox.isChecked()).apply();
                    boolean screenChanged = screenBox.isChecked() != showScreen()
                            || frontBox.isChecked() != prefs.getBoolean("frontBuffer", true)
                            || h264Box.isChecked() != prefs.getBoolean("h264", false);
                    prefs.edit().putBoolean("screen", screenBox.isChecked())
                            .putBoolean("frontBuffer", frontBox.isChecked())
                            .putBoolean("h264", h264Box.isChecked()).apply();
                    applyLock();
                    link.sendText(caps());
                    if (screenChanged) startScreen();
                })
                .create();
        cameraButton.setOnClickListener(v -> {
            dialog.dismiss();
            openCamera();
        });
        dialog.setOnDismissListener(d -> {
            status = null;
            pad.invalidate();
            hideBars();
        });
        dialog.show();
    }

    private void updateStatus() {
        TextView s = status;
        if (s == null) return;
        String conn = link.connected
                ? "Connected to " + host() + (link.rttMs >= 0 ? String.format(" · rtt %.1f ms", link.rttMs) : "")
                : "Not connected" + (link.error.isEmpty() ? "" : " (" + link.error + ")");
        String scr = !showScreen() ? "screen: off" : screen.status.isEmpty() ? "screen: connecting" : screen.status;
        s.setText(conn + "\nLow-latency Wi-Fi: " + (wifiLock.isHeld() ? "on" : "off") + "\n" + scr);
    }

    // ------------------------------------------------------------ Link.Listener

    @Override
    public void onLinkChanged() {
        runOnUiThread(() -> {
            pad.setOnline(link.connected);
            updateStatus();
        });
    }

    /** raw, coalesced, keep-awake, trail, native app, low-latency lock held. */
    @Override
    public String caps() {
        return "i111" + (trail() ? '1' : '0') + '1' + (wifiLock.isHeld() ? '1' : '0');
    }
}
