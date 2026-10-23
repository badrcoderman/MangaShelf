package android.view;

import android.content.Context;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/** Headless dialog state for source validation callbacks, not an Android surface. */
public class View {
    private final Context context;
    private final List<View> children = new ArrayList<>();
    private View parent;
    private int id = -1;
    private boolean enabled = true;
    public View(Context context) { this.context = Objects.requireNonNull(context); }
    public Context getContext() { return context; }
    public int getId() { return id; }
    public void setId(int id) { this.id = id; }
    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public View getRootView() { return parent == null ? this : parent.getRootView(); }
    @SuppressWarnings("unchecked")
    public <T extends View> T findViewById(int id) {
        if (id < 0) return null;
        if (this.id == id) return (T) this;
        for (View child : children) {
            T found = child.findViewById(id);
            if (found != null) return found;
        }
        return null;
    }
    public final void mslAddChild(View child) {
        Objects.requireNonNull(child);
        if (child == this || child.parent != null || getRootView() == child) throw new IllegalArgumentException("invalid_dialog_child");
        if (children.size() >= 32) throw new IllegalStateException("dialog_child_limit");
        children.add(child); child.parent = this;
    }
}
