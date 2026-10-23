package androidx.preference;

import android.content.Context;

public class TwoStatePreference extends Preference {
    private boolean checked;
    private boolean provided;
    private boolean disableDependents;
    private String summaryOn;
    private String summaryOff;
    public TwoStatePreference(Context context) { super(context); }
    public boolean isChecked() { return checked; }
    public void setChecked(boolean checked) { this.checked = checked; provided = true; persist(checked); }
    public boolean getDisableDependentsState() { return disableDependents; }
    public void setDisableDependentsState(boolean state) { disableDependents = state; }
    public CharSequence getSummaryOn() { return summaryOn; }
    public void setSummaryOn(CharSequence summary) { summaryOn = text(summary); }
    public CharSequence getSummaryOff() { return summaryOff; }
    public void setSummaryOff(CharSequence summary) { summaryOff = text(summary); }
    @Override protected void onAttached() {
        boolean initial = hasStoredValue() ? preferences().getBoolean(getKey(), false) :
                hasDefaultValue() ? Boolean.TRUE.equals(defaultValue()) : provided && checked;
        setChecked(initial);
    }
    @Override protected Object normalizeUserValue(Object value) {
        if (!(value instanceof Boolean)) throw new IllegalArgumentException("invalid_preference_boolean");
        return value;
    }
    @Override protected void setUserValue(Object value) { setChecked((Boolean) value); }
    @Override public Object mslValue() { return checked; }
}
