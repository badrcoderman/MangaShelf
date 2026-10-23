package android.app;

import android.content.Context;
import java.io.IOException;
import java.nio.file.Path;

/** File/preferences application context required by source helpers; no Android lifecycle/UI. */
public class Application extends Context {
    public Application() { super(); }
    public Application(Path directory, String packageName) throws IOException { super(directory, packageName); }
}
