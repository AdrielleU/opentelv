package tv.dumbtv.home;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.text.Collator;
import java.util.Collections;
import java.util.List;

/**
 * OpenTelV: every launchable app, hidden ones included, strictly A to Z by the name its tile
 * shows. Hidden apps are dimmed; holding OK shows or hides one on the home screen.
 */
public final class AllApps extends Activity {
    private static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;
    /** Hidden apps are drawn at this opacity. */
    private static final float HIDDEN = 0.4f;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private Config cfg;
    private Grid grid;
    private TextView count;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        cfg = Config.get(this);

        ScrollView scroll = new ScrollView(this);
        scroll.setFocusable(false);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.setBackgroundColor(0xFF0C0C0E);
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(dp(56), dp(40), dp(56), dp(40));
        scroll.addView(list);

        TextView title = Ui.text(this, 30, Ui.TEXT, Ui.LIGHT);
        title.setText("All apps");
        list.addView(title);
        count = Ui.text(this, 14, Ui.MUTED, Ui.MEDIUM);
        count.setPadding(0, dp(8), 0, dp(20));
        list.addView(count);

        grid = new Grid(this);
        String columns = cfg.get(Config.COLUMNS);
        grid.setMaxColumns("auto".equals(columns) ? 0 : Integer.parseInt(columns));
        list.addView(grid, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, WRAP));

        setContentView(scroll);
        new Thread(() -> {
            List<Item> all = Catalog.apps(this);
            ui.post(() -> show(all));
        }).start();
    }

    private void show(List<Item> all) {
        // Strictly alphabetical by the label on the tile (a renamed app sorts by its new
        // name), ignoring case; the package name breaks ties so the order never shuffles.
        Collator collator = Collator.getInstance();
        collator.setStrength(Collator.SECONDARY);
        Collections.sort(all, (a, b) -> {
            int c = collator.compare(Catalog.label(cfg, a).toString(), Catalog.label(cfg, b).toString());
            return c != 0 ? c : a.id.compareTo(b.id);
        });
        int[] size = cardSize();
        int hidden = 0;
        for (Item it : all) {
            Tile t = new Tile(this, it, Catalog.APPS, Catalog.label(cfg, it), size[0], size[1],
                    "always", cfg.accent());
            boolean shown = Catalog.shown(cfg, Catalog.APPS, it);
            if (!shown) hidden++;
            t.setAlpha(shown ? 1f : HIDDEN);
            t.setOnClickListener(v -> launch(it));
            t.setOnLongClickListener(v -> {
                menu((Tile) v);
                return true;
            });
            grid.addView(t, new ViewGroup.LayoutParams(WRAP, WRAP));
            loadArt(it, t);
        }
        count.setText(all.size() + " apps · " + hidden + " hidden · hold OK to show or hide");
        if (grid.getChildCount() > 0) grid.getChildAt(0).requestFocus();
    }

    private void loadArt(Item it, Tile t) {
        new Thread(() -> {
            Catalog.art(getPackageManager(), it);
            ui.post(t::invalidate);
        }).start();
    }

    private void menu(Tile t) {
        boolean shown = Catalog.shown(cfg, Catalog.APPS, t.item);
        new AlertDialog.Builder(this, Ui.DIALOG)
                .setTitle(Catalog.label(cfg, t.item))
                .setItems(new String[] {shown ? "Hide from home screen" : "Show on home screen", "App info"},
                        (d, which) -> {
                            if (which == 0) {
                                Catalog.setShown(cfg, Catalog.APPS, t.item, !shown);
                                t.setAlpha(shown ? HIDDEN : 1f);
                                Toast.makeText(this, shown ? "Hidden from home screen" : "On the home screen",
                                        Toast.LENGTH_SHORT).show();
                            } else {
                                start(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.fromParts("package", t.item.id, null)));
                            }
                        })
                .show();
    }

    private void launch(Item it) {
        // As on the home screen: Amazon's launcher is let through rather than bounced back.
        if (Guard.AMAZON.equals(it.id)) Guard.pause();
        start(new Intent(it.intent));
    }

    private void start(Intent i) {
        try {
            startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED));
        } catch (ActivityNotFoundException | SecurityException e) {
            Toast.makeText(this, "Could not open that", Toast.LENGTH_SHORT).show();
        }
    }

    /** Same card sizes as the home screen's Options › Tile size. */
    private int[] cardSize() {
        switch (cfg.get(Config.TILES)) {
            case "small":
                return new int[] {dp(144), dp(81)};
            case "large":
                return new int[] {dp(224), dp(126)};
            default:
                return new int[] {dp(180), dp(101)};
        }
    }

    private int dp(float v) {
        return Ui.dp(this, v);
    }
}
