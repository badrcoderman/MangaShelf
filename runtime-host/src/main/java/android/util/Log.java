package android.util;

import java.io.PrintWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;

/** Source diagnostics go to the host's captured stderr; no plugin objects are retained. */
public final class Log {
    public static final int VERBOSE = 2, DEBUG = 3, INFO = 4, WARN = 5, ERROR = 6, ASSERT = 7;
    private static final int LIMIT = 16_384;
    private Log() { }
    public static int v(String tag, String message) { return write(VERBOSE, tag, message, null); }
    public static int v(String tag, String message, Throwable error) { return write(VERBOSE, tag, message, error); }
    public static int d(String tag, String message) { return write(DEBUG, tag, message, null); }
    public static int d(String tag, String message, Throwable error) { return write(DEBUG, tag, message, error); }
    public static int i(String tag, String message) { return write(INFO, tag, message, null); }
    public static int i(String tag, String message, Throwable error) { return write(INFO, tag, message, error); }
    public static int w(String tag, String message) { return write(WARN, tag, message, null); }
    public static int w(String tag, String message, Throwable error) { return write(WARN, tag, message, error); }
    public static int w(String tag, Throwable error) { return write(WARN, tag, null, error); }
    public static int e(String tag, String message) { return write(ERROR, tag, message, null); }
    public static int e(String tag, String message, Throwable error) { return write(ERROR, tag, message, error); }
    public static int wtf(String tag, String message) { return write(ASSERT, tag, message, null); }
    public static int wtf(String tag, String message, Throwable error) { return write(ASSERT, tag, message, error); }
    public static int wtf(String tag, Throwable error) { return write(ASSERT, tag, null, error); }
    public static boolean isLoggable(String tag, int priority) { return priority >= VERBOSE && priority <= ASSERT; }
    public static int println(int priority, String tag, String message) { return write(priority, tag, message, null); }
    public static String getStackTraceString(Throwable error) {
        if (error == null) return "";
        LimitedWriter writer = new LimitedWriter();
        error.printStackTrace(new PrintWriter(writer));
        return writer.toString();
    }
    private static int write(int priority, String tag, String message, Throwable error) {
        if (!isLoggable(tag, priority)) return 0;
        String line = "[source/" + priority + "/" + bounded(tag, 128) + "] " + bounded(message, LIMIT);
        if (error != null) line = bounded(line + "\n" + getStackTraceString(error), LIMIT);
        System.err.println(line);
        return line.getBytes(StandardCharsets.UTF_8).length;
    }
    private static String bounded(String value, int maximum) {
        if (value == null) return "";
        return value.length() <= maximum ? value : value.substring(0, maximum);
    }
    private static final class LimitedWriter extends Writer {
        private final StringBuilder text = new StringBuilder();
        @Override public void write(char[] chars, int start, int count) {
            int remaining = LIMIT - text.length();
            if (remaining > 0) text.append(chars, start, Math.min(count, remaining));
        }
        @Override public void write(String value, int start, int count) {
            int remaining = LIMIT - text.length();
            if (remaining > 0) text.append(value, start, start + Math.min(count, remaining));
        }
        @Override public void flush() { }
        @Override public void close() { }
        @Override public String toString() { return text.toString(); }
    }
}
