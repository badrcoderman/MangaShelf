package androidx.preference;

import android.content.Context;
import android.content.SharedPreferences;
import android.preference.PreferenceManager;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/** Bounded source-owned screen model. Access it on its source operation/actor. */
public class PreferenceScreen implements AutoCloseable {
    private final Context context;
    private final SharedPreferences preferences;
    private final List<Preference> rows = new ArrayList<>();
    private boolean closed;
    public PreferenceScreen() { this(new Context()); }
    public PreferenceScreen(Context context) { this(context, PreferenceManager.getDefaultSharedPreferences(context)); }
    public PreferenceScreen(Context context, SharedPreferences preferences) {
        this.context = Objects.requireNonNull(context); this.preferences = Objects.requireNonNull(preferences);
    }
    public Context getContext() { return context; }
    SharedPreferences mslPreferences() { return preferences; }
    public boolean addPreference(Preference preference) {
        ensureOpen(); Objects.requireNonNull(preference);
        if (rows.contains(preference)) return false;
        if (rows.size() >= 512) throw new IllegalStateException("preference_screen_limit");
        if (preference.getKey() != null && rows.stream().anyMatch(row -> preference.getKey().equals(row.getKey()))) {
            throw new IllegalArgumentException("duplicate_preference_key");
        }
        rows.add(preference);
        try { preference.attach(this); }
        catch (RuntimeException | Error error) { rows.remove(preference); throw error; }
        return true;
    }
    public List<Preference> mslRows() { ensureOpen(); return List.copyOf(rows); }
    private void ensureOpen() { if (closed) throw new IllegalStateException("preference_screen_closed"); }
    @Override public void close() {
        if (closed) return;
        closed = true;
        Throwable failure = null;
        for (Preference row : rows) {
            try { row.detach(); }
            catch (RuntimeException | Error error) { if (failure == null) failure = error; else if (failure != error) failure.addSuppressed(error); }
        }
        rows.clear();
        if (failure instanceof RuntimeException error) throw error;
        if (failure instanceof Error error) throw error;
    }
}
