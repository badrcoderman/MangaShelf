package android.widget;

import android.content.Context;
import android.text.Editable;
import android.text.TextWatcher;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

public class EditText extends TextView {
    private final List<TextWatcher> watchers = new ArrayList<>();
    private final InputText value = new InputText();
    private int notifying;
    public EditText(Context context) { super(context); }
    @Override public Editable getText() { return value; }
    @Override public void setText(CharSequence text) { value.replace(0, value.length(), text == null ? "" : text); }
    public void addTextChangedListener(TextWatcher watcher) {
        if (watchers.size() >= 64) throw new IllegalStateException("text_watcher_limit");
        watchers.add(Objects.requireNonNull(watcher));
    }
    public void removeTextChangedListener(TextWatcher watcher) { watchers.remove(watcher); }
    public final void mslClearWatchers() { watchers.clear(); }
    private final class InputText implements Editable {
        private final StringBuilder data = new StringBuilder();
        @Override public int length() { return data.length(); }
        @Override public char charAt(int index) { return data.charAt(index); }
        @Override public CharSequence subSequence(int start, int end) { return data.substring(start, end); }
        @Override public String toString() { return data.toString(); }
        @Override public Editable replace(int start, int end, CharSequence text) { return replace(start, end, text, 0, text.length()); }
        @Override public Editable replace(int start, int end, CharSequence text, int textStart, int textEnd) {
            Objects.checkFromToIndex(start, end, length()); Objects.requireNonNull(text);
            Objects.checkFromToIndex(textStart, textEnd, text.length());
            int inserted = textEnd - textStart;
            if ((long) length() - (end - start) + inserted > 1024 * 1024) throw new IllegalArgumentException("preference_text_limit");
            if (notifying >= 32) throw new IllegalStateException("text_watcher_recursion_limit");
            String replacement = text.subSequence(textStart, textEnd).toString();
            List<TextWatcher> listeners = List.copyOf(watchers);
            notifying++;
            try {
                String old = data.toString();
                for (TextWatcher watcher : listeners) watcher.beforeTextChanged(old, start, end - start, inserted);
                data.replace(start, end, replacement);
                for (TextWatcher watcher : listeners) watcher.onTextChanged(this, start, end - start, inserted);
                for (TextWatcher watcher : listeners) watcher.afterTextChanged(this);
            } finally { notifying--; }
            return this;
        }
        @Override public Editable insert(int where, CharSequence text) { return replace(where, where, text); }
        @Override public Editable insert(int where, CharSequence text, int start, int end) { return replace(where, where, text, start, end); }
        @Override public Editable delete(int start, int end) { return replace(start, end, ""); }
        @Override public void clear() { replace(0, length(), ""); }
        @Override public Editable append(CharSequence text) { return insert(length(), String.valueOf(text)); }
        @Override public Editable append(CharSequence text, int start, int end) { return replace(length(), length(), text == null ? "null" : text, start, end); }
        @Override public Editable append(char text) { return append(String.valueOf(text)); }
    }
}
