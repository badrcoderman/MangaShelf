package mangashelf.host;

import android.content.Context;
import android.content.SharedPreferences;
import android.preference.PreferenceManager;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public final class PreferenceStoreCheck {
    private PreferenceStoreCheck() {}
    @FunctionalInterface private interface Check { void run() throws Exception; }
    private static final Map<String, Boolean> RESULTS = new LinkedHashMap<>();
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    private static void test(String name, Check body) throws Exception { body.run(); RESULTS.put(name, true); }
    private static void fails(Class<? extends Throwable> type, Check body) throws Exception {
        try { body.run(); }
        catch (Throwable error) { if (type.isInstance(error)) return; throw error; }
        throw new AssertionError("Expected " + type.getName());
    }
    private static Path onlyFile(Path root) throws IOException {
        try (var paths = Files.list(root)) { return paths.filter(Files::isRegularFile).findFirst().orElseThrow(); }
    }

    public static void main(String[] args) throws Exception {
        Path root = Path.of(args[0]);
        test("typed_defaults_atomic_editor_and_reopen", () -> {
            Path path = root.resolve("types");
            try (PreferenceStore store = new PreferenceStore(path)) {
                SharedPreferences prefs = store.get("source_-37");
                check(prefs.getString("missing", null) == null && prefs.getInt("missing", 11) == 11);
                check(prefs.getBoolean("missing", true) && prefs.getLong("missing", Long.MAX_VALUE) == Long.MAX_VALUE);
                check(prefs.getStringSet("missing", null) == null && prefs.getAll().isEmpty());
                SharedPreferences.Editor editor = prefs.edit().putString("text", "العربية 📚")
                        .putInt("int", -7).putLong("long", Long.MIN_VALUE).putFloat("float", -0.0f)
                        .putBoolean("bool", true).putStringSet("set", Set.of("ar", "en"));
                check(prefs.getAll().isEmpty());
                check(editor.commit() && prefs.getAll().size() == 6);
                check(store.get("source_-37") == prefs);
            }
            try (PreferenceStore store = new PreferenceStore(path)) {
                SharedPreferences p = store.get("source_-37");
                check(p.getString("text", "").equals("العربية 📚") && p.getInt("int", 0) == -7);
                check(p.getLong("long", 0) == Long.MIN_VALUE && p.getBoolean("bool", false));
                check(Float.floatToRawIntBits(p.getFloat("float", 1)) == Float.floatToRawIntBits(-0.0f));
                check(p.getStringSet("set", Set.of()).equals(Set.of("ar", "en")));
                fails(ClassCastException.class, () -> p.getLong("int", 0));
                fails(ClassCastException.class, () -> p.getBoolean("text", false));
            }
        });
        test("set_input_output_and_get_all_do_not_alias_storage", () -> {
            try (PreferenceStore store = new PreferenceStore(root.resolve("sets"))) {
                SharedPreferences p = store.get("source");
                Set<String> input = new HashSet<>(Set.of("ar", "en"));
                SharedPreferences.Editor edit = p.edit().putStringSet("languages", input);
                input.clear(); check(edit.commit());
                Set<String> returned = p.getStringSet("languages", null);
                check(returned.equals(Set.of("ar", "en")));
                fails(UnsupportedOperationException.class, returned::clear);
                Map<String, ?> all = p.getAll();
                fails(UnsupportedOperationException.class, all::clear);
                check(p.edit().putStringSet("languages", Set.of("ja")).commit());
                check(returned.equals(Set.of("ar", "en")) && ((Set<?>) all.get("languages")).contains("ar"));
                Set<String> fallback = new HashSet<>(Set.of("fallback"));
                Set<String> copy = p.getStringSet("absent", fallback); fallback.clear();
                check(copy.equals(Set.of("fallback")));
            }
        });
        test("clear_remove_null_and_editor_reuse_follow_android_value_rules", () -> {
            try (PreferenceStore store = new PreferenceStore(root.resolve("editor"))) {
                SharedPreferences p = store.get("source");
                check(p.edit().putString("old", "yes").putStringSet("set", Set.of("a")).commit());
                SharedPreferences.Editor editor = p.edit().putString("new", "kept").clear();
                check(editor.commit() && p.getAll().keySet().equals(Set.of("new")));
                check(editor.putInt("other", 3).commit() && p.contains("new"));
                check(p.edit().putString("new", null).putStringSet("set", null).remove("missing").commit());
                check(!p.contains("new") && !p.contains("set") && p.getInt("other", 0) == 3);
            }
        });
        test("names_and_unicode_keys_stay_distinct_without_path_traversal", () -> {
            Path path = root.resolve("names");
            try (PreferenceStore store = new PreferenceStore(path)) {
                for (String name : List.of("a.b", "ab", "../", "العربية 📚")) {
                    check(store.get(name).edit().putString("مفتاح 📚", name).commit());
                }
                for (String name : List.of("a.b", "ab", "../", "العربية 📚")) {
                    check(store.get(name).getString("مفتاح 📚", "").equals(name));
                }
                try (var paths = Files.list(path)) {
                    List<Path> files = paths.toList();
                    check(files.size() == 4 && files.stream().allMatch(p -> p.getFileName().toString().matches("[a-f0-9]{64}\\.prefs")));
                }
            }
        });
        test("apply_is_immediately_visible_and_commit_waits_for_prior_writes", () -> {
            Path path = root.resolve("ordering");
            CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
            AtomicInteger writes = new AtomicInteger();
            try (PreferenceStore store = new PreferenceStore(path, (temporary, target) -> {
                if (writes.getAndIncrement() == 0) {
                    entered.countDown();
                    try { if (!release.await(5, TimeUnit.SECONDS)) throw new IOException("gate_timeout"); }
                    catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
                }
            })) {
                SharedPreferences p = store.get("source");
                p.edit().putInt("value", 1).apply();
                check(p.getInt("value", 0) == 1 && entered.await(5, TimeUnit.SECONDS));
                var caller = Executors.newSingleThreadExecutor();
                try {
                    var commit = caller.submit(() -> p.edit().putInt("value", 2).commit());
                    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
                    while (p.getInt("value", 0) != 2 && System.nanoTime() < deadline) Thread.onSpinWait();
                    check(p.getInt("value", 0) == 2 && !commit.isDone());
                    release.countDown(); check(commit.get(5, TimeUnit.SECONDS));
                } finally { release.countDown(); caller.shutdownNow(); }
            }
            try (PreferenceStore store = new PreferenceStore(path)) { check(store.get("source").getInt("value", 0) == 2); }
        });
        test("failed_atomic_replace_preserves_disk_and_retry_clears_pending_error", () -> {
            Path path = root.resolve("failure"); AtomicBoolean fail = new AtomicBoolean();
            try (PreferenceStore store = new PreferenceStore(path, (temporary, target) -> {
                if (fail.get()) throw new IOException("Authored replacement fault");
            })) {
                SharedPreferences p = store.get("source");
                check(p.edit().putInt("value", 1).commit());
                byte[] previous = Files.readAllBytes(onlyFile(path));
                fail.set(true); check(!p.edit().putInt("value", 2).commit());
                check(p.getInt("value", 0) == 2 && Arrays.equals(previous, Files.readAllBytes(onlyFile(path))));
                check(store.lastWriteFailure() != null);
                fails(IOException.class, store::flush);
                fail.set(false); check(p.edit().commit()); store.flush();
                check(store.lastWriteFailure() == null);
                try (var paths = Files.list(path)) { check(paths.count() == 1); }
            }
            try (PreferenceStore store = new PreferenceStore(path)) { check(store.get("source").getInt("value", 0) == 2); }
        });
        test("asynchronous_failure_is_observable_and_recoverable_per_store", () -> {
            Path path = root.resolve("async-failure"); AtomicBoolean fail = new AtomicBoolean(true);
            try (PreferenceStore store = new PreferenceStore(path, (temporary, target) -> {
                if (fail.get()) throw new IOException("Authored asynchronous fault");
            })) {
                store.get("a").edit().putBoolean("flag", true).apply();
                fails(IOException.class, store::flush);
                fail.set(false);
                check(store.get("b").edit().putBoolean("flag", true).commit());
                fails(IOException.class, store::flush); // success for b cannot hide unsaved a
                check(store.get("a").edit().commit()); store.flush();
            }
        });
        test("unchecked_async_writer_failures_surface_at_flush_and_allow_retry", () -> {
            for (boolean fatal : List.of(false, true)) {
                AtomicBoolean fail = new AtomicBoolean(true);
                try (PreferenceStore store = new PreferenceStore(root.resolve("unchecked-" + fatal), (temporary, target) -> {
                    if (fail.get()) {
                        if (fatal) throw new AssertionError("Authored writer error");
                        throw new IllegalStateException("Authored writer exception");
                    }
                })) {
                    SharedPreferences p = store.get("source");
                    p.edit().putInt("value", 1).apply();
                    fails(IOException.class, store::flush);
                    check(store.lastWriteFailure() != null && store.lastWriteFailure().getCause() == null);
                    check(store.lastWriteFailure().getMessage().contains(fatal ? "AssertionError" : "IllegalStateException"));
                    fail.set(false); check(p.edit().commit()); store.flush();
                    check(store.lastWriteFailure() == null);
                }
            }
        });
        test("pending_write_bytes_and_count_are_bounded_before_memory_publication", () -> {
            for (boolean bytesLimit : List.of(false, true)) {
                Path path = root.resolve("queue-limit-" + bytesLimit);
                CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
                try (PreferenceStore store = new PreferenceStore(path, (temporary, target) -> {
                    entered.countDown();
                    try { if (!release.await(5, TimeUnit.SECONDS)) throw new IOException("gate_timeout"); }
                    catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
                }, bytesLimit ? 64 : 1024, bytesLimit ? 100 : 2)) {
                    SharedPreferences p = store.get("source");
                    try {
                        p.edit().putInt("value", 1).apply(); check(entered.await(5, TimeUnit.SECONDS));
                        p.edit().putInt("value", 2).apply();
                        fails(IllegalStateException.class, () -> p.edit().putInt("value", 3).apply());
                        check(p.getInt("value", 0) == 2);
                    } finally { release.countDown(); }
                    store.flush(); check(p.edit().putInt("value", 4).commit());
                }
                try (PreferenceStore store = new PreferenceStore(path)) { check(store.get("source").getInt("value", 0) == 4); }
            }
        });
        test("listeners_can_edit_reentrantly_unregister_and_observe_clear", () -> {
            try (PreferenceStore store = new PreferenceStore(root.resolve("listeners"))) {
                SharedPreferences p = store.get("source"); List<String> events = new ArrayList<>();
                SharedPreferences.OnSharedPreferenceChangeListener listener = (prefs, key) -> {
                    events.add(key);
                    if ("outer".equals(key)) check(prefs.edit().putInt("inner", 1).commit());
                };
                p.registerOnSharedPreferenceChangeListener(listener);
                check(p.edit().putInt("outer", 1).commit());
                check(events.equals(List.of("outer", "inner")));
                events.clear(); check(p.edit().putInt("outer", 1).commit()); check(events.isEmpty());
                check(p.edit().clear().commit()); check(events.size() == 1 && events.get(0) == null);
                p.unregisterOnSharedPreferenceChangeListener(listener);
                check(p.edit().putInt("after", 1).commit()); check(events.size() == 1);
            }
        });
        test("bad_listener_does_not_retain_plugin_exception_or_block_other_listeners", () -> {
            try (PreferenceStore store = new PreferenceStore(root.resolve("bad-listener"))) {
                SharedPreferences p = store.get("source"); AtomicInteger delivered = new AtomicInteger();
                SharedPreferences.OnSharedPreferenceChangeListener bad = (prefs, key) -> { throw new IllegalStateException("fixture"); };
                SharedPreferences.OnSharedPreferenceChangeListener good = (prefs, key) -> delivered.incrementAndGet();
                p.registerOnSharedPreferenceChangeListener(bad); p.registerOnSharedPreferenceChangeListener(good);
                check(p.edit().putInt("value", 1).commit());
                check(delivered.get() == 1 && store.lastListenerFailure().equals("java.lang.IllegalStateException"));
                p.unregisterOnSharedPreferenceChangeListener(bad); p.unregisterOnSharedPreferenceChangeListener(good);
            }
        });
        test("concurrent_edits_preserve_disjoint_keys_and_latest_memory_snapshot", () -> {
            Path path = root.resolve("concurrent");
            int last;
            try (PreferenceStore store = new PreferenceStore(path)) {
                SharedPreferences p = store.get("source"); var callers = Executors.newFixedThreadPool(8);
                try {
                    List<java.util.concurrent.Future<?>> futures = new ArrayList<>();
                    for (int index = 0; index < 100; index++) {
                        int value = index;
                        futures.add(callers.submit(() -> p.edit().putInt("key-" + value, value).putInt("latest", value).apply()));
                    }
                    for (var future : futures) future.get(10, TimeUnit.SECONDS);
                    store.flush(); check(p.getAll().size() == 101); last = p.getInt("latest", -1);
                } finally { callers.shutdownNow(); }
            }
            try (PreferenceStore store = new PreferenceStore(path)) {
                SharedPreferences p = store.get("source");
                for (int index = 0; index < 100; index++) check(p.getInt("key-" + index, -1) == index);
                check(p.getInt("latest", -1) == last);
            }
        });
        test("truncated_corrupt_and_symlink_files_are_rejected_without_reset", () -> {
            Path path = root.resolve("corrupt");
            try (PreferenceStore store = new PreferenceStore(path)) { check(store.get("source").edit().putString("key", "value").commit()); }
            Path file = onlyFile(path); byte[] valid = Files.readAllBytes(file);
            for (int size = 0; size < valid.length; size++) {
                Files.write(file, Arrays.copyOf(valid, size));
                try (PreferenceStore store = new PreferenceStore(path)) { fails(IOException.class, () -> store.get("source")); }
                check(Files.size(file) == size);
            }
            Files.write(file, new byte[PreferenceStore.MAX_FILE_BYTES + 1]);
            try (PreferenceStore store = new PreferenceStore(path)) { fails(IOException.class, () -> store.get("source")); }
            Files.delete(file); Path target = root.resolve("link-target"); Files.write(target, valid); Files.createSymbolicLink(file, target);
            try (PreferenceStore store = new PreferenceStore(path)) { fails(IOException.class, () -> store.get("source")); }
            check(Arrays.equals(valid, Files.readAllBytes(target)));
        });
        test("limits_and_malformed_unicode_fail_before_memory_publication", () -> {
            try (PreferenceStore store = new PreferenceStore(root.resolve("limits"))) {
                SharedPreferences p = store.get("source");
                fails(IllegalArgumentException.class, () -> p.edit().putString("key", String.valueOf((char) 0xD800)));
                fails(IllegalArgumentException.class, () -> p.edit().putInt("x".repeat(4097), 1));
                fails(IllegalArgumentException.class, () -> p.edit().putString("key", "x".repeat(1024 * 1024 + 1)));
                SharedPreferences.Editor editor = p.edit();
                for (int index = 0; index < 4097; index++) editor.putInt("key-" + index, index);
                fails(UncheckedIOException.class, editor::commit); check(p.getAll().isEmpty());
                String large = "x".repeat(1024 * 1024);
                editor = p.edit().putString("a", large).putString("b", large).putString("c", large).putString("d", large);
                SharedPreferences.Editor full = editor;
                fails(UncheckedIOException.class, full::commit); check(p.getAll().isEmpty());
            }
        });
        test("application_context_default_preferences_files_and_shutdown", () -> {
            fails(IllegalStateException.class, Context::new);
            Context owner = new Context(root.resolve("application"), "app.mangashelf.reader");
            Context.installDefault(owner);
            Context alias = new Context();
            check(alias.getApplicationContext() == owner && owner.getCacheDir().isDirectory() && owner.getFilesDir().isDirectory());
            check(owner.getPackageName().equals("app.mangashelf.reader"));
            SharedPreferences defaults = PreferenceManager.getDefaultSharedPreferences(alias);
            check(defaults == owner.getSharedPreferences("app.mangashelf.reader_preferences", 0));
            check(defaults.edit().putBoolean("test", true).commit());
            fails(IllegalArgumentException.class, () -> owner.getSharedPreferences("../outside", 0));
            fails(IllegalArgumentException.class, () -> owner.getSharedPreferences("source", 1));
            owner.close();
            fails(IllegalStateException.class, Context::new);
            fails(IllegalStateException.class, () -> defaults.edit().putInt("late", 1).apply());
        });
        test("writer_uses_host_loader_instead_of_inheriting_plugin_context", () -> {
            AtomicBoolean hostLoader = new AtomicBoolean();
            ClassLoader prior = Thread.currentThread().getContextClassLoader();
            try (PreferenceStore store = new PreferenceStore(root.resolve("writer-context"), (temporary, target) -> {
                hostLoader.set(Thread.currentThread().getContextClassLoader() == PreferenceStore.class.getClassLoader());
            })) {
                try {
                    Thread.currentThread().setContextClassLoader(new ClassLoader(prior) {});
                    check(store.get("source").edit().putInt("value", 1).commit());
                } finally { Thread.currentThread().setContextClassLoader(prior); }
                check(hostLoader.get());
            }
        });
        System.out.println("{\"passed\":true,\"checks\":{" + String.join(",", RESULTS.keySet().stream()
                .map(name -> "\"" + name + "\":true").toList()) + "}}");
    }
}
