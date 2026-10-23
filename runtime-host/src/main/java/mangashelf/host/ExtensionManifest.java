package mangashelf.host;

import java.io.IOException;
import java.io.StringReader;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import javax.xml.XMLConstants;
import javax.xml.parsers.ParserConfigurationException;
import javax.xml.parsers.SAXParserFactory;
import org.xml.sax.Attributes;
import org.xml.sax.InputSource;
import org.xml.sax.SAXException;
import org.xml.sax.SAXParseException;
import org.xml.sax.XMLReader;
import org.xml.sax.helpers.DefaultHandler;

/** Bounded text AndroidManifest contract, parsed from the verified archive only. */
public record ExtensionManifest(String packageName, BigInteger versionCode, String versionName,
                                String mainClass, String libraryVersion) {
    private static final String ANDROID = "http://schemas.android.com/apk/res/android";
    private static final BigInteger MAX_VERSION = BigInteger.ONE.shiftLeft(64).subtract(BigInteger.ONE);

    public static ExtensionManifest parse(byte[] bytes) throws IOException {
        if (bytes == null || bytes.length == 0 || bytes.length > 256 * 1024) throw invalid(null);
        final String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException error) { throw invalid(error); }
        String upper = text.toUpperCase(Locale.ROOT);
        if (text.indexOf('\0') >= 0 || upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY")) throw invalid(null);
        Reader handler = new Reader();
        try {
            SAXParserFactory factory = SAXParserFactory.newDefaultInstance();
            factory.setNamespaceAware(true);
            factory.setXIncludeAware(false);
            factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
            factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false);
            XMLReader reader = factory.newSAXParser().getXMLReader();
            reader.setProperty(XMLConstants.ACCESS_EXTERNAL_DTD, "");
            reader.setProperty(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
            reader.setContentHandler(handler);
            reader.setEntityResolver(handler);
            reader.setErrorHandler(handler);
            reader.parse(new InputSource(new StringReader(text)));
        } catch (ParserConfigurationException | SAXException error) { throw invalid(error); }
        if (!handler.path.isEmpty() || !validName(handler.pkg) || handler.code == null
                || !handler.application || !handler.feature || handler.source == null) throw invalid(null);
        String main = handler.source.strip();
        if (main.startsWith(".")) main = handler.pkg + main;
        if (!validName(main)) throw invalid(null);
        return new ExtensionManifest(handler.pkg, handler.code, handler.version, main, handler.library);
    }

    private static boolean validName(String name) {
        return name != null && name.length() <= 512
                && name.matches("[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)*");
    }

    private static IOException invalid(Throwable cause) { return new IOException("invalid_extension_manifest", cause); }

    private static final class Reader extends DefaultHandler {
        private final List<String> path = new ArrayList<>();
        private int elements;
        private String pkg, version, source, library;
        private BigInteger code;
        private boolean application, feature, librarySeen;

        @Override public void startElement(String uri, String local, String qualified, Attributes attributes) throws SAXException {
            if (!uri.isEmpty() || path.size() >= 32 || ++elements > 4096 || attributes.getLength() > 64) fail();
            path.add(local);
            if (path.size() == 1) {
                if (!local.equals("manifest")) fail();
                pkg = attributes.getValue("", "package");
                String value = attributes.getValue(ANDROID, "versionCode");
                if (value == null || value.length() > 20 || !value.matches("[0-9]+")) fail();
                code = new BigInteger(value);
                if (code.compareTo(MAX_VERSION) > 0) fail();
                version = attributes.getValue(ANDROID, "versionName");
            } else if (path.equals(List.of("manifest", "application"))) {
                if (application) fail();
                application = true;
            } else if (path.equals(List.of("manifest", "uses-feature"))) {
                if ("tachiyomi.extension".equals(attributes.getValue(ANDROID, "name"))) feature = true;
            } else if (path.equals(List.of("manifest", "application", "meta-data"))) {
                String name = attributes.getValue(ANDROID, "name");
                if ("tachiyomi.extension.class".equals(name)) {
                    if (source != null) fail();
                    source = attributes.getValue(ANDROID, "value");
                    if (source == null) fail();
                } else if ("tachiyomix.extensionLib".equals(name)) {
                    if (librarySeen) fail();
                    librarySeen = true;
                    library = attributes.getValue(ANDROID, "value");
                    if (library == null) fail();
                }
            }
        }

        @Override public void endElement(String uri, String local, String qualified) throws SAXException {
            if (path.isEmpty() || !path.remove(path.size() - 1).equals(local)) fail();
        }
        @Override public InputSource resolveEntity(String publicId, String systemId) throws SAXException { fail(); return null; }
        @Override public void error(SAXParseException error) throws SAXException { throw error; }
        @Override public void fatalError(SAXParseException error) throws SAXException { throw error; }
        private static void fail() throws SAXException { throw new SAXException("invalid_extension_manifest"); }
    }
}
