package android.widget;

import android.content.Context;
import android.view.View;

public class TextView extends View {
    private String text = "";
    private String error;
    public TextView(Context context) { super(context); }
    public CharSequence getText() { return text; }
    public void setText(CharSequence text) { this.text = text == null ? "" : text.toString(); }
    public CharSequence getError() { return error; }
    public void setError(CharSequence error) {
        if (error != null && error.length() > 16_384) throw new IllegalArgumentException("preference_error_limit");
        this.error = error == null ? null : error.toString();
    }
}
