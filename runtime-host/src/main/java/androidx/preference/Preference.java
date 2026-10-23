package androidx.preference;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.LinkedHashSet;
import java.util.Objects;
import java.util.Set;

/** Source-owned preference state; rendering and user input belong to the native host. */
public class Preference {
    private String key;
    private String title;
    private String summary;
    private boolean enabled = true;
    private boolean visible = true;
    private Object defaultValue;
    private boolean hasDefault;
    private PreferenceScreen screen;
    private OnPreferenceChangeListener changeListener;
    private OnPreferenceClickListener clickListener;
    private final Context context;

    public Preference() { this(new Context()); }
    public Preference(Context context) { this.context = Objects.requireNonNull(context); }
    public Context getContext() { return context; }
    public String getKey() { return key; }
    public void setKey(String key) {
        if (key != null && (key.isEmpty() || key.length() > 4096)) throw new IllegalArgumentException("invalid_preference_key");
        if (screen != null && !Objects.equals(this.key, key)) throw new IllegalStateException("attached_preference_key_changed");
        this.key = key;
    }
    public CharSequence getTitle() { return title; }
    public void setTitle(CharSequence title) { this.title = text(title); }
    public CharSequence getSummary() { return summary; }
    public void setSummary(CharSequence summary) { this.summary = text(summary); }
    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public boolean isVisible() { return visible; }
    public void setVisible(boolean visible) { this.visible = visible; }
    public void setDefaultValue(Object value) { defaultValue = copyValue(value); hasDefault = true; }
    public void setOnPreferenceChangeListener(OnPreferenceChangeListener listener) { changeListener = listener; }
    public void setOnPreferenceClickListener(OnPreferenceClickListener listener) { clickListener = listener; }
    public boolean callChangeListener(Object value) { return changeListener == null || changeListener.onPreferenceChange(this, value); }

    public final boolean mslChange(Object value) {
        if (!enabled || !visible) return false;
        UserChange change = prepareUserChange(value);
        if (!change.accepted() || !callChangeListener(change.value())) return false;
        setUserValue(change.value());
        return true;
    }
    public final boolean mslClick() { return enabled && visible && clickListener != null && clickListener.onPreferenceClick(this); }
    public Object mslValue() { return null; }
    protected Object normalizeUserValue(Object value) { throw new IllegalArgumentException("preference_not_editable"); }
    protected boolean acceptUserValue(Object value) { return true; }
    protected record UserChange(boolean accepted, Object value) { }
    protected UserChange prepareUserChange(Object value) {
        Object proposed = normalizeUserValue(value);
        return new UserChange(acceptUserValue(proposed), proposed);
    }
    protected void setUserValue(Object value) { throw new IllegalArgumentException("preference_not_editable"); }
    protected void onAttached() { }
    protected void onDetached() { }
    protected final boolean hasDefaultValue() { return hasDefault; }
    protected final Object defaultValue() { return copyValue(defaultValue); }
    protected final SharedPreferences preferences() { return screen == null ? null : screen.mslPreferences(); }
    protected final boolean hasStoredValue() { return preferences() != null && key != null && preferences().contains(key); }
    protected final void persist(Object value) {
        SharedPreferences store = preferences();
        if (store == null || key == null) return;
        SharedPreferences.Editor edit = store.edit();
        if (value == null) edit.remove(key);
        else if (value instanceof String string) edit.putString(key, string);
        else if (value instanceof Boolean bool) edit.putBoolean(key, bool);
        else if (value instanceof Set<?>) edit.putStringSet(key, strings(value));
        else throw new IllegalArgumentException("unsupported_preference_value");
        edit.apply();
    }
    final void attach(PreferenceScreen owner) {
        if (screen != null) throw new IllegalStateException("preference_already_attached");
        screen = owner;
        try { onAttached(); }
        catch (RuntimeException | Error error) { screen = null; throw error; }
    }
    final void detach() {
        screen = null; changeListener = null; clickListener = null;
        onDetached();
    }
    static String text(CharSequence value) {
        if (value == null) return null;
        if (value.length() > 16_384) throw new IllegalArgumentException("preference_label_limit");
        return value.toString();
    }
    static Set<String> strings(Object value) {
        if (!(value instanceof Set<?> source) || source.size() > 4096) throw new IllegalArgumentException("invalid_preference_set");
        Set<String> result = new LinkedHashSet<>();
        long length = 0;
        for (Object item : source) {
            if (!(item instanceof String string)) throw new IllegalArgumentException("invalid_preference_set");
            length += string.length();
            if (length > 1024 * 1024) throw new IllegalArgumentException("preference_set_limit");
            result.add(string);
        }
        return result;
    }
    private static Object copyValue(Object value) {
        if (value == null || value instanceof String || value instanceof Boolean || value instanceof Number) return value;
        if (value instanceof Set<?>) return strings(value);
        throw new IllegalArgumentException("unsupported_preference_default");
    }
    public interface OnPreferenceChangeListener { boolean onPreferenceChange(Preference preference, Object newValue); }
    public interface OnPreferenceClickListener { boolean onPreferenceClick(Preference preference); }
}
