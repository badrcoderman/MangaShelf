package mangashelf.host

import android.app.Application
import android.content.Context
import android.preference.PreferenceManager
import eu.kanade.tachiyomi.AppInfo
import eu.kanade.tachiyomi.network.NetworkHelper
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.InjektScope
import uy.kohesive.injekt.api.LocalScoped
import uy.kohesive.injekt.api.addSingleton
import uy.kohesive.injekt.api.get
import uy.kohesive.injekt.api.getOrNull
import uy.kohesive.injekt.registry.default.DefaultRegistrar

/** Host startup/lifecycle and the same type-based lookups used by public source helpers. */
object BootstrapCheck {
    private class Local(scope: InjektScope) : LocalScoped(scope) {
        fun protectedScope(): InjektScope = localScope
    }
    private inline fun <reified T : Throwable> fails(body: () -> Unit): T {
        try { body() }
        catch (error: Throwable) { if (error is T) return error; throw error }
        error("Expected ${T::class.java.name}")
    }
    private fun uninstalled() {
        fails<IllegalStateException> { HostServices.current }
        fails<IllegalStateException> { Context() }
        check(Injekt.getOrNull<Application>() == null && Injekt.getOrNull<NetworkHelper>() == null)
    }

    @JvmStatic
    fun main(args: Array<String>) {
        val root = Path.of(args.single())
        val checks = linkedMapOf<String, Boolean>()
        fun case(name: String, body: () -> Unit) {
            System.err.println("START $name")
            try { body() }
            catch (error: Throwable) { System.err.println("FAIL $name: ${error.javaClass.name}: ${error.message}"); throw error }
            checks[name] = true
            System.err.println("PASS $name")
        }
        uninstalled()
        case("application_context_and_network_are_injected_with_exact_parent_type_identity") {
            val app = Application(root.resolve("identity"), "app.mangashelf.bootstrap")
            val state = HostServices.configure(app, "test-identity", 8, "MangaShelf-Test/8")
            try {
                check(state.context === app && Injekt.get<Application>() === app && Injekt.get<Context>() === app)
                check(Injekt.get<NetworkHelper>() === state.network)
                check(Context().applicationContext === app && app.applicationContext === app)
                check(AppInfo.getVersionName() == "test-identity" && AppInfo.getVersionCode() == 8)
                val defaults = PreferenceManager.getDefaultSharedPreferences(Injekt.get<Application>())
                check(defaults === app.getSharedPreferences("app.mangashelf.bootstrap_preferences", 0))
            } finally { HostServices.close() }
            uninstalled()
        }
        case("public_inline_helpers_cross_modules_and_preserve_the_protected_scope_getter") {
            HostServices.configure(Application(root.resolve("inline"), "app.mangashelf.bootstrap"), "test", 8, "MangaShelf-Test/8")
            try {
                val local = Local(Injekt)
                val eager by local.injectValue<Application>()
                val lazy by local.injectLazy<NetworkHelper>()
                check(local.protectedScope() === Injekt && eager === HostServices.current.context && lazy === HostServices.current.network)
            } finally { HostServices.close() }
        }
        case("close_clears_injection_and_reopen_restores_durable_source_preferences") {
            val path = root.resolve("reopen")
            val first = HostServices.configure(Application(path, "app.mangashelf.bootstrap"), "first", 8, "MangaShelf-Test/8")
            val oldInjector = Injekt
            first.context.getSharedPreferences("source_-41", 0).edit().putString("title", "العربية 📚").apply()
            HostServices.close(); HostServices.close(); uninstalled()
            val second = HostServices.configure(Application(path, "app.mangashelf.bootstrap"), "second", 9, "MangaShelf-Test/9")
            try {
                check(second.context !== first.context && second.network !== first.network && Injekt !== oldInjector)
                check(Injekt.get<Application>() === second.context && AppInfo.getVersionName() == "second")
                check(Injekt.get<Application>().getSharedPreferences("source_-41", 0).getString("title", "") == "العربية 📚")
            } finally { HostServices.close() }
        }
        case("startup_failure_preserves_existing_context_and_injector_and_caller_ownership") {
            val previous = Application(root.resolve("previous"), "app.mangashelf.previous")
            val candidate = Application(root.resolve("candidate"), "app.mangashelf.candidate")
            val original = Injekt
            val external = InjektScope(DefaultRegistrar()).apply { addSingleton<String>("previous owner") }
            Context.installDefault(previous); Injekt = external
            try {
                val error = fails<IllegalStateException> { HostServices.configure(candidate, "test", 8, "MangaShelf-Test/8") }
                check(error.message == "application_context_already_installed" && Injekt === external)
                check(Injekt.get<String>() == "previous owner" && Context().applicationContext === previous)
                fails<IllegalStateException> { HostServices.current }
                check(candidate.getSharedPreferences("still-owned", 0).edit().putBoolean("open", true).commit())
            } finally { candidate.close(); previous.close(); Injekt = original }
        }
        case("duplicate_startup_does_not_replace_live_services_or_close_the_candidate") {
            val first = HostServices.configure(Application(root.resolve("first"), "app.mangashelf.bootstrap"), "first", 8, "MangaShelf-Test/8")
            val original = Injekt
            val candidate = Application(root.resolve("second"), "app.mangashelf.candidate")
            try {
                fails<IllegalStateException> { HostServices.configure(candidate, "second", 9, "MangaShelf-Test/9") }
                check(HostServices.current === first && Injekt === original && Injekt.get<Application>() === first.context)
                check(candidate.getSharedPreferences("still-owned", 0).edit().putBoolean("open", true).commit())
            } finally { candidate.close(); HostServices.close() }
        }
        case("preference_close_failure_is_reported_after_global_services_are_cleared") {
            val path = root.resolve("close-failure")
            val app = Application(path, "app.mangashelf.bootstrap")
            HostServices.configure(app, "test", 8, "MangaShelf-Test/8")
            val preferences = app.getSharedPreferences("source", 0)
            check(preferences.edit().putInt("value", 1).commit())
            val file = Files.list(path.resolve("preferences")).use { it.filter { p -> p.fileName.toString().endsWith(".prefs") }.findFirst().orElseThrow() }
            Files.delete(file); Files.createDirectory(file); Files.writeString(file.resolve("owned-fixture"), "fixture")
            preferences.edit().putInt("value", 2).apply()
            val error = fails<IOException> { HostServices.close() }
            check(error.message == "preference_write_failed")
            uninstalled(); HostServices.close()
        }
        println(buildJsonObject {
            put("passed", true)
            put("checks", buildJsonObject { checks.forEach { (name, result) -> put(name, result) } })
            put("scope", "Source-built pinned Injekt and authored application services on host JVM; no published extension, Android UI, native transport or iOS execution")
        })
    }
}
