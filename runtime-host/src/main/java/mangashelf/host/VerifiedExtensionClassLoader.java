package mangashelf.host;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URL;
import java.net.URLConnection;
import java.net.URLStreamHandler;
import java.security.CodeSource;
import java.security.SecureClassLoader;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;
import java.util.jar.Attributes;
import java.util.jar.Manifest;
import mangashelf.runtime.ExtensionArchiveVerifier.VerifiedArchive;
import mangashelf.runtime.ExtensionArchiveVerifier.VerifiedEntry;

/**
 * Loads only from an owned verified JarFile, never from a mutable path or the
 * manifest Class-Path. Trusted plugins share the host process; this is no sandbox.
 * Closing releases the archive, not already defined classes or plugin threads.
 */
public final class VerifiedExtensionClassLoader extends SecureClassLoader implements AutoCloseable {
    private static final List<String> HOST_PREFIXES = List.of(
            "java.", "javax.", "jdk.", "sun.", "com.sun.", "android.", "androidx.",
            "kotlin.", "kotlinx.", "okhttp3.", "okio.", "mangashelf.",
            "org.jetbrains.annotations.", "org.tachiyomi.", "uy.kohesive.injekt.",
            "com.squareup.zstd.",
            "org.jsoup.", "org.brotli.", "org.jspecify.",
            "eu.kanade.tachiyomi.source.", "eu.kanade.tachiyomi.network.",
            "eu.kanade.tachiyomi.util.");
    private final VerifiedArchive archive;
    private final Manifest manifest;
    private final URL location;
    private volatile boolean closed;

    /** Takes ownership of archive on success and failure. The parent is the host ABI loader. */
    public static VerifiedExtensionClassLoader open(VerifiedArchive archive, ClassLoader parent) throws IOException {
        if (archive == null) throw new IllegalArgumentException("Missing verified archive");
        try {
            if (parent == null) throw new IllegalArgumentException("Missing host class loader");
            return new VerifiedExtensionClassLoader(archive, parent);
        } catch (IOException | RuntimeException | Error error) {
            try { archive.close(); } catch (IOException release) { error.addSuppressed(release); }
            throw error;
        }
    }

    private VerifiedExtensionClassLoader(VerifiedArchive archive, ClassLoader parent) throws IOException {
        super("msl-extension-" + archive.result().archiveSha256(), parent);
        this.archive = archive;
        VerifiedEntry metadata = archive.read("META-INF/MANIFEST.MF");
        if (metadata == null) throw new IOException("missing_manifest");
        manifest = new Manifest(new ByteArrayInputStream(metadata.bytes()));
        String classPath = manifest.getMainAttributes().getValue(Attributes.Name.CLASS_PATH);
        if (classPath != null && !classPath.isBlank()) throw new IOException("external_class_path_unsupported");
        for (String entry : archive.entryNames()) {
            String path = entry.replaceFirst("^META-INF/versions/[0-9]+/", "");
            if (path.endsWith(".class")) {
                String name = path.substring(0, path.length() - 6).replace('/', '.');
                if (HOST_PREFIXES.stream().anyMatch(name::startsWith)) throw new IOException("host_class_shadow");
            }
        }
        location = resourceUrl("");
    }

    public boolean isClosed() { return closed; }

    /** Resolves without initialization and requires the entrypoint to belong to this archive. */
    public Class<?> localEntrypoint(String name) throws ClassNotFoundException {
        Class<?> found = Class.forName(name, false, this);
        if (found.getClassLoader() != this) throw new ClassNotFoundException("entrypoint_not_local");
        return found;
    }

    @Override protected Class<?> findClass(String name) throws ClassNotFoundException {
        if (closed || HOST_PREFIXES.stream().anyMatch(name::startsWith)) throw new ClassNotFoundException(name);
        try {
            VerifiedEntry entry = archive.read(name.replace('.', '/') + ".class");
            if (entry == null) throw new ClassNotFoundException(name);
            byte[] bytes = entry.bytes();
            int dot = name.lastIndexOf('.');
            if (dot > 0) defineArchivePackage(name.substring(0, dot));
            return defineClass(name, bytes, 0, bytes.length, new CodeSource(location, entry.codeSigners()));
        } catch (IOException error) {
            throw new ClassNotFoundException(name, error);
        }
    }

    private void defineArchivePackage(String name) {
        // ClassLoader is deliberately not parallel capable; its load lock serializes definitions.
        if (getDefinedPackage(name) != null) return;
        Attributes local = manifest.getAttributes(name.replace('.', '/') + "/");
        definePackage(name,
                attribute(local, Attributes.Name.SPECIFICATION_TITLE),
                attribute(local, Attributes.Name.SPECIFICATION_VERSION),
                attribute(local, Attributes.Name.SPECIFICATION_VENDOR),
                attribute(local, Attributes.Name.IMPLEMENTATION_TITLE),
                attribute(local, Attributes.Name.IMPLEMENTATION_VERSION),
                attribute(local, Attributes.Name.IMPLEMENTATION_VENDOR),
                "true".equalsIgnoreCase(attribute(local, Attributes.Name.SEALED)) ? location : null);
    }

    private String attribute(Attributes local, Attributes.Name name) {
        String value = local == null ? null : local.getValue(name);
        return value == null ? manifest.getMainAttributes().getValue(name) : value;
    }

    @Override protected URL findResource(String name) {
        if (closed) return null;
        try { return archive.contains(name) ? resourceUrl(name) : null; }
        catch (IOException | IllegalArgumentException error) { return null; }
    }

    @Override protected Enumeration<URL> findResources(String name) {
        URL found = findResource(name);
        return Collections.enumeration(found == null ? List.of() : List.of(found));
    }

    private URL resourceUrl(String name) throws IOException {
        final String address;
        try {
            address = new URI("msl-jar", archive.result().archiveSha256(), "/" + name, null).toASCIIString();
        } catch (URISyntaxException error) { throw new IOException("invalid_resource_name", error); }
        return new URL(null, address, new URLStreamHandler() {
            // Opaque archive identity comparisons must never perform DNS lookups.
            @Override protected boolean equals(URL first, URL second) {
                return first.toExternalForm().equals(second.toExternalForm());
            }
            @Override protected int hashCode(URL url) { return url.toExternalForm().hashCode(); }
            @Override protected boolean sameFile(URL first, URL second) { return equals(first, second); }
            @Override protected URLConnection openConnection(URL url) throws IOException {
                if (!address.equals(url.toExternalForm()) || name.isEmpty()) throw new IOException("invalid_resource_url");
                return new URLConnection(url) {
                    @Override public void connect() throws IOException {
                        if (closed) throw new IOException("archive_closed");
                        connected = true;
                    }
                    @Override public InputStream getInputStream() throws IOException {
                        connect();
                        VerifiedEntry entry = archive.read(name);
                        if (entry == null) throw new IOException("resource_not_found");
                        return new ByteArrayInputStream(entry.bytes());
                    }
                };
            }
        });
    }

    @Override public synchronized void close() throws IOException {
        closed = true;
        archive.close();
    }
}
