package mangashelf.runtime;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

/** Line protocol used only by scripts/test_extension_runner.py with synthetic inputs. */
public final class RunnerHost {
    private RunnerHost() {}
    private static String decode(String input) {
        return input.equals("-") ? null : new String(Base64.getDecoder().decode(input), StandardCharsets.UTF_8);
    }
    public static void main(String[] args) throws Exception {
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = reader.readLine()) != null) {
            String[] fields = line.split("\t", -1);
            if (fields.length != 2) throw new IllegalArgumentException("Invalid host test protocol");
            String reply = ExtensionRunner.dispatch(decode(fields[0]), decode(fields[1]));
            System.out.println(Base64.getEncoder().encodeToString(reply.getBytes(StandardCharsets.UTF_8)));
        }
    }
    public static final class ClasspathSource {
        public String popularManga(int page) { return "[]"; }
    }
}
