package android.preference;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.Objects;

public final class PreferenceManager {
    private PreferenceManager() {}
    public static SharedPreferences getDefaultSharedPreferences(Context context) {
        Context application = Objects.requireNonNull(context).getApplicationContext();
        return application.getSharedPreferences(application.getPackageName() + "_preferences", Context.MODE_PRIVATE);
    }
}
