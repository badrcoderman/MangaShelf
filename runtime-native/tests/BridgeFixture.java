package mangashelf.bridgefixture;

import java.util.concurrent.atomic.AtomicInteger;

/** Project-owned deterministic bridge fixture. It never loads an extension. */
public final class BridgeFixture {
    private static final AtomicInteger calls = new AtomicInteger();
    private static volatile boolean entered;
    private static volatile boolean released;

    public static final class BrokenInitializer {
        static {
            if (System.nanoTime() != Long.MIN_VALUE) throw new IllegalStateException("expected initializer failure");
        }
        public static String dispatch(String action, String payload) { return payload; }
    }

    public static String dispatch(String action, String payload) throws InterruptedException {
        if (action.equals("calls")) return Integer.toString(calls.get());
        if (action.equals("entered")) return Boolean.toString(entered);
        if (action.equals("release")) { released = true; return "released"; }
        calls.incrementAndGet();
        switch (action) {
            case "large": return "x".repeat(100_000) + "العربية📚";
            case "oversize": return "x".repeat(16 * 1024 * 1024 + 1);
            case "throw": throw new IllegalStateException("project-owned expected failure");
            case "null": return null;
            case "nul": return "a\u0000b";
            case "blocked":
                entered = true;
                while (!released) Thread.sleep(1);
                return "finished";
            default: return payload;
        }
    }
}
