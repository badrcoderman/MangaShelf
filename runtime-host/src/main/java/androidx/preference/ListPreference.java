package androidx.preference;

import android.content.Context;
import java.util.IllegalFormatException;
import java.util.Locale;
import java.util.Objects;

public class ListPreference extends Preference {
    private CharSequence[] entries;
    private CharSequence[] entryValues;
    private String value;
    private boolean provided;
    public ListPreference(Context context) { super(context); }
    public CharSequence[] getEntries() { return entries == null ? null : entries.clone(); }
    public void setEntries(CharSequence[] entries) { this.entries = copyEntries(entries); }
    public CharSequence[] getEntryValues() { return entryValues == null ? null : entryValues.clone(); }
    public void setEntryValues(CharSequence[] values) { entryValues = copyEntries(values); }
    public String getValue() { return value; }
    public void setValue(String value) { this.value = value; provided = true; persist(value); }
    public void setValueIndex(int index) {
        if (entryValues == null || index < 0 || index >= entryValues.length) throw new IllegalArgumentException("invalid_preference_choice");
        setValue(entryValues[index].toString());
    }
    public int findIndexOfValue(String value) {
        if (entryValues != null && value != null) for (int i = entryValues.length - 1; i >= 0; i--) {
            if (Objects.equals(entryValues[i].toString(), value)) return i;
        }
        return -1;
    }
    @Override public CharSequence getSummary() {
        CharSequence summary = super.getSummary();
        if (summary == null) return null;
        int index = findIndexOfValue(value);
        String label = entries != null && index >= 0 && index < entries.length ? entries[index].toString() : "";
        try { return String.format(Locale.ROOT, summary.toString(), label); }
        catch (IllegalFormatException error) { return summary; }
    }
    @Override protected void onAttached() {
        String initial = hasStoredValue() ? preferences().getString(getKey(), null) :
                hasDefaultValue() ? (String) defaultValue() : provided ? value : null;
        setValue(initial);
    }
    @Override protected Object normalizeUserValue(Object value) {
        if (!(value instanceof String)) throw new IllegalArgumentException("invalid_preference_string");
        return value;
    }
    @Override protected boolean acceptUserValue(Object value) { return entryValues == null || findIndexOfValue((String) value) >= 0; }
    @Override protected void setUserValue(Object value) { setValue((String) value); }
    @Override public Object mslValue() { return value; }
    static CharSequence[] copyEntries(CharSequence[] source) {
        if (source == null) return null;
        if (source.length > 2048) throw new IllegalArgumentException("preference_choice_limit");
        CharSequence[] result = new CharSequence[source.length];
        for (int i = 0; i < source.length; i++) result[i] = Objects.requireNonNull(text(source[i]));
        return result;
    }
}
