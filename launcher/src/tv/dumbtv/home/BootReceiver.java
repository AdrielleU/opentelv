package tv.dumbtv.home;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Puts the home keeper back after a reboot or an update. */
public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        Keeper.start(context);
        Vpn.boot(context); // OpenTelV: Fire OS 6, where this receiver runs at boot
    }
}
