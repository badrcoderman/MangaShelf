package mangashelf.runtime;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.CodeSigner;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.cert.Certificate;
import java.security.cert.CertificateEncodingException;
import java.util.Enumeration;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Isolated host-side JAR v1 verifier; never loads or initializes archive classes.
 * The caller supplies a trusted SHA-256 of the whole archive and an independently
 * provisioned SHA-256 of the signing leaf certificate's DER encoding. A matching
 * self-signed/debug certificate proves that pinned key signed these bytes, not
 * publisher identity, certificate-chain validity, expiry, revocation, or safety.
 *
 * <p>Every physical payload entry (including META-INF resources and all versioned
 * entries) must have exactly one signer with the pinned leaf certificate. Only
 * canonical manifest/signature metadata and empty directory entries are exempt.
 * Disabled signature algorithms remain subject to the JDK's security policy.
 *
 * <p>verify returns data only and closes its snapshot. openVerified instead keeps
 * the exact checked JarFile open after unlinking its private snapshot on POSIX.
 * A loader must retain that handle, never reopen the caller's original path.
 * Neither entry point is wired into the production iOS target.
 *
 * <p>API contracts:
 * https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/jar/JarFile.html
 * https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/jar/JarEntry.html
 * https://docs.oracle.com/en/java/javase/17/docs/api/java.base/java/util/jar/JarInputStream.html
 * JarFile verifies content, not certificate trust. Signers are queried only after
 * EOF; JarInputStream's ordering constraints are deliberately avoided.
 */
public final class ExtensionArchiveVerifier {
    public static final long MAX_ARCHIVE_BYTES = 64L * 1024 * 1024;
    public static final long MAX_ENTRY_BYTES = 16L * 1024 * 1024;
    public static final long MAX_EXPANDED_BYTES = 128L * 1024 * 1024;
    public static final long MAX_SIGNATURE_METADATA_BYTES = 1024L * 1024;
    public static final int MAX_ENTRIES = 4096;
    public static final int MAX_NAME_BYTES = 4096;

    private ExtensionArchiveVerifier() {}

    public record Result(String archiveSha256, String signerCertificateSha256,
                         int entries, int payloadEntries, long expandedBytes) {}

    /** A fresh bounded copy of an entry, with the signers of its physical bytes. */
    public record VerifiedEntry(byte[] bytes, CodeSigner[] codeSigners) {
        public VerifiedEntry {
            bytes = bytes.clone();
            codeSigners = codeSigners == null ? new CodeSigner[0] : codeSigners.clone();
        }
        @Override public byte[] bytes() { return bytes.clone(); }
        @Override public CodeSigner[] codeSigners() { return codeSigners.clone(); }
    }

    /** Owns one unlinked, verified archive until close. No mutable path escapes. */
    public static final class VerifiedArchive implements AutoCloseable {
        private JarFile jar;
        private final Result result;
        private final List<String> names;

        private VerifiedArchive(JarFile jar, Result result) {
            this.jar = jar;
            this.result = result;
            List<String> found = new ArrayList<>();
            jar.entries().asIterator().forEachRemaining(entry -> found.add(entry.getName()));
            names = List.copyOf(found);
        }

        public Result result() { return result; }
        public List<String> entryNames() { return names; }
        public synchronized boolean isClosed() { return jar == null; }

        public synchronized boolean contains(String name) throws IOException {
            if (jar == null) throw failure("archive_closed");
            if (name == null) throw failure("invalid_argument");
            safeName(name);
            JarEntry entry = jar.getJarEntry(name);
            return entry != null && !entry.isDirectory();
        }

        /** Multi-release selection uses this VM's version; every physical entry was verified. */
        public synchronized VerifiedEntry read(String name) throws IOException {
            if (jar == null) throw failure("archive_closed");
            if (name == null) throw failure("invalid_argument");
            safeName(name);
            JarEntry entry = jar.getJarEntry(name);
            if (entry == null || entry.isDirectory()) return null;
            ByteArrayOutputStream output = new ByteArrayOutputStream((int) Math.min(entry.getSize(), 32 * 1024));
            try {
                readEntry(jar.getInputStream(entry), entry, entryLimit(entry.getName()), output);
                return new VerifiedEntry(output.toByteArray(), entry.getCodeSigners());
            } catch (SecurityException error) {
                throw failure("invalid_signature");
            }
        }

        @Override public synchronized void close() throws IOException {
            JarFile owned = jar;
            jar = null;
            if (owned != null) owned.close();
        }
    }

    public static final class VerificationException extends IOException {
        private static final long serialVersionUID = 1L;
        public final String code;

        private VerificationException(String code) {
            super(code);
            this.code = code;
        }
    }

    public static Result verify(Path archive, String expectedArchiveSha256,
                                String trustedSignerCertificateSha256, Path scratchDirectory) throws IOException {
        try (VerifiedArchive verified = openVerified(archive, expectedArchiveSha256,
                trustedSignerCertificateSha256, scratchDirectory)) {
            return verified.result();
        }
    }

    /**
     * Opens a bounded 0600 copy in a new 0700 child of the trusted scratch directory.
     * Unlinks it before signature verification and returns that same JarFile handle.
     * Platforms unable to unlink an open file fail; no mutable-path fallback exists.
     */
    public static VerifiedArchive openVerified(Path archive, String expectedArchiveSha256,
                                               String trustedSignerCertificateSha256,
                                               Path scratchDirectory) throws IOException {
        String expected = hashArgument(expectedArchiveSha256);
        String trusted = hashArgument(trustedSignerCertificateSha256);
        if (archive == null || scratchDirectory == null) throw failure("invalid_argument");
        if (!Files.isDirectory(scratchDirectory, LinkOption.NOFOLLOW_LINKS)) throw failure("invalid_argument");
        BasicFileAttributes attributes = Files.readAttributes(archive, BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS);
        if (!attributes.isRegularFile()) throw failure("invalid_archive");
        if (attributes.size() < 1 || attributes.size() > MAX_ARCHIVE_BYTES) throw failure("archive_limit");

        Path directory = Files.createTempDirectory(scratchDirectory, "msl-archive-verification-",
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        Path snapshot = null;
        JarFile jar = null;
        try {
            snapshot = Files.createTempFile(directory, "archive-", ".jar",
                    PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
            MessageDigest digest = sha256();
            long copied = 0;
            byte[] buffer = new byte[32 * 1024];
            try (InputStream input = Files.newInputStream(archive, LinkOption.NOFOLLOW_LINKS);
                 OutputStream output = Files.newOutputStream(snapshot)) {
                int count;
                while ((count = input.read(buffer)) != -1) {
                    copied += count;
                    if (copied > MAX_ARCHIVE_BYTES) throw failure("archive_limit");
                    digest.update(buffer, 0, count);
                    output.write(buffer, 0, count);
                }
            }
            String actual = HexFormat.of().formatHex(digest.digest());
            if (!actual.equals(expected)) throw failure("digest_mismatch");
            preflight(snapshot);
            jar = new JarFile(snapshot.toFile(), true, ZipFile.OPEN_READ, Runtime.version());
            Files.delete(snapshot);
            snapshot = null;
            Files.delete(directory);
            Result result = verifySignatures(jar, actual, trusted);
            return new VerifiedArchive(jar, result);
        } catch (SecurityException error) {
            VerificationException reported = failure("invalid_signature");
            cleanup(jar, snapshot, directory, reported);
            throw reported;
        } catch (IOException | RuntimeException | Error error) {
            cleanup(jar, snapshot, directory, error);
            throw error;
        }
    }

    private static void cleanup(JarFile jar, Path snapshot, Path directory, Throwable error) {
        try { if (jar != null) jar.close(); }
        catch (IOException failure) { error.addSuppressed(failure); }
        try { if (snapshot != null) Files.deleteIfExists(snapshot); }
        catch (IOException failure) { error.addSuppressed(failure); }
        try { Files.deleteIfExists(directory); }
        catch (IOException failure) { error.addSuppressed(failure); }
    }

    /** Bounds metadata before JarFile can eagerly parse manifest/signature files. */
    private static void preflight(Path archive) throws IOException {
        try (ZipFile zip = new ZipFile(archive.toFile())) {
            Set<String> names = new HashSet<>();
            Set<String> metadata = new HashSet<>();
            long total = 0;
            int count = 0;
            Enumeration<? extends ZipEntry> entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (++count > MAX_ENTRIES) throw failure("entry_count_limit");
                String name = entry.getName();
                safeName(name);
                if (!names.add(name)) throw failure("duplicate_entry");
                if (isSignatureMetadata(name)) {
                    if (!metadata.add(name.toUpperCase(Locale.ROOT))) throw failure("duplicate_entry");
                }
                if (entry.getSize() < 0 || entry.getSize() > entryLimit(name)) throw failure("entry_size_limit");
                if (entry.getCompressedSize() < 0 || entry.getCompressedSize() > MAX_ARCHIVE_BYTES) {
                    throw failure("invalid_archive");
                }
                if (entry.isDirectory() && entry.getSize() != 0) throw failure("invalid_archive");
                total += readEntry(zip.getInputStream(entry), entry, entryLimit(name));
                if (total > MAX_EXPANDED_BYTES) throw failure("expanded_size_limit");
            }
            if (!metadata.contains(JarFile.MANIFEST_NAME)) throw failure("missing_manifest");
            boolean signaturePair = false;
            for (String name : metadata) {
                if (name.endsWith(".SF")) {
                    String base = name.substring(0, name.length() - 3);
                    if (!(metadata.contains(base + ".RSA") || metadata.contains(base + ".DSA")
                            || metadata.contains(base + ".EC"))) throw failure("invalid_signature_metadata");
                    signaturePair = true;
                } else if (!name.equals(JarFile.MANIFEST_NAME)) {
                    String base = name.substring(0, name.lastIndexOf('.'));
                    if (!metadata.contains(base + ".SF")) throw failure("invalid_signature_metadata");
                }
            }
            if (!signaturePair) throw failure("unsigned_archive");
        }
    }

    private static Result verifySignatures(JarFile jar, String digest, String trusted) throws IOException {
        int count = 0;
        int payloads = 0;
        long expanded = 0;
        {
            Enumeration<JarEntry> entries = jar.entries();
            while (entries.hasMoreElements()) {
                JarEntry entry = entries.nextElement();
                ++count;
                expanded += readEntry(jar.getInputStream(entry), entry, entryLimit(entry.getName()));
                if (entry.isDirectory() || isSignatureMetadata(entry.getName())) continue;
                ++payloads;
                // JarFile populates signers only after the input stream reaches EOF.
                CodeSigner[] signers = entry.getCodeSigners();
                if (signers == null || signers.length == 0) throw failure("unsigned_entry");
                if (signers.length != 1) throw failure("multiple_signers");
                List<? extends Certificate> certificates = signers[0].getSignerCertPath().getCertificates();
                if (certificates.isEmpty()) throw failure("invalid_signature");
                try {
                    String leaf = HexFormat.of().formatHex(sha256().digest(certificates.get(0).getEncoded()));
                    if (!trusted.equals(leaf)) throw failure("signer_mismatch");
                } catch (CertificateEncodingException error) {
                    throw failure("invalid_signature");
                }
            }
        }
        if (payloads == 0) throw failure("no_payload");
        return new Result(digest, trusted, count, payloads, expanded);
    }

    private static long readEntry(InputStream stream, ZipEntry entry, long limit) throws IOException {
        return readEntry(stream, entry, limit, null);
    }

    private static long readEntry(InputStream stream, ZipEntry entry, long limit, OutputStream output) throws IOException {
        long count = 0;
        CRC32 crc = new CRC32();
        byte[] buffer = new byte[32 * 1024];
        try (InputStream input = stream) {
            int length;
            while ((length = input.read(buffer)) != -1) {
                count += length;
                if (count > limit) throw failure("entry_size_limit");
                crc.update(buffer, 0, length);
                if (output != null) output.write(buffer, 0, length);
            }
        }
        if (count != entry.getSize() || crc.getValue() != entry.getCrc()) throw failure("invalid_archive");
        return count;
    }

    private static long entryLimit(String name) {
        return isSignatureMetadata(name) ? MAX_SIGNATURE_METADATA_BYTES : MAX_ENTRY_BYTES;
    }

    private static boolean isSignatureMetadata(String name) {
        return name.equals(JarFile.MANIFEST_NAME)
                || name.matches("META-INF/[A-Z0-9_-]{1,8}\\.(SF|RSA|DSA|EC)");
    }

    private static void safeName(String name) throws VerificationException {
        if (name.isEmpty() || name.getBytes(StandardCharsets.UTF_8).length > MAX_NAME_BYTES
                || name.startsWith("/") || name.indexOf('\\') >= 0 || name.indexOf(':') >= 0) {
            throw failure("unsafe_entry_name");
        }
        for (int index = 0; index < name.length(); ++index) {
            if (Character.isISOControl(name.charAt(index))) throw failure("unsafe_entry_name");
        }
        String path = name.endsWith("/") ? name.substring(0, name.length() - 1) : name;
        for (String segment : path.split("/", -1)) {
            if (segment.isEmpty() || segment.equals(".") || segment.equals("..")) throw failure("unsafe_entry_name");
        }
        // Reject aliases of signing metadata; the verifier and loader must see one name.
        if (isSignatureMetadata(name.toUpperCase(Locale.ROOT)) && !isSignatureMetadata(name)) {
            throw failure("ambiguous_signature_metadata");
        }
    }

    private static String hashArgument(String value) throws VerificationException {
        if (value == null || !value.matches("[0-9a-fA-F]{64}")) throw failure("invalid_argument");
        return value.toLowerCase(Locale.ROOT);
    }

    private static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    private static VerificationException failure(String code) { return new VerificationException(code); }

    /** Diagnostic CLI for data inspection; its class path must contain only project code. */
    public static void main(String[] arguments) {
        if (arguments.length != 4) {
            System.out.println("{\"verified\":false,\"code\":\"invalid_argument\"}");
            System.exit(1);
        }
        try {
            Result result = verify(Path.of(arguments[0]), arguments[1], arguments[2], Path.of(arguments[3]));
            System.out.println("{\"verified\":true,\"archiveSha256\":\"" + result.archiveSha256()
                    + "\",\"signerCertificateSha256\":\"" + result.signerCertificateSha256()
                    + "\",\"entries\":" + result.entries() + ",\"payloadEntries\":" + result.payloadEntries()
                    + ",\"expandedBytes\":" + result.expandedBytes() + "}");
        } catch (IOException | RuntimeException error) {
            String code = error instanceof VerificationException
                    ? ((VerificationException) error).code : "invalid_archive";
            System.out.println("{\"verified\":false,\"code\":\"" + code + "\"}");
            System.exit(1);
        }
    }
}
