package mangashelf.host;

import android.content.SharedPreferences;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/**
 * One application owner's durable extension preferences. Memory commits are
 * atomic and disk snapshots are sequenced on one writer before atomic rename.
 * The file format belongs to MSL; this is not Android XML backup compatibility.
 * Listener callbacks run outside locks on the editing caller, not an Android UI
 * Looper. Listeners are weakly held. Call flush/close at host lifecycle boundaries.
 */
public final class PreferenceStore implements AutoCloseable {
    public static final int MAX_FILE_BYTES = 4 * 1024 * 1024;
    private static final int MAX_KEYS = 4096;
    private static final int MAX_KEY_BYTES = 4096;
    private static final int MAX_VALUE_BYTES = 1024 * 1024;
    private static final long MAX_PENDING_BYTES = 32L * 1024 * 1024;
    private static final int MAX_PENDING_WRITES = 4096;
    private static final long MAGIC = 0x4d534c5052454601L; // MSLPREF, format 1
    private final Path root;
    private final ExecutorService writer;
    private final Map<String, Preferences> opened = new HashMap<>();
    private final BeforeReplace beforeReplace;
    private final long pendingBytesLimit;
    private final int pendingWritesLimit;
    private long pendingBytes;
    private int pendingWrites;
    private volatile IOException lastWriteFailure;
    private volatile String lastListenerFailure;
    private final Map<Path, IOException> unresolvedWrites = new LinkedHashMap<>(); // writer thread only
    private boolean closed;

    @FunctionalInterface interface BeforeReplace { void run(Path temporary, Path target) throws IOException; }

    public PreferenceStore(Path root) throws IOException { this(root, (temporary, target) -> {}); }

    PreferenceStore(Path root, BeforeReplace beforeReplace) throws IOException {
        this(root, beforeReplace, MAX_PENDING_BYTES, MAX_PENDING_WRITES);
    }

    PreferenceStore(Path root, BeforeReplace beforeReplace, long pendingBytesLimit, int pendingWritesLimit) throws IOException {
        if (pendingBytesLimit < 1 || pendingWritesLimit < 1) throw new IllegalArgumentException("invalid_preference_write_limit");
        this.pendingBytesLimit = pendingBytesLimit;
        this.pendingWritesLimit = pendingWritesLimit;
        this.root = Objects.requireNonNull(root).toAbsolutePath().normalize();
        this.beforeReplace = Objects.requireNonNull(beforeReplace);
        Files.createDirectories(this.root);
        if (!Files.isDirectory(this.root, LinkOption.NOFOLLOW_LINKS)) throw new IOException("invalid_preferences_directory");
        writer = Executors.newSingleThreadExecutor(action -> {
            Thread thread = new Thread(null, action, "msl-preference-writer", 0, false);
            thread.setContextClassLoader(PreferenceStore.class.getClassLoader());
            thread.setDaemon(true);
            return thread;
        });
    }

    public synchronized SharedPreferences get(String name) throws IOException {
        ensureOpen();
        byte[] encoded = encode(name, MAX_KEY_BYTES);
        Preferences existing = opened.get(name);
        if (existing != null) return existing;
        if (opened.size() >= 10_000) throw new IOException("preference_store_limit");
        final String identity;
        try { identity = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(encoded)); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
        Preferences value = new Preferences(root.resolve(identity + ".prefs"));
        opened.put(name, value);
        return value;
    }

    public IOException lastWriteFailure() { return lastWriteFailure; }
    public String lastListenerFailure() { return lastListenerFailure; }

    /** Waits for already enqueued writes; a prior asynchronous write error is observable. */
    public void flush() throws IOException {
        Future<Boolean> barrier;
        synchronized (this) { ensureOpen(); barrier = writer.submit(() -> true); }
        if (!await(barrier)) throw new IOException("preference_flush_failed");
        IOException failure = lastWriteFailure;
        if (failure != null) throw new IOException("preference_write_failed", failure);
    }

    private synchronized Future<Boolean> enqueue(Path target, byte[] bytes) {
        ensureOpen();
        if (pendingWrites >= pendingWritesLimit || bytes.length > pendingBytesLimit - pendingBytes) {
            throw new IllegalStateException("preference_pending_write_limit");
        }
        pendingBytes += bytes.length;
        pendingWrites++;
        try {
            return writer.submit(() -> {
                try {
                    persist(target, bytes);
                    unresolvedWrites.remove(target);
                    return true;
                } catch (IOException error) {
                    unresolvedWrites.put(target, error);
                    return false;
                } catch (RuntimeException error) {
                    // Do not retain a plugin-defined exception/classloader in shared state.
                    unresolvedWrites.put(target, new IOException("preference_writer_failed: " + error.getClass().getName()));
                    return false;
                } catch (Error error) {
                    unresolvedWrites.put(target, new IOException("preference_writer_failed: " + error.getClass().getName()));
                    throw error;
                } finally {
                    lastWriteFailure = unresolvedWrites.values().stream().findFirst().orElse(null);
                    synchronized (PreferenceStore.this) { pendingBytes -= bytes.length; pendingWrites--; }
                }
            });
        } catch (RuntimeException | Error error) {
            pendingBytes -= bytes.length;
            pendingWrites--;
            throw error;
        }
    }

    private void persist(Path target, byte[] bytes) throws IOException {
        Path temporary = Files.createTempFile(root, "write-", ".tmp",
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
        try {
            try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                ByteBuffer buffer = ByteBuffer.wrap(bytes);
                while (buffer.hasRemaining()) channel.write(buffer);
                channel.force(true);
            }
            beforeReplace.run(temporary, target);
            Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temporary); }
    }

    private synchronized void ensureOpen() {
        if (closed) throw new IllegalStateException("preference_store_closed");
    }

    private static boolean await(Future<Boolean> future) {
        try { return future.get(); }
        catch (InterruptedException error) { Thread.currentThread().interrupt(); return false; }
        catch (ExecutionException error) { throw new IllegalStateException("preference_writer_failed", error.getCause()); }
    }

    @Override public void close() throws IOException {
        synchronized (this) {
            closed = true;
            writer.shutdown();
        }
        try {
            if (!writer.awaitTermination(30, TimeUnit.SECONDS)) throw new IOException("preference_close_timeout");
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("preference_close_interrupted", error);
        }
        IOException failure = lastWriteFailure;
        if (failure != null) throw new IOException("preference_write_failed", failure);
    }

    private record Value(int kind, Object data) {}
    private record Change(List<SharedPreferences.OnSharedPreferenceChangeListener> listeners,
                          List<String> keys, boolean cleared, Future<Boolean> disk) {}

    private final class Preferences implements SharedPreferences {
        private final Object lock = new Object();
        private final Path file;
        private final Map<OnSharedPreferenceChangeListener, Boolean> listeners = new WeakHashMap<>();
        private volatile Map<String, Value> values;

        private Preferences(Path file) throws IOException { this.file = file; values = read(file); }

        private Object getValue(String key, int kind, Object fallback) {
            Objects.requireNonNull(key);
            Value value = values.get(key);
            if (value == null) return fallback;
            if (value.kind != kind) throw new ClassCastException("Preference has a different value type");
            return value.data;
        }
        @Override public Map<String, ?> getAll() {
            Map<String, Object> copy = new LinkedHashMap<>();
            values.forEach((key, value) -> copy.put(key, copyValue(value.data)));
            return Collections.unmodifiableMap(copy);
        }
        @Override public String getString(String key, String fallback) { return (String) getValue(key, 1, fallback); }
        @Override public Set<String> getStringSet(String key, Set<String> fallback) {
            Object value = getValue(key, 2, fallback);
            if (value == null) return null;
            Set<?> source = (Set<?>) value;
            Set<String> copy = new LinkedHashSet<>();
            for (Object element : source) copy.add((String) element);
            return Collections.unmodifiableSet(copy);
        }
        @Override public int getInt(String key, int fallback) { return (Integer) getValue(key, 3, fallback); }
        @Override public long getLong(String key, long fallback) { return (Long) getValue(key, 4, fallback); }
        @Override public float getFloat(String key, float fallback) { return (Float) getValue(key, 5, fallback); }
        @Override public boolean getBoolean(String key, boolean fallback) { return (Boolean) getValue(key, 6, fallback); }
        @Override public boolean contains(String key) { return values.containsKey(Objects.requireNonNull(key)); }
        @Override public Editor edit() { return new Edit(); }
        @Override public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) {
            synchronized (lock) { listeners.put(Objects.requireNonNull(listener), true); }
        }
        @Override public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener) {
            synchronized (lock) { listeners.remove(listener); }
        }

        private Change publish(Map<String, Value> edits, boolean clear) {
            synchronized (lock) {
                Map<String, Value> previous = values;
                Map<String, Value> next = clear ? new LinkedHashMap<>() : new LinkedHashMap<>(previous);
                List<String> changed = new ArrayList<>();
                edits.forEach((key, value) -> {
                    Value old = next.get(key);
                    if (!Objects.equals(old, value)) {
                        if (value == null) next.remove(key); else next.put(key, value);
                        changed.add(key);
                    }
                });
                final byte[] encoded;
                try { encoded = serialize(next); }
                catch (IOException error) { throw new UncheckedIOException(error); }
                // Enqueue under the memory lock so racing editors cannot persist out of order.
                Future<Boolean> disk = enqueue(file, encoded);
                values = Collections.unmodifiableMap(next);
                return new Change(new ArrayList<>(listeners.keySet()), changed, clear && !previous.isEmpty(), disk);
            }
        }

        private void notifyListeners(Change change) {
            for (OnSharedPreferenceChangeListener listener : change.listeners) {
                if (listener == null) continue;
                try {
                    if (change.cleared) listener.onSharedPreferenceChanged(this, null);
                    for (String key : change.keys) listener.onSharedPreferenceChanged(this, key);
                } catch (RuntimeException error) { lastListenerFailure = error.getClass().getName(); }
            }
        }

        private final class Edit implements Editor {
            private final Map<String, Value> pending = new LinkedHashMap<>();
            private boolean clear;
            private synchronized Editor put(String key, int type, Object value) {
                try { encode(key, MAX_KEY_BYTES); }
                catch (IOException error) { throw new IllegalArgumentException("invalid_preference_key", error); }
                pending.put(key, value == null ? null : new Value(type, value));
                return this;
            }
            @Override public Editor putString(String key, String value) {
                if (value != null) validateString(value);
                return put(key, 1, value);
            }
            @Override public Editor putStringSet(String key, Set<String> value) {
                if (value == null) return remove(key);
                if (value.size() > MAX_KEYS) throw new IllegalArgumentException("preference_set_limit");
                Set<String> copy = new LinkedHashSet<>();
                long bytes = 0;
                for (String item : value) {
                    try { bytes += encode(item, MAX_VALUE_BYTES).length + 4L; }
                    catch (IOException error) { throw new IllegalArgumentException("invalid_preference_string", error); }
                    if (bytes > MAX_FILE_BYTES) throw new IllegalArgumentException("preference_set_limit");
                    copy.add(item);
                }
                return put(key, 2, Collections.unmodifiableSet(copy));
            }
            @Override public Editor putInt(String key, int value) { return put(key, 3, value); }
            @Override public Editor putLong(String key, long value) { return put(key, 4, value); }
            @Override public Editor putFloat(String key, float value) { return put(key, 5, value); }
            @Override public Editor putBoolean(String key, boolean value) { return put(key, 6, value); }
            @Override public Editor remove(String key) { return put(key, 0, null); }
            @Override public synchronized Editor clear() { clear = true; return this; }
            private Change snapshot() {
                Map<String, Value> copy;
                boolean clearing;
                synchronized (this) {
                    copy = new LinkedHashMap<>(pending); clearing = clear;
                    pending.clear(); clear = false;
                }
                return publish(copy, clearing);
            }
            @Override public boolean commit() {
                Change change = snapshot();
                boolean result = await(change.disk);
                notifyListeners(change);
                return result;
            }
            @Override public void apply() { Change change = snapshot(); notifyListeners(change); }
        }
    }

    private static Object copyValue(Object value) {
        return value instanceof Set<?> set ? Collections.unmodifiableSet(new LinkedHashSet<>(set)) : value;
    }

    private static void validateString(String text) {
        try { encode(Objects.requireNonNull(text), MAX_VALUE_BYTES); }
        catch (IOException error) { throw new IllegalArgumentException("invalid_preference_string", error); }
    }

    private static byte[] encode(String text, int maximum) throws IOException {
        Objects.requireNonNull(text);
        if (text.length() > maximum) throw new IOException("preference_string_limit");
        try {
            ByteBuffer encoded = StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(text));
            if (encoded.remaining() > maximum) throw new IOException("preference_string_limit");
            byte[] bytes = new byte[encoded.remaining()]; encoded.get(bytes); return bytes;
        } catch (CharacterCodingException error) { throw new IOException("invalid_preference_utf8", error); }
    }

    private static void string(DataOutputStream output, String text, int maximum) throws IOException {
        byte[] bytes = encode(text, maximum); output.writeInt(bytes.length); output.write(bytes);
    }

    private static String string(DataInputStream input, int maximum) throws IOException {
        int count = input.readInt();
        if (count < 0 || count > maximum || count > input.available()) throw new IOException("invalid_preference_length");
        byte[] bytes = input.readNBytes(count);
        if (bytes.length != count) throw new EOFException();
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException error) { throw new IOException("invalid_preference_utf8", error); }
    }

    private static byte[] serialize(Map<String, Value> values) throws IOException {
        if (values.size() > MAX_KEYS) throw new IOException("preference_key_limit");
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        OutputStream bounded = new OutputStream() {
            @Override public void write(int value) throws IOException {
                if (bytes.size() >= MAX_FILE_BYTES) throw new IOException("preference_file_limit");
                bytes.write(value);
            }
            @Override public void write(byte[] data, int offset, int length) throws IOException {
                if (length > MAX_FILE_BYTES - bytes.size()) throw new IOException("preference_file_limit");
                bytes.write(data, offset, length);
            }
        };
        try (DataOutputStream output = new DataOutputStream(bounded)) {
            output.writeLong(MAGIC); output.writeInt(values.size());
            for (String key : values.keySet().stream().sorted().toList()) {
                string(output, key, MAX_KEY_BYTES);
                Value value = values.get(key); output.writeByte(value.kind);
                switch (value.kind) {
                    case 1 -> string(output, (String) value.data, MAX_VALUE_BYTES);
                    case 2 -> {
                        Set<?> set = (Set<?>) value.data; output.writeInt(set.size());
                        for (String item : set.stream().map(String.class::cast).sorted().toList()) string(output, item, MAX_VALUE_BYTES);
                    }
                    case 3 -> output.writeInt((Integer) value.data);
                    case 4 -> output.writeLong((Long) value.data);
                    case 5 -> output.writeInt(Float.floatToRawIntBits((Float) value.data));
                    case 6 -> output.writeBoolean((Boolean) value.data);
                    default -> throw new IOException("invalid_preference_type");
                }
                if (bytes.size() > MAX_FILE_BYTES) throw new IOException("preference_file_limit");
            }
        }
        return bytes.toByteArray();
    }

    private static Map<String, Value> read(Path path) throws IOException {
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return Map.of();
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.size(path) > MAX_FILE_BYTES) {
            throw new IOException("invalid_preference_file");
        }
        byte[] data;
        try (var input = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)) {
            data = input.readNBytes(MAX_FILE_BYTES + 1);
        }
        if (data.length > MAX_FILE_BYTES) throw new IOException("preference_file_limit");
        Map<String, Value> values = new LinkedHashMap<>();
        try (DataInputStream input = new DataInputStream(new ByteArrayInputStream(data))) {
            if (input.readLong() != MAGIC) throw new IOException("invalid_preference_format");
            int count = input.readInt();
            if (count < 0 || count > MAX_KEYS) throw new IOException("preference_key_limit");
            for (int index = 0; index < count; index++) {
                String key = string(input, MAX_KEY_BYTES);
                int type = input.readUnsignedByte();
                Object value = switch (type) {
                    case 1 -> string(input, MAX_VALUE_BYTES);
                    case 2 -> {
                        int size = input.readInt();
                        if (size < 0 || size > MAX_KEYS) throw new IOException("preference_set_limit");
                        Set<String> set = new LinkedHashSet<>();
                        for (int item = 0; item < size; item++) {
                            if (!set.add(string(input, MAX_VALUE_BYTES))) throw new IOException("duplicate_preference_set_value");
                        }
                        yield Collections.unmodifiableSet(set);
                    }
                    case 3 -> input.readInt();
                    case 4 -> input.readLong();
                    case 5 -> Float.intBitsToFloat(input.readInt());
                    case 6 -> {
                        int flag = input.readUnsignedByte();
                        if (flag > 1) throw new IOException("invalid_preference_boolean");
                        yield flag == 1;
                    }
                    default -> throw new IOException("invalid_preference_type");
                };
                if (values.put(key, new Value(type, value)) != null) throw new IOException("duplicate_preference_key");
            }
            if (input.read() != -1) throw new IOException("trailing_preference_data");
        }
        return Collections.unmodifiableMap(values);
    }
}
