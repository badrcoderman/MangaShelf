package androidx.preference;

import android.content.Context;
import java.util.LinkedHashSet;
import java.util.Objects;
import java.util.Set;

public class MultiSelectListPreference extends DialogPreference {
    private CharSequence[] entries;
    private CharSequence[] entryValues;
    private Set<String> values = new LinkedHashSet<>();
    private boolean provided;
    public MultiSelectListPreference(Context context) { super(context); }
    public CharSequence[] getEntries() { return entries == null ? null : entries.clone(); }
    public void setEntries(CharSequence[] entries) { this.entries = ListPreference.copyEntries(entries); }
    public CharSequence[] getEntryValues() { return entryValues == null ? null : entryValues.clone(); }
    public void setEntryValues(CharSequence[] values) { entryValues = ListPreference.copyEntries(values); }
    public Set<String> getValues() { return new LinkedHashSet<>(values); }
    public void setValues(Set<String> values) { this.values = strings(values); provided = true; persist(this.values); }
    public int findIndexOfValue(String value) {
        if (entryValues != null && value != null) for (int i = entryValues.length - 1; i >= 0; i--) {
            if (Objects.equals(entryValues[i].toString(), value)) return i;
        }
        return -1;
    }
    @Override protected void onAttached() {
        Set<String> initial = hasStoredValue() ? preferences().getStringSet(getKey(), Set.of()) :
                hasDefaultValue() ? strings(defaultValue()) : provided ? values : Set.of();
        setValues(initial);
    }
    @Override protected Object normalizeUserValue(Object value) { return strings(value); }
    @Override protected boolean acceptUserValue(Object value) {
        if (entryValues == null) return true;
        return strings(value).stream().allMatch(item -> findIndexOfValue(item) >= 0);
    }
    @Override protected void setUserValue(Object value) { setValues(strings(value)); }
    @Override public Object mslValue() { return getValues(); }
}
