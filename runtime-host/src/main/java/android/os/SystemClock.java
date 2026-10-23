package android.os;

/** Monotonic VM clock for source request intervals; no adjustable wall-clock time. */
public final class SystemClock {
    private SystemClock() { }
    public static long elapsedRealtime() { return System.nanoTime() / 1_000_000L; }
    public static long elapsedRealtimeNanos() { return System.nanoTime(); }
}
