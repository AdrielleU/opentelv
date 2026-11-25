package tv.dumbtv.home;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import java.io.File;

/**
 * OpenTelV: Options › Export settings, from adb, for opentelv/backup.sh.
 * {@code am broadcast -n tv.dumbtv.home/.Export} writes home-export.conf into the media folder
 * (the one adb can read on Fire OS 8) and answers with its path, or "" when it could not.
 */
public final class Export extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        Config cfg = Config.get(c);
        cfg.refresh();
        File copy = cfg.export();
        setResultCode(copy == null ? 0 : 1);
        setResultData(copy == null ? "" : copy.getPath());
    }
}
