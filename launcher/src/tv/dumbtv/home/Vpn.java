package tv.dumbtv.home;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;

/**
 * OpenTelV: brings one WireGuard tunnel up once per boot, after the network is up.
 *
 * <p>Android's always-on VPN starts the tunnel before the network (Wi-Fi or Ethernet) is up, so
 * the endpoint does not resolve and the tunnel has no route; it also keeps the VPN slot, so
 * Tailscale refuses to start. This asks WireGuard to switch the tunnel on (its {@code SET_TUNNEL_UP} intent) once the
 * default network has internet, and checks a VPN came up, retrying a few times. Nothing holds the
 * slot: switching the tunnel off in WireGuard, or using Tailscale instead, sticks until the next
 * boot.
 *
 * <p>Needs WireGuard's {@code CONTROL_TUNNELS} permission ({@code pm grant}, from
 * opentelv/vpn.sh) and WireGuard › Settings › Allow remote control apps.
 */
final class Vpn {
    private static final String TAG = "dumbtv";
    static final String WG = "com.wireguard.android";
    static final String CONTROL = WG + ".permission.CONTROL_TUNNELS";
    /** The tunnel to bring up at boot; empty = none. */
    private static final String KEY = "vpn.boot";
    /** The boot the tunnel was last brought up (or given up on) for. */
    private static final String DONE = "vpn.done";
    private static final String NAME = "[A-Za-z0-9_=+.-]{1,15}";

    /** Wait after the network validates, so DNS is answering when WireGuard resolves the endpoint. */
    private static final long SETTLE_MS = 5_000;
    /** Some TVs never mark the network validated (their check host is blocked); start anyway. */
    private static final long UNVALIDATED_MS = 30_000;
    private static final long CHECK_MS = 20_000;
    private static final int TRIES = 5;

    private static boolean running;

    private Vpn() {}

    /** From the home screen's start and the boot receiver: once per boot. */
    static void boot(Context c) {
        start(c.getApplicationContext(), false);
    }

    private static void start(final Context c, boolean now) {
        final Config cfg = Config.get(c);
        cfg.refresh();
        final String tunnel = cfg.get(KEY, "");
        if (tunnel.isEmpty() || running) return;
        final String boot = bootId(c);
        if (!now && boot.equals(cfg.get(DONE, ""))) return;
        if (c.checkSelfPermission(CONTROL) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "vpn: no " + CONTROL + "; run opentelv/vpn.sh on");
            return;
        }
        final ConnectivityManager cm = c.getSystemService(ConnectivityManager.class);
        if (cm == null) return;
        running = true;

        final Handler main = new Handler(Looper.getMainLooper());
        final ConnectivityManager.NetworkCallback[] watch = new ConnectivityManager.NetworkCallback[1];
        final Runnable finish = () -> {
            running = false;
            try {
                cm.unregisterNetworkCallback(watch[0]);
            } catch (IllegalArgumentException ignored) {
                // already unregistered
            }
            cfg.set(DONE, boot);
        };
        final Runnable attempt = new Runnable() {
            int tries;

            @Override
            public void run() {
                if (vpnUp(cm)) {
                    Log.i(TAG, "vpn: up" + (tries == 0 ? " already, leaving it" : " (" + tunnel + ")"));
                    finish.run();
                } else if (tries == TRIES) {
                    Log.w(TAG, "vpn: " + tunnel + " did not come up; is WireGuard's Allow remote control apps on?");
                    finish.run();
                } else {
                    tries++;
                    Log.i(TAG, "vpn: asking WireGuard for " + tunnel + " (" + tries + "/" + TRIES + ")");
                    // FOREGROUND: WireGuard is in the background at boot, and Android only lets a
                    // background app start its VPN service while it handles a foreground broadcast.
                    c.sendBroadcast(new Intent(WG + ".action.SET_TUNNEL_UP")
                            .setPackage(WG)
                            .putExtra("tunnel", tunnel)
                            .addFlags(Intent.FLAG_RECEIVER_FOREGROUND));
                    main.postDelayed(this, CHECK_MS);
                }
            }
        };
        final boolean[] started = {false};
        final Runnable go = () -> {
            if (started[0]) return;
            started[0] = true;
            attempt.run();
        };
        // Called on a connectivity thread; the decisions happen on the main thread.
        watch[0] = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onCapabilitiesChanged(Network n, NetworkCapabilities caps) {
                if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return;
                final long wait = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ? 0
                        : caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) ? SETTLE_MS
                        : UNVALIDATED_MS;
                main.post(() -> {
                    if (started[0]) return;
                    main.removeCallbacks(go);
                    main.postDelayed(go, wait);
                });
            }

            @Override
            public void onLost(Network n) {
                main.post(() -> main.removeCallbacks(go));
            }
        };
        try {
            cm.registerDefaultNetworkCallback(watch[0]);
        } catch (RuntimeException e) {
            Log.w(TAG, "vpn: cannot watch the network", e);
            running = false;
        }
    }

    private static boolean vpnUp(ConnectivityManager cm) {
        for (Network n : cm.getAllNetworks()) {
            NetworkCapabilities caps = cm.getNetworkCapabilities(n);
            if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return true;
        }
        return false;
    }

    /** Same for every start of the home screen within one boot. */
    private static String bootId(Context c) {
        int count = Settings.Global.getInt(c.getContentResolver(), Settings.Global.BOOT_COUNT, -1);
        if (count >= 0) return "count:" + count;
        return "time:" + (System.currentTimeMillis() - SystemClock.elapsedRealtime()) / 60_000L;
    }

    /**
     * {@code am broadcast -n tv.dumbtv.home/.Vpn\$Set --es tunnel home [--ez now true]}: the tunnel
     * to bring up at boot (empty = none), and with {@code now} also bring it up right away. With
     * no extras it only answers. The result data is {@code tunnel=<name> control=<granted|missing>}.
     */
    public static final class Set extends BroadcastReceiver {
        @Override
        public void onReceive(Context c, Intent i) {
            Config cfg = Config.get(c);
            cfg.refresh();
            if (i.hasExtra("tunnel")) {
                String t = i.getStringExtra("tunnel");
                t = t == null ? "" : t.trim();
                if (!t.isEmpty() && !t.matches(NAME)) {
                    setResultCode(0);
                    setResultData("bad tunnel name");
                    return;
                }
                cfg.set(KEY, t);
                cfg.set(DONE, "");
                Log.i(TAG, "vpn: at boot " + (t.isEmpty() ? "(nothing)" : t));
                if (!t.isEmpty() && i.getBooleanExtra("now", false)) start(c.getApplicationContext(), true);
            }
            boolean granted = c.checkSelfPermission(CONTROL) == PackageManager.PERMISSION_GRANTED;
            setResultCode(1);
            setResultData("tunnel=" + cfg.get(KEY, "") + " control=" + (granted ? "granted" : "missing"));
        }
    }
}
