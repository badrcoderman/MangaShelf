package android.os;

/** Source header compatibility; the host supplies its real platform release. */
public final class Build {
    private Build() { }
    public static final class VERSION {
        private VERSION() { }
        public static String RELEASE = System.getProperty("os.version", "unknown");
    }
    public static String validateRelease(String release) {
        if (release == null || release.isEmpty() || release.length() > 128 ||
                release.chars().anyMatch(value -> value < 32 || value > 126)) {
            throw new IllegalArgumentException("invalid_platform_release");
        }
        return release;
    }
}
