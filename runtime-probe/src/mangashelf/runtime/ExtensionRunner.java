package mangashelf.runtime;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Experimental host runner for MangaShelf's explicit JSON fixture contract.
 * Sources must expose the exact methods below and return JSON strings. This is
 * not an adapter for Tachiyomi objects, source factories, RxJava, or Android.
 * Running it does not prove compatibility with iOS or real extensions.
 */
public final class ExtensionRunner {
    private static final int MAX_REQUEST_CHARS = 256 * 1024;
    private static final int MAX_RESPONSE_CHARS = 4 * 1024 * 1024;
    private static final Map<String, LoadedSource> packages = new HashMap<>();
    private static final Map<String, LoadedSource> sources = new HashMap<>();

    private ExtensionRunner() {}

    /** Serializes registry changes and invocations, including archive loader closure. */
    public static synchronized String dispatch(String action, String payload) {
        if (action == null || action.isEmpty()) return errorJson("invalid_action", "Missing action.");
        try {
            Map<String, Object> request = object(Json.parse(payload == null ? "{}" : payload, MAX_REQUEST_CHARS));
            switch (action) {
                case "ping":
                    return "{\"status\":\"ok\",\"engine\":\"MangaShelf experimental host runner\",\"version\":\"1.0.0\"}";
                case "load": return load(request);
                case "unload": return unload(request);
                case "popular":
                    return invoke(action, request, "popularManga", new Class<?>[]{int.class}, page(request));
                case "search":
                    return invoke(action, request, "searchManga", new Class<?>[]{int.class, String.class},
                            page(request), optionalString(request, "query", ""));
                case "details":
                    return invoke(action, request, "mangaDetails", new Class<?>[]{String.class}, requiredString(request, "url"));
                case "chapters":
                    return invoke(action, request, "chapterList", new Class<?>[]{String.class}, requiredString(request, "url"));
                case "pages":
                    return invoke(action, request, "pageList", new Class<?>[]{String.class}, requiredString(request, "url"));
                default: return errorJson("unknown_action", "Unknown action: " + action);
            }
        } catch (RunnerFailure e) {
            return errorJson(e.code, e.getMessage());
        } catch (RuntimeException e) {
            return errorJson("dispatch_failed", "Dispatch failed: " + e.getClass().getSimpleName());
        }
    }

    private static String load(Map<String, Object> request) {
        String pkg = requiredString(request, "package");
        String mainClass = requiredString(request, "mainClass");
        String sourceId = optionalString(request, "sourceId", pkg);
        if (sourceId.isEmpty()) throw failure("invalid_request", "Missing sourceId.");
        if (packages.containsKey(pkg)) throw failure("already_loaded", "Unload the package before loading it again.");
        if (sources.containsKey(sourceId)) throw failure("source_conflict", "The source identifier is already loaded.");
        URLClassLoader archiveLoader = null;
        try {
            String path = optionalString(request, "path", "");
            ClassLoader loader = ExtensionRunner.class.getClassLoader();
            if (!path.isEmpty()) {
                File jarFile = new File(path);
                if (!jarFile.isFile()) throw failure("load_failed", "Extension archive file not found.");
                archiveLoader = new URLClassLoader(new URL[]{jarFile.toURI().toURL()}, loader);
                loader = archiveLoader;
            }
            Object instance = Class.forName(mainClass, true, loader).getDeclaredConstructor().newInstance();
            LoadedSource loaded = new LoadedSource(sourceId, archiveLoader, instance);
            packages.put(pkg, loaded);
            sources.put(sourceId, loaded);
            return "{\"status\":\"loaded\",\"package\":" + quote(pkg)
                    + ",\"sourceId\":" + quote(sourceId) + ",\"hasInstance\":true}";
        } catch (ReflectiveOperationException | IOException | LinkageError | RuntimeException e) {
            if (archiveLoader != null) {
                try { archiveLoader.close(); }
                catch (IOException closeError) { e.addSuppressed(closeError); }
            }
            if (e instanceof RunnerFailure) throw (RunnerFailure) e;
            Throwable cause = e instanceof InvocationTargetException ? ((InvocationTargetException) e).getCause() : e;
            throw failure("load_failed", "Could not create source instance: " + cause.getClass().getSimpleName());
        }
    }

    private static String unload(Map<String, Object> request) {
        String pkg = requiredString(request, "package");
        LoadedSource loaded = packages.remove(pkg);
        if (loaded == null) throw failure("not_loaded", "The package is not loaded.");
        sources.remove(loaded.sourceId);
        if (loaded.loader != null) {
            try { loaded.loader.close(); }
            catch (IOException e) {
                return "{\"status\":\"unloaded\",\"package\":" + quote(pkg)
                        + ",\"warning\":\"The archive handle could not be closed.\"}";
            }
        }
        // This removes registrations; it does not guarantee JVM class unloading.
        return "{\"status\":\"unloaded\",\"package\":" + quote(pkg) + "}";
    }

    private static String invoke(String action, Map<String, Object> request, String methodName,
                                 Class<?>[] signature, Object... arguments) {
        String sourceId = requiredString(request, "sourceId");
        LoadedSource source = sources.get(sourceId);
        if (source == null) throw failure("source_not_loaded", "The requested source is not loaded.");
        final Method method;
        try { method = source.instance.getClass().getMethod(methodName, signature); }
        catch (NoSuchMethodException e) {
            throw failure("unsupported_method", "The source does not implement " + methodName + " with the required signature.");
        }
        final Object result;
        try { result = method.invoke(source.instance, arguments); }
        catch (InvocationTargetException e) {
            throw failure("invocation_failed", "Source method " + methodName + " failed: " + e.getCause().getClass().getSimpleName());
        } catch (ReflectiveOperationException | RuntimeException e) {
            throw failure("invocation_failed", "Could not invoke source method " + methodName + ".");
        }
        if (!(result instanceof String)) throw failure("invalid_response", "The source must return a JSON string.");
        String json = (String) result;
        try { validateResult(action, Json.parse(json, MAX_RESPONSE_CHARS)); }
        catch (RunnerFailure e) { throw failure("invalid_response", "The source returned invalid " + action + " data: " + e.getMessage()); }
        return json;
    }

    private static void validateResult(String action, Object result) {
        if (action.equals("details")) {
            Map<String, Object> item = object(result);
            requiredString(item, "title");
            for (String key : new String[]{"author", "artist", "description", "status", "coverURL"}) nullableString(item, key);
            for (Object genre : array(item.get("genre"))) {
                if (!(genre instanceof String)) throw failure("invalid_response", "genre entries must be strings.");
            }
            return;
        }
        List<?> entries = array(result);
        if (entries.size() > (action.equals("pages") ? 4096 : 30_000)) throw failure("invalid_response", "Too many entries.");
        if (action.equals("pages") && entries.isEmpty()) throw failure("invalid_response", "No chapter pages were returned.");
        for (Object entry : entries) {
            Map<String, Object> item = object(entry);
            if (action.equals("popular") || action.equals("search")) {
                requiredString(item, "id"); requiredString(item, "title"); requiredString(item, "url");
                nullableString(item, "coverURL");
            } else if (action.equals("chapters")) {
                requiredString(item, "id"); requiredString(item, "url"); string(item, "name");
                BigDecimal number = number(item.get("chapterNumber"));
                if (!Float.isFinite(number.floatValue())) throw failure("invalid_response", "Invalid chapter number.");
                integer(item.get("dateUpload")); nullableString(item, "scanlator");
            } else {
                long index = integer(item.get("index"));
                if (index < 0 || index >= 4096) throw failure("invalid_response", "Invalid page index.");
                requiredString(item, "url"); nullableString(item, "imageURL");
            }
        }
    }

    private static int page(Map<String, Object> request) {
        long page = request.containsKey("page") ? integer(request.get("page")) : 1;
        if (page < 1 || page > 10_000) throw failure("invalid_request", "Invalid page number.");
        return (int) page;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> object(Object value) {
        if (!(value instanceof Map)) throw failure("invalid_request", "Expected a JSON object.");
        return (Map<String, Object>) value;
    }

    private static List<?> array(Object value) {
        if (!(value instanceof List)) throw failure("invalid_request", "Expected a JSON array.");
        return (List<?>) value;
    }

    private static String string(Map<String, Object> object, String key) {
        Object value = object.get(key);
        if (!(value instanceof String)) throw failure("invalid_request", "Expected string field: " + key);
        return (String) value;
    }

    private static String requiredString(Map<String, Object> object, String key) {
        String value = string(object, key);
        if (value.isEmpty()) throw failure("invalid_request", "Empty field: " + key);
        return value;
    }

    private static String optionalString(Map<String, Object> object, String key, String fallback) {
        return object.containsKey(key) ? string(object, key) : fallback;
    }

    private static void nullableString(Map<String, Object> object, String key) {
        Object value = object.get(key);
        if (value != null && !(value instanceof String)) throw failure("invalid_response", "Expected a string or null: " + key);
    }

    private static BigDecimal number(Object value) {
        if (!(value instanceof BigDecimal)) throw failure("invalid_request", "Expected a JSON number.");
        return (BigDecimal) value;
    }

    private static long integer(Object value) {
        try { return number(value).longValueExact(); }
        catch (ArithmeticException e) { throw failure("invalid_request", "Expected a 64-bit integer."); }
    }

    private static String quote(String value) {
        StringBuilder result = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"': result.append("\\\""); break;
                case '\\': result.append("\\\\"); break;
                case '\b': result.append("\\b"); break;
                case '\f': result.append("\\f"); break;
                case '\n': result.append("\\n"); break;
                case '\r': result.append("\\r"); break;
                case '\t': result.append("\\t"); break;
                default:
                    if (c < 32 || Character.isSurrogate(c)) result.append(String.format("\\u%04x", (int) c));
                    else result.append(c);
            }
        }
        return result.append('"').toString();
    }

    private static String errorJson(String code, String message) {
        return "{\"error\":" + quote(message) + ",\"code\":" + quote(code) + "}";
    }

    private static RunnerFailure failure(String code, String message) { return new RunnerFailure(code, message); }

    private static final class RunnerFailure extends RuntimeException {
        private static final long serialVersionUID = 1L;
        final String code;
        RunnerFailure(String code, String message) { super(message); this.code = code; }
    }

    private static final class LoadedSource {
        final String sourceId;
        final URLClassLoader loader;
        final Object instance;
        LoadedSource(String sourceId, URLClassLoader loader, Object instance) {
            this.sourceId = sourceId; this.loader = loader; this.instance = instance;
        }
    }

    /** Bounded JSON decoding for the experimental contract, with no runtime dependency. */
    private static final class Json {
        private final String input;
        private int position;
        private int values;
        private Json(String input) { this.input = input; }

        static Object parse(String input, int limit) {
            if (input == null || input.length() > limit) throw failure("invalid_request", "JSON exceeds the size limit.");
            Json parser = new Json(input);
            Object value = parser.value(0);
            parser.whitespace();
            if (parser.position != input.length()) throw parser.invalid();
            return value;
        }

        private Object value(int depth) {
            if (depth > 32 || ++values > 100_000) throw failure("invalid_request", "JSON exceeds the structure limit.");
            whitespace();
            if (position == input.length()) throw invalid();
            char token = input.charAt(position);
            if (token == '"') return text();
            if (token == '{') {
                position++;
                Map<String, Object> result = new LinkedHashMap<>();
                whitespace();
                if (take('}')) return result;
                do {
                    whitespace();
                    if (position == input.length() || input.charAt(position) != '"') throw invalid();
                    String key = text(); whitespace();
                    if (!take(':') || result.containsKey(key)) throw invalid();
                    result.put(key, value(depth + 1)); whitespace();
                    if (take('}')) return result;
                } while (take(','));
                throw invalid();
            }
            if (token == '[') {
                position++;
                List<Object> result = new ArrayList<>();
                whitespace();
                if (take(']')) return result;
                do {
                    result.add(value(depth + 1)); whitespace();
                    if (take(']')) return result;
                } while (take(','));
                throw invalid();
            }
            if (token == 't') return literal("true", Boolean.TRUE);
            if (token == 'f') return literal("false", Boolean.FALSE);
            if (token == 'n') return literal("null", null);
            return numeric();
        }

        private Object literal(String token, Object value) {
            if (!input.startsWith(token, position)) throw invalid();
            position += token.length(); return value;
        }

        private BigDecimal numeric() {
            int start = position;
            take('-');
            if (!take('0')) digits();
            if (take('.')) digits();
            if (take('e') || take('E')) { if (!take('+')) take('-'); digits(); }
            if (position == start || position - start > 128) throw invalid();
            try { return new BigDecimal(input.substring(start, position)); }
            catch (NumberFormatException e) { throw invalid(); }
        }

        private void digits() {
            int start = position;
            while (position < input.length() && input.charAt(position) >= '0' && input.charAt(position) <= '9') position++;
            if (start == position) throw invalid();
        }

        private String text() {
            position++;
            StringBuilder result = new StringBuilder();
            boolean closed = false;
            while (position < input.length()) {
                char c = input.charAt(position++);
                if (c == '"') { closed = true; break; }
                if (c < 32) throw invalid();
                if (c == '\\') {
                    if (position == input.length()) throw invalid();
                    c = input.charAt(position++);
                    switch (c) {
                        case '"': case '\\': case '/': break;
                        case 'b': c = '\b'; break;
                        case 'f': c = '\f'; break;
                        case 'n': c = '\n'; break;
                        case 'r': c = '\r'; break;
                        case 't': c = '\t'; break;
                        case 'u':
                            if (input.length() - position < 4) throw invalid();
                            int code = 0;
                            for (int i = 0; i < 4; i++) {
                                char hex = input.charAt(position++);
                                int digit = hex >= '0' && hex <= '9' ? hex - '0'
                                        : hex >= 'a' && hex <= 'f' ? hex - 'a' + 10
                                        : hex >= 'A' && hex <= 'F' ? hex - 'A' + 10 : -1;
                                if (digit < 0) throw invalid();
                                code = code * 16 + digit;
                            }
                            c = (char) code; break;
                        default: throw invalid();
                    }
                }
                result.append(c);
            }
            if (!closed) throw invalid();
            for (int i = 0; i < result.length(); i++) {
                char c = result.charAt(i);
                if (Character.isHighSurrogate(c)) {
                    if (++i == result.length() || !Character.isLowSurrogate(result.charAt(i))) throw invalid();
                } else if (Character.isLowSurrogate(c)) throw invalid();
            }
            return result.toString();
        }

        private boolean take(char expected) {
            if (position < input.length() && input.charAt(position) == expected) { position++; return true; }
            return false;
        }

        private void whitespace() {
            while (position < input.length()) {
                char c = input.charAt(position);
                if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
                position++;
            }
        }

        private RunnerFailure invalid() { return failure("invalid_request", "Malformed JSON at character " + position + "."); }
    }
}
