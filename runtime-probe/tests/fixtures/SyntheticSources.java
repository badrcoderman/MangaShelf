package mangashelf.fixtures;

/** Project-authored host fixtures. Never part of the application or a real extension. */
public final class SyntheticSources {
    private SyntheticSources() {}

    public static final class Good {
        public Object popularManga(int page) {
            switch (page) {
                case 2: throw new IllegalStateException("Synthetic invocation failure");
                case 3: return null;
                case 4: return Integer.valueOf(42);
                case 5: return "[invalid";
                case 6: return "{}";
                case 7: return "[{}]";
                case 8: return "[]";
                case 9: return "[{\"id\":\"a\",\"title\":4,\"url\":\"/a\"}]";
                case 10:
                    StringBuilder oversized = new StringBuilder();
                    for (int i = 0; i < 4 * 1024 * 1024 + 1; i++) oversized.append(' ');
                    return oversized.toString();
                case 11: return "[{\"id\":\"a\",\"id\":\"b\",\"title\":\"t\",\"url\":\"/a\"}]";
                case 12: return "[null]";
                case 13: throw new AssertionError("Synthetic source error");
                default: return "[{\"id\":\"fixture-popular\",\"title\":\"Synthetic Popular\",\"url\":\"/fixture/manga\",\"coverURL\":null}]";
            }
        }

        // Returning the supplied JSON lets the Python test compare independent serialization.
        public Object searchManga(int page, String query) {
            if (query.equals("throw")) throw new IllegalArgumentException("Synthetic search failure");
            return query;
        }

        public Object mangaDetails(String url) {
            if (url.equals("throw")) throw new IllegalStateException("Synthetic details failure");
            if (url.equals("null")) return null;
            if (url.equals("wrong-shape")) return "{}";
            if (url.equals("wrong-genre")) return "{\"title\":\"Synthetic\",\"genre\":[1]}";
            if (url.equals("malformed")) return "{\"title\":\"Synthetic\",\"genre\":[]}" + "trailing";
            return "{\"title\":\"Synthetic Details\",\"author\":null,\"artist\":null,\"description\":\"Fixture only\",\"genre\":[\"Test\"],\"status\":\"ongoing\",\"coverURL\":null}";
        }

        public Object chapterList(String url) {
            if (url.equals("throw")) throw new IllegalStateException("Synthetic chapters failure");
            if (url.equals("null")) return null;
            if (url.equals("wrong-shape")) return "[{}]";
            if (url.equals("empty")) return "[]";
            String number = url.equals("infinite-number") ? "1e1000" : "1.5";
            String date = url.equals("fractional-date") ? "1.5" : url.equals("overflow-date") ? "9223372036854775808" : "1700000000";
            return "[{\"id\":\"fixture-chapter\",\"name\":\"Synthetic Chapter\",\"url\":\"/fixture/chapter\",\"chapterNumber\":" + number
                    + ",\"dateUpload\":" + date + ",\"scanlator\":null}]";
        }

        public Object pageList(String url) {
            if (url.equals("throw")) throw new IllegalStateException("Synthetic pages failure");
            if (url.equals("null")) return null;
            if (url.equals("wrong-shape")) return "[{}]";
            if (url.equals("empty")) return "[]";
            String index = url.equals("negative-index") ? "-1" : url.equals("overflow-index") ? "4096" : "0";
            return "[{\"index\":" + index + ",\"url\":\"/fixture/page\",\"imageURL\":\"https://fixture.invalid/page.png\"}]";
        }
    }

    public static final class NoMethods { public NoMethods() {} }

    public static final class WrongSignature {
        public String popularManga(String page) { throw new AssertionError("Wrong signature was invoked"); }
        public String searchManga(String query, int page) { throw new AssertionError("Wrong signature was invoked"); }
    }

    public static final class BrokenConstructor {
        public BrokenConstructor() { throw new IllegalStateException("Synthetic constructor failure"); }
    }
}
