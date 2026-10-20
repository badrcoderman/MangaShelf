package mangashelf.probe;

import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/** Runs only project-owned test code, callable from a future iOS JNI harness. */
public final class RuntimeProbe {
    private static void require(boolean ok, String detail) {
        if (!ok) throw new IllegalStateException(detail);
    }
    public static String run(String pluginPath, String writableDirectory) throws Exception {
        require(Runtime.version().feature() >= 17, "Java 17 or later required");
        Path plugin = Path.of(pluginPath);
        require(Files.isRegularFile(plugin), "Probe JAR missing");
        try (URLClassLoader loader = new URLClassLoader(new java.net.URL[]{plugin.toUri().toURL()}, ClassLoader.getPlatformClassLoader())) {
            Class<?> type = loader.loadClass("probe.SourceProbe");
            require(type.getClassLoader() == loader, "Fixture must load from separate JAR");
            Object instance = type.getDeclaredConstructor().newInstance();
            require("MangaShelf runtime probe".equals(type.getMethod("title").invoke(instance)), "Reflection failed");
            require("مانغا 📚".equals(type.getMethod("unicode").invoke(instance)), "UTF-16 failed");
        }
        var executor = Executors.newSingleThreadExecutor();
        try { require(executor.submit(() -> 42).get(10, TimeUnit.SECONDS) == 42, "Worker thread failed"); }
        finally { executor.shutdownNow(); }
        byte[] plain = "MangaShelf مانغا".getBytes(StandardCharsets.UTF_8);
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        try (var gzip = new GZIPOutputStream(buffer)) { gzip.write(plain); }
        try (var gzip = new GZIPInputStream(new ByteArrayInputStream(buffer.toByteArray()))) {
            require(java.util.Arrays.equals(plain, gzip.readAllBytes()), "GZIP failed");
        }
        Path root = Path.of(writableDirectory);
        require(Files.isDirectory(root), "Writable directory missing");
        Path test = Files.createTempFile(root, "mangashelf-probe-", ".tmp");
        try { Files.write(test, plain); require(java.util.Arrays.equals(plain, Files.readAllBytes(test)), "File I/O failed"); }
        finally { Files.deleteIfExists(test); }
        return "PASS: separate JAR, reflection, Unicode, thread, GZIP, file I/O";
    }

    /** Device diagnostics survive the bridge clearing a Java exception. */
    public static String runWithDiagnostics(String pluginPath, String writableDirectory) throws Exception {
        try {
            return run(pluginPath, writableDirectory);
        } catch (Exception | LinkageError failure) {
            failure.printStackTrace(System.err);
            throw failure;
        }
    }

    /** A native caller supplies both strings to verify JNI UTF-8 in both directions. */
    public static String echo(String first, String second) {
        return first + second;
    }
    public static final class MockOkioBuffer {
        private final byte[] data;

        public MockOkioBuffer(byte[] data) {
            this.data = data;
        }

        public byte[] readByteArray() {
            return data;
        }

        public long size() {
            return data.length;
        }
    }

    /** Synthetic malformed buffers; never uses a reference or third-party class. */
    public static final class BoundaryBuffer {
        private final int mode;
        public int reads;

        public BoundaryBuffer(int mode) { this.mode = mode; }

        public long size() {
            if (mode == 0) return 32L * 1024 * 1024 + 1;
            if (mode == 1) return -1;
            if (mode == 2) throw new IllegalStateException("Synthetic size failure");
            return mode == 7 ? 0 : 1;
        }

        public byte[] readByteArray() {
            reads++;
            if (mode == 3) throw new IllegalStateException("Synthetic read failure");
            if (mode == 4) return null;
            if (mode == 5) return new byte[2];
            if (mode == 6) return new byte[32 * 1024 * 1024 + 1];
            return new byte[0];
        }
    }

    public static final class BoundaryMissingRead {
        public long size() { return 0; }
    }

    public static Object createMockBuffer(String text) {
        return new MockOkioBuffer(text != null ? text.getBytes(StandardCharsets.UTF_8) : new byte[0]);
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("plugin.jar writable-directory");
        System.out.println("VM: " + System.getProperty("java.vm.name") + " " + System.getProperty("java.vm.version"));
        System.out.println(run(args[0], args[1]));
    }
}

