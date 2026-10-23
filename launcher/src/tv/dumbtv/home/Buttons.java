package tv.dumbtv.home;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * OpenTelV: remote app buttons (YouTube, Netflix, ...) opening an app of the owner's choice.
 *
 * Fire OS consumes those buttons before any app or accessibility service sees them, but the
 * system logs each press as an Appstore start with the button's tag, e.g. {@code START u0
 * {... com.amazon.venezia/.pdi.AppLaunchActivity ... clickStreamReftag=r_btn_app_33 ...}
 * from uid 1000}, whether or not the button's own app is installed. With READ_LOGS
 * (development permission, granted once over adb) the Guard follows that log; a tag mapped in
 * home.conf as {@code button.<tag>=<package>} opens that package instead. Only uid 1000
 * starts carry the tag, so opening the same apps from the home screen is never redirected.
 *
 * Mappings arrive from opentelv/buttons.sh through {@link Map}, which only the shell and the
 * system can send to (it requires DUMP): Fire OS 8 keeps home.conf out of adb's reach.
 */
final class Buttons {
    private static final String TAG = "OpenTelV";
    static final String PREFIX = "button.";
    private static final Pattern START = Pattern.compile("START u0 \\{(.*)\\} from uid (\\d+)");
    private static final Pattern BUTTON = Pattern.compile("clickStreamReftag=(r_btn_[A-Za-z0-9_]+)");
    /** Back-off before a dead logcat is restarted, so a missing grant cannot spin. */
    private static final long RESTART_MS = 2_000L;

    /**
     * One press can arrive twice: Fire OS 8 writes the start line to both the system and the
     * main buffer, and both are read. A repeat of the same tag this soon is the same press.
     */
    private static final long SAME_PRESS_MS = 700L;

    private static volatile boolean running;
    private static String lastTag;
    private static long lastAt;
    private static volatile Process proc;

    private Buttons() {}

    static void start(Context c) {
        if (running) return;
        running = true;
        Context app = c.getApplicationContext();
        Handler main = new Handler(Looper.getMainLooper());
        Thread t = new Thread(() -> {
            while (running) {
                follow(app, main);
                try {
                    Thread.sleep(RESTART_MS);
                } catch (InterruptedException e) {
                    return;
                }
            }
        }, "opentelv-buttons");
        t.setDaemon(true);
        t.start();
    }

    static void stop() {
        running = false;
        restartLog();
    }

    /**
     * Ends the current logcat; the reader thread starts a new one. Needed after READ_LOGS is
     * granted: logd decides what a reader may see when it connects, so a logcat started
     * before the grant never shows system lines.
     */
    static void restartLog() {
        Process p = proc;
        if (p != null) p.destroy();
    }

    /**
     * Reads new log lines until logcat ends. The start lines are in the system buffer on
     * Fire OS 8 (AFTMA08C15, RS8185.3891N); main is read as well in case a build differs.
     * Fire OS 7 logs them as ActivityManager.
     */
    private static void follow(Context c, Handler main) {
        try {
            proc = new ProcessBuilder("logcat", "-b", "system", "-b", "main", "-v", "brief", "-T", "1",
                    "ActivityTaskManager:I", "ActivityManager:I", "*:S")
                    .redirectErrorStream(true).start();
            BufferedReader r = new BufferedReader(new InputStreamReader(proc.getInputStream()));
            String line;
            while (running && (line = r.readLine()) != null) {
                String tag = pressed(line);
                if (tag != null) main.post(() -> open(c, tag));
            }
        } catch (Exception e) {
            Log.w(TAG, "button log unavailable: " + e);
        } finally {
            Process p = proc;
            if (p != null) p.destroy();
            proc = null;
        }
    }

    /** The button tag of a system-started Appstore hop, or null for any other line. */
    static String pressed(String line) {
        Matcher m = START.matcher(line);
        if (!m.find() || !"1000".equals(m.group(2))) return null;
        Matcher b = BUTTON.matcher(m.group(1));
        return b.find() ? b.group(1) : null;
    }

    private static void open(Context c, String tag) {
        long now = android.os.SystemClock.uptimeMillis();
        if (tag.equals(lastTag) && now - lastAt < SAME_PRESS_MS) return;
        lastTag = tag;
        lastAt = now;
        Config cfg = Config.get(c);
        cfg.refresh();
        String pkg = cfg.get(PREFIX + tag, "");
        if (pkg.isEmpty()) {
            Log.i(TAG, "remote button " + tag + ": not mapped");
            return;
        }
        Log.i(TAG, "remote button " + tag + " -> " + pkg);
        Intent target = c.getPackageManager().getLeanbackLaunchIntentForPackage(pkg);
        if (target == null) target = c.getPackageManager().getLaunchIntentForPackage(pkg);
        if (target == null) {
            Log.w(TAG, tag + " is mapped to " + pkg + ", which is not installed");
            return;
        }
        // Home first, so the Appstore page the button opened ends up behind it and Back
        // from the mapped app lands on the home screen, not on that page.
        Intent home = new Intent(c, Home.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        Intent app = target.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        try {
            c.startActivity(home);
            new Handler(Looper.getMainLooper()).postDelayed(() -> c.startActivity(app), 150);
        } catch (RuntimeException e) {
            Log.w(TAG, "could not open " + pkg + ": " + e);
        }
    }

    /**
     * {@code am broadcast -n tv.dumbtv.home/.Buttons\$Map --es tag r_btn_app_33 --es pkg <pkg>};
     * an empty pkg removes the mapping.
     */
    public static final class Map extends BroadcastReceiver {
        @Override
        public void onReceive(Context c, Intent i) {
            String tag = i.getStringExtra("tag");
            if (tag == null || !tag.matches("r_btn_[A-Za-z0-9_]+")) return;
            String pkg = i.getStringExtra("pkg");
            Config cfg = Config.get(c);
            cfg.refresh();
            cfg.set(PREFIX + tag, pkg == null ? "" : pkg.trim());
            Log.i(TAG, "mapped " + tag + " -> " + (pkg == null || pkg.isEmpty() ? "(nothing)" : pkg));
            restartLog();
            setResultCode(1);
        }
    }
}
