package android.text;

/** Plain text editing contract used by source preference validators; no spans/layout. */
public interface Editable extends CharSequence, Appendable {
    Editable replace(int start, int end, CharSequence text);
    Editable replace(int start, int end, CharSequence text, int textStart, int textEnd);
    Editable insert(int where, CharSequence text);
    Editable insert(int where, CharSequence text, int start, int end);
    Editable delete(int start, int end);
    void clear();
    @Override Editable append(CharSequence text);
    @Override Editable append(CharSequence text, int start, int end);
    @Override Editable append(char text);
}
