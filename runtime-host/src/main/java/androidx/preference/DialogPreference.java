package androidx.preference;

import android.content.Context;

public abstract class DialogPreference extends Preference {
    private String dialogTitle;
    private String dialogMessage;
    public DialogPreference() { super(); }
    protected DialogPreference(Context context) { super(context); }
    public CharSequence getDialogTitle() { return dialogTitle; }
    public void setDialogTitle(CharSequence title) { dialogTitle = text(title); }
    public CharSequence getDialogMessage() { return dialogMessage; }
    public void setDialogMessage(CharSequence message) { dialogMessage = text(message); }
}
