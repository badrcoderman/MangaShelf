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
import java.nio.charset.Charset;

/** Runs only project-owned test code, callable from a future iOS JNI harness. */
public final class RuntimeProbe {
    private static void require(boolean ok, String detail) {
        if (!ok) throw new IllegalStateException(detail);
    }

    /** ASCII-only values keep diagnostics readable even when native output encoding is broken. */
    private static String diagnosticValue(String value) {
        if (value == null) return "<unset>";
        StringBuilder result = new StringBuilder();
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            String encoded;
            if (character >= 32 && character <= 126 && character != '\\') {
                encoded = String.valueOf(character);
            } else {
                encoded = "\\u" + String.format(java.util.Locale.ROOT, "%04X", (int) character);
            }
            if (result.length() + encoded.length() > 160) {
                result.append("<truncated>");
                break;
            }
            result.append(encoded);
        }
        return result.toString();
    }

    /** Uses the bridge's existing (String, String) signature; never includes paths or environment. */
    public static String diagnostics(String unusedFirst, String unusedSecond) {
        StringBuilder result = new StringBuilder("JVM/file diagnostics\n");
        for (String key : new String[]{"sun.jnu.encoding", "native.encoding", "file.encoding",
                "stdout.encoding", "stderr.encoding", "java.version", "java.runtime.version",
                "java.vm.name", "java.vm.version", "os.name", "os.arch", "os.version"}) {
            String value;
            try { value = System.getProperty(key); }
            catch (SecurityException unavailable) { value = "<unavailable>"; }
            result.append(key).append('=').append(diagnosticValue(value)).append('\n');
        }
        result.append("Charset.defaultCharset=").append(diagnosticValue(Charset.defaultCharset().name())).append('\n');
        return result.toString();
    }

    private static void checkUnicodeFilesystem(Path root, byte[] plain) throws Exception {
        String prefix = "مانغا-📚-";
        String childName = "فصل-📖.txt";
        Path directory = Files.createTempDirectory(root, prefix);
        Path child = null;
        try {
            String directoryName = directory.getFileName().toString();
            require(directoryName.startsWith(prefix), "Unicode directory name changed");
            child = directory.resolve(childName);
            Files.write(child, plain);
            require(java.util.Arrays.equals(plain, Files.readAllBytes(child)), "Unicode path file I/O failed");
            String expectedSuffix = new java.net.URI(null, null, "/" + directoryName + "/" + childName, null).toASCIIString();
            require(child.toUri().toASCIIString().endsWith(expectedSuffix), "Unicode path bytes are not UTF-8");
            try (var directories = Files.list(root)) {
                require(directories.anyMatch(path -> directoryName.equals(path.getFileName().toString())),
                        "Unicode directory listing changed name");
            }
            try (var entries = Files.list(directory)) {
                var listed = entries.toList();
                require(listed.size() == 1, "Unicode directory has unexpected entries");
                Path entry = listed.get(0);
                require(childName.equals(entry.getFileName().toString()), "Unicode file listing changed name");
                require(entry.toUri().toASCIIString().endsWith(expectedSuffix), "Listed Unicode path bytes are not UTF-8");
                require(java.util.Arrays.equals(plain, Files.readAllBytes(entry)), "Listed Unicode file read failed");
            }
        } finally {
            try { if (child != null) Files.deleteIfExists(child); }
            finally { Files.deleteIfExists(directory); }
        }
        require(!Files.exists(directory), "Unicode directory cleanup failed");
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
        Path textFile = Files.createTempFile(root, "مانغا-probe-", ".txt");
        Path imageFile = null;
        try {
            imageFile = Files.createTempFile(root, "mangashelf-probe-", ".png");
            Files.write(textFile, plain);
            Files.write(imageFile, new byte[]{(byte)137, 80, 78, 71, 13, 10, 26, 10});
            require("text/plain".equals(Files.probeContentType(textFile)), "Text MIME probe failed");
            require("image/png".equals(Files.probeContentType(imageFile)), "PNG MIME probe failed");
        } finally {
            try { Files.deleteIfExists(textFile); }
            finally { if (imageFile != null) Files.deleteIfExists(imageFile); }
        }
        checkUnicodeFilesystem(root, plain);
        return "PASS: separate JAR, reflection, Unicode, thread, GZIP, file I/O, file MIME types, Unicode filesystem";
    }

    /** Device diagnostics survive the bridge clearing a Java exception. */
    public static String runWithDiagnostics(String pluginPath, String writableDirectory) throws Exception {
        System.err.print(diagnostics(null, null));
        System.err.flush();
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

