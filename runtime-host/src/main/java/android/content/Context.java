package android.content;

import java.io.File;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.Objects;
import mangashelf.host.PreferenceStore;

/** Application files/preferences context, not Android UI or system service emulation. */
public class Context implements AutoCloseable {
    public static final int MODE_PRIVATE = 0;
    private static volatile Context defaultContext;
    private final Path root;
    private final File files;
    private final File cache;
    private final String packageName;
    private final PreferenceStore preferences;
    private final Context application;

    /** Extension-created contexts share the host's explicitly installed application state. */
    public Context() { this(requireDefault()); }

    private Context(Context owner) {
        root = owner.root; files = owner.files; cache = owner.cache;
        packageName = owner.packageName; preferences = owner.preferences; application = owner.application;
    }

    public Context(Path directory, String packageName) throws IOException {
        this.packageName = Objects.requireNonNull(packageName);
        if (packageName.length() > 512 || !packageName.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*")) {
            throw new IllegalArgumentException("invalid_application_package");
        }
        root = Objects.requireNonNull(directory).toAbsolutePath().normalize();
        Files.createDirectories(root);
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) throw new IOException("invalid_application_directory");
        Path filesPath = root.resolve("files"), cachePath = root.resolve("cache");
        Files.createDirectories(filesPath); Files.createDirectories(cachePath);
        if (!Files.isDirectory(filesPath, LinkOption.NOFOLLOW_LINKS) || !Files.isDirectory(cachePath, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("invalid_application_directory");
        }
        files = filesPath.toFile(); cache = cachePath.toFile();
        preferences = new PreferenceStore(root.resolve("preferences"));
        application = this;
    }

    public static synchronized void installDefault(Context context) {
        Objects.requireNonNull(context);
        if (defaultContext != null && defaultContext.application != context.application) {
            throw new IllegalStateException("application_context_already_installed");
        }
        defaultContext = context.application;
    }

    private static Context requireDefault() {
        Context context = defaultContext;
        if (context == null) throw new IllegalStateException("application_context_not_installed");
        return context;
    }

    public Context getApplicationContext() { return application; }
    public String getPackageName() { return packageName; }
    public File getFilesDir() { return files; }
    public File getCacheDir() { return cache; }
    public SharedPreferences getSharedPreferences(String name, int mode) {
        if (mode != MODE_PRIVATE) throw new IllegalArgumentException("unsupported_preference_mode");
        if (Objects.requireNonNull(name).indexOf('/') >= 0) throw new IllegalArgumentException("invalid_preference_name");
        try { return preferences.get(name); }
        catch (IOException error) { throw new UncheckedIOException("Could not read extension preferences", error); }
    }
    public PreferenceStore preferenceStore() { return preferences; }

    @Override public void close() throws IOException {
        synchronized (Context.class) {
            if (defaultContext != null && defaultContext.application == application) defaultContext = null;
        }
        preferences.close();
    }
}
