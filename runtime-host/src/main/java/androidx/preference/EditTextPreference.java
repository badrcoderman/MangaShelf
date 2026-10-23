package androidx.preference;

import android.content.Context;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;

public class EditTextPreference extends DialogPreference {
    private String value;
    private boolean provided;
    private OnBindEditTextListener bindListener;
    public EditTextPreference(Context context) { super(context); }
    public String getText() { return value; }
    public void setText(String text) { value = text; provided = true; persist(text); }
    public void setOnBindEditTextListener(OnBindEditTextListener listener) { bindListener = listener; }
    @Override protected void onAttached() {
        String initial = hasStoredValue() ? preferences().getString(getKey(), null) :
                hasDefaultValue() ? (String) defaultValue() : provided ? value : null;
        setText(initial);
    }
    public record Validation(boolean allowed, String error, String text) { }
    public final Validation mslValidateText(String proposed) {
        EditText editor = new EditText(getContext());
        View root = new View(getContext());
        Button positive = new Button(getContext()); positive.setId(android.R.id.button1);
        root.mslAddChild(editor); root.mslAddChild(positive);
        try {
            editor.setText(value == null ? "" : value);
            if (bindListener != null) bindListener.onBindEditText(editor);
            editor.setText(proposed);
            String error = editor.getError() == null ? null : editor.getError().toString();
            return new Validation(error == null && positive.isEnabled(), error, editor.getText().toString());
        } finally { editor.mslClearWatchers(); }
    }
    @Override protected Object normalizeUserValue(Object value) {
        if (!(value instanceof String)) throw new IllegalArgumentException("invalid_preference_string");
        return value;
    }
    @Override protected UserChange prepareUserChange(Object value) {
        Validation validation = mslValidateText((String) normalizeUserValue(value));
        return new UserChange(validation.allowed(), validation.text());
    }
    @Override protected void setUserValue(Object value) { setText((String) value); }
    @Override protected void onDetached() { bindListener = null; }
    @Override public Object mslValue() { return value; }
    public interface OnBindEditTextListener { void onBindEditText(EditText editText); }
}
