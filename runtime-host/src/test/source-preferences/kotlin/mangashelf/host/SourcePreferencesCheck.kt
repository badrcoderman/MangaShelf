package mangashelf.host

import android.app.Application
import android.content.Context
import android.text.Editable
import android.text.TextWatcher
import android.widget.Button
import android.widget.EditText
import androidx.preference.CheckBoxPreference
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.MultiSelectListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceScreen
import androidx.preference.SwitchPreferenceCompat
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Authored settings sources exercise the public API patterns; no published extension executes here. */
object SourcePreferencesCheck {
    private open class Source(override val id: Long) : CatalogueSource {
        override val name = "Authored settings $id"
        override val lang = "en"
        override val supportsLatest = true
        override suspend fun getPopularManga(page: Int) = MangasPage(emptyList(), false)
        override suspend fun getLatestUpdates(page: Int) = getPopularManga(page)
        override suspend fun getSearchManga(page: Int, query: String, filters: FilterList) = getPopularManga(page)
        override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) = SMangaUpdate(manga, chapters)
        override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
    }
    private class Settings(id: Long, private val buildScreen: (PreferenceScreen) -> Unit) : Source(id), ConfigurableSource {
        override fun setupPreferenceScreen(screen: PreferenceScreen) {
            check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
            buildScreen(screen)
        }
    }
    private class Model(val id: Long) {
        val calls = AtomicInteger()
        val validations = AtomicInteger()
        private fun persist(key: String, value: Any): Boolean {
            check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
            calls.incrementAndGet()
            val edit = HostServices.current.context.getSharedPreferences("source_$id", 0).edit()
            when (value) {
                is String -> edit.putString(key, value)
                is Boolean -> edit.putBoolean(key, value)
                is Set<*> -> edit.putStringSet(key, value.map { it as String }.toSet())
                else -> error("Unexpected authored value")
            }
            return edit.commit()
        }
        fun screen(screen: PreferenceScreen) {
            val context = screen.context
            screen.addPreference(ListPreference(context).apply {
                key = "cover"; title = "Cover quality"; summary = "%s"
                entries = arrayOf("Original", "Small"); entryValues = arrayOf("original", "small")
                setDefaultValue("original")
                setOnPreferenceChangeListener { _, value -> persist("cover", value) }
            })
            repeat(7) { index -> screen.addPreference(SwitchPreferenceCompat(context).apply {
                key = "toggle-$index"; title = "Option $index"; setDefaultValue(index == 0)
                summaryOn = "Enabled"; summaryOff = "Disabled"
                setOnPreferenceChangeListener { _, value -> persist("toggle-$index", value) }
            }) }
            repeat(2) { index -> screen.addPreference(MultiSelectListPreference(context).apply {
                key = "set-$index"; title = "Selection $index"; dialogTitle = "Choose values"; dialogMessage = "اختيار 📚"
                entries = arrayOf("English", "Arabic"); entryValues = arrayOf("en", "ar")
                setDefaultValue(setOf("en"))
                setOnPreferenceChangeListener { _, value -> persist("set-$index", value) }
            }) }
            repeat(2) { index -> screen.addPreference(EditTextPreference(context).apply {
                key = "ids-$index"; title = "Blocked UUIDs $index"; setDefaultValue("")
                setOnBindEditTextListener { editor ->
                    check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
                    editor.addTextChangedListener(object : TextWatcher {
                        override fun beforeTextChanged(text: CharSequence, start: Int, count: Int, after: Int) { }
                        override fun onTextChanged(text: CharSequence, start: Int, before: Int, count: Int) { }
                        override fun afterTextChanged(text: Editable) {
                            validations.incrementAndGet()
                            val valid = text.toString().split(',').map(String::trim).filter(String::isNotEmpty).all {
                                try { UUID.fromString(it).toString() == it.lowercase() } catch (_: IllegalArgumentException) { false }
                            }
                            editor.error = if (valid) null else "Invalid UUID — معرّف غير صالح"
                            editor.rootView.findViewById<Button>(android.R.id.button1)?.isEnabled = editor.error == null
                        }
                    })
                }
                setOnPreferenceChangeListener { _, value -> persist("ids-$index", value) }
            }) }
        }
    }
    private suspend fun register(registry: SourceRegistry, source: Source, resource: AutoCloseable? = null) {
        registry.register("fixture.settings${source.id.toString().replace('-', 'n')}", source,
            listOf(SourceRegistry.ExpectedSource(source.id, "en")), resource)
    }
    private suspend fun failure(code: String, body: suspend () -> Unit) {
        try { body() } catch (error: SourcePreferenceSession.Failure) {
            check(error.code == code && error.cause == null && error.suppressed.isEmpty()) { "Expected $code, got ${error.code}" }
            return
        }
        error("Expected $code")
    }
    private inline fun <reified T : Throwable> fails(body: () -> Unit) {
        try { body() } catch (error: Throwable) { if (error is T) return else throw error }
        error("Expected ${T::class.java.name}")
    }
    private fun CountDownLatch.gate() { check(await(5, TimeUnit.SECONDS)) { "Authored gate timed out" } }

    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val root = Path.of(args.single())
        val checks = linkedMapOf<String, Boolean>()
        var current: SourceRegistry? = null
        suspend fun case(name: String, body: suspend (SourceRegistry) -> Unit) {
            System.err.println("START $name")
            val registry = SourceRegistry(); current = registry
            HostServices.configure(Application(root.resolve(name), "app.mangashelf.settings"), "settings-test", 8, "MangaShelf-Test/8")
            try { withTimeout(20000) { body(registry) } }
            catch (error: Throwable) { System.err.println("FAIL $name: ${error.javaClass.name}: ${error.message}"); throw error }
            finally { registry.close().forEach { it.await() }; HostServices.close(); current = null }
            checks[name] = true
            System.err.println("PASS $name")
        }
        try {
            case("twelve_row_source_configuration_defaults_and_native_value_snapshot") { registry ->
                val model = Model(-41); register(registry, Settings(-41, model::screen))
                val session = SourcePreferenceSession.open(registry, -41)
                try {
                    val view = session.snapshot()
                    check(view.sourceId == -41L && view.rows.size == 12 && view.rows.map { it.id } == (1..12).toList())
                    check(view.rows.groupingBy { it.kind }.eachCount() == mapOf(SourcePreferenceSession.Kind.LIST to 1,
                        SourcePreferenceSession.Kind.SWITCH to 7, SourcePreferenceSession.Kind.MULTISELECT to 2, SourcePreferenceSession.Kind.TEXT to 2))
                    check(view.rows[0].summary == "Original" && view.rows[0].value == SourcePreferenceSession.Value.Text("original"))
                    check(view.rows[1].summary == "Enabled" && view.rows[2].summary == "Disabled")
                    check(view.rows[8].dialogTitle == "Choose values" && view.rows[8].dialogMessage == "اختيار 📚")
                    check(view.rows[8].value == SourcePreferenceSession.Value.Multiple(setOf("en")) && model.calls.get() == 0)
                    fails<UnsupportedOperationException> { (view.rows as MutableList).clear() }
                    fails<UnsupportedOperationException> { (view.rows[0].choices as MutableList).clear() }
                    val selected = (view.rows[8].value as SourcePreferenceSession.Value.Multiple).values
                    fails<UnsupportedOperationException> { (selected as MutableSet).clear() }
                    check(HostServices.current.context.getSharedPreferences("source_-41", 0).getString("cover", null) == "original")
                } finally { session.closeAndJoin() }
                check(session.isClosed)
            }
            case("list_switch_and_multiselect_changes_persist_and_reject_unlisted_values") { registry ->
                val model = Model(1); register(registry, Settings(1, model::screen))
                val session = SourcePreferenceSession.open(registry, 1)
                try {
                    check(session.change(1, SourcePreferenceSession.Value.Text("small")).screen.rows[0].summary == "Small")
                    check(session.change(2, SourcePreferenceSession.Value.Toggle(false)).accepted)
                    check(session.change(9, SourcePreferenceSession.Value.Multiple(setOf("ar", "en"))).accepted)
                    check(model.calls.get() == 3)
                    check(!session.change(1, SourcePreferenceSession.Value.Text("unlisted")).accepted)
                    check(!session.change(9, SourcePreferenceSession.Value.Multiple(setOf("unknown"))).accepted)
                    val stored = HostServices.current.context.getSharedPreferences("source_1", 0)
                    check(stored.getString("cover", null) == "small" && !stored.getBoolean("toggle-0", true))
                    check(stored.getStringSet("set-0", emptySet()) == setOf("en", "ar") && model.calls.get() == 3)
                } finally { session.closeAndJoin() }
            }
            case("uuid_text_validation_blocks_save_without_mutating_preferences_or_calling_change_listener") { registry ->
                val model = Model(2); register(registry, Settings(2, model::screen))
                val session = SourcePreferenceSession.open(registry, 2)
                try {
                    val invalid = session.validateText(11, "bad-uuid")
                    check(!invalid.allowed && invalid.error == "Invalid UUID — معرّف غير صالح")
                    check(invalid.screen.rows[10].value == SourcePreferenceSession.Value.Text(""))
                    check(!session.change(11, SourcePreferenceSession.Value.Text("bad-uuid")).accepted && model.calls.get() == 0)
                    val ids = "35d3f9dd-344b-40a6-b690-92c5def28f52, 51e9bffc-325b-4196-bcac-42f5f58745cb"
                    check(session.validateText(11, ids).allowed && model.calls.get() == 0)
                    check(session.change(11, SourcePreferenceSession.Value.Text(ids)).accepted)
                    check(model.calls.get() == 1 && model.validations.get() == 4)
                    check(HostServices.current.context.getSharedPreferences("source_2", 0).getString("ids-0", null) == ids)
                } finally { session.closeAndJoin() }
            }
            case("source_namespaces_are_isolated_and_changes_survive_application_restart") { registry ->
                val one = Model(3); val two = Model(4)
                register(registry, Settings(3, one::screen)); register(registry, Settings(4, two::screen))
                val first = SourcePreferenceSession.open(registry, 3); val second = SourcePreferenceSession.open(registry, 4)
                try {
                    check(first.change(1, SourcePreferenceSession.Value.Text("small")).accepted)
                    check(second.snapshot().rows[0].value == SourcePreferenceSession.Value.Text("original"))
                } finally { first.closeAndJoin(); second.closeAndJoin() }
                registry.close().forEach { it.await() }; HostServices.close()
                HostServices.configure(Application(root.resolve("source_namespaces_are_isolated_and_changes_survive_application_restart"),
                    "app.mangashelf.settings"), "reopen", 9, "MangaShelf-Test/9")
                val reopened = SourceRegistry()
                try {
                    register(reopened, Settings(3, Model(3)::screen))
                    val session = SourcePreferenceSession.open(reopened, 3)
                    try { check(session.snapshot().rows[0].value == SourcePreferenceSession.Value.Text("small")) }
                    finally { session.closeAndJoin() }
                } finally { reopened.close().forEach { it.await() } }
            }
            case("listeners_can_reject_user_changes_and_programmatic_setters_do_not_call_them") { registry ->
                val calls = AtomicInteger()
                register(registry, Settings(5) { screen -> screen.addPreference(CheckBoxPreference(screen.context).apply {
                    key = "accept"; setDefaultValue(null); isChecked = true
                    setOnPreferenceChangeListener { _, _ -> calls.incrementAndGet(); false }
                }) })
                val session = SourcePreferenceSession.open(registry, 5)
                try {
                    check(session.snapshot().rows[0].value == SourcePreferenceSession.Value.Toggle(false) && calls.get() == 0)
                    check(!session.change(1, SourcePreferenceSession.Value.Toggle(true)).accepted && calls.get() == 1)
                    check(!HostServices.current.context.getSharedPreferences("source_5", 0).getBoolean("accept", true))
                } finally { session.closeAndJoin() }
            }
            case("choice_arrays_sets_and_mutable_labels_are_copied_on_assignment") { _ ->
                val context = HostServices.current.context
                val screen = PreferenceScreen(context, context.getSharedPreferences("defensive", 0))
                try {
                    val label = StringBuilder("Arabic"); val labels = arrayOf<CharSequence>(label)
                    val values = arrayOf<CharSequence>("ar"); val defaults = linkedSetOf("ar")
                    val preference = MultiSelectListPreference(context).apply {
                        key = "languages"; entries = labels; entryValues = values; setDefaultValue(defaults)
                    }
                    labels[0] = "changed"; label.append(" changed"); values[0] = "changed"; defaults.clear()
                    check(screen.addPreference(preference))
                    preference.entries[0] = "changed"; preference.values.clear()
                    check(preference.entries.single().toString() == "Arabic" && preference.entryValues.single() == "ar")
                    check(preference.values == setOf("ar"))
                } finally { screen.close() }
            }
            case("hidden_disabled_rows_and_positive_button_validation_reject_changes") { registry ->
                val calls = AtomicInteger()
                register(registry, Settings(6) { screen ->
                    screen.addPreference(SwitchPreferenceCompat(screen.context).apply { key = "hidden"; isVisible = false; setOnPreferenceChangeListener { _, _ -> calls.incrementAndGet(); true } })
                    screen.addPreference(SwitchPreferenceCompat(screen.context).apply { key = "disabled"; isEnabled = false; setOnPreferenceChangeListener { _, _ -> calls.incrementAndGet(); true } })
                    screen.addPreference(EditTextPreference(screen.context).apply {
                        key = "button-gated"; setOnBindEditTextListener { it.rootView.findViewById<Button>(android.R.id.button1).isEnabled = false }
                        setOnPreferenceChangeListener { _, _ -> calls.incrementAndGet(); true }
                    })
                })
                val session = SourcePreferenceSession.open(registry, 6)
                try {
                    check(!session.change(1, SourcePreferenceSession.Value.Toggle(true)).accepted)
                    check(!session.change(2, SourcePreferenceSession.Value.Toggle(true)).accepted)
                    val validation = session.validateText(3, "valid text")
                    check(!validation.allowed && validation.error == null)
                    check(!session.change(3, SourcePreferenceSession.Value.Text("valid text")).accepted && calls.get() == 0)
                } finally { session.closeAndJoin() }
            }
            case("invalid_requests_are_bounded_and_do_not_break_a_valid_session") { registry ->
                register(registry, Settings(7, Model(7)::screen))
                val session = SourcePreferenceSession.open(registry, 7)
                try {
                    failure("preference_not_found") { session.change(0, SourcePreferenceSession.Value.Text("x")) }
                    failure("invalid_preference_value") { session.change(1, SourcePreferenceSession.Value.Toggle(true)) }
                    failure("preference_not_text") { session.validateText(1, "x") }
                    failure("preference_input_limit") { session.change(1, SourcePreferenceSession.Value.Text("x".repeat(1024 * 1024 + 1))) }
                    failure("invalid_preference_unicode") { session.validateText(11, "\uD800") }
                    check(session.snapshot().rows.size == 12 && !session.isClosed)
                } finally { session.closeAndJoin() }
            }
            case("text_watcher_uses_utf16_edit_indices_and_supports_validator_text_correction") { _ ->
                val edit = EditText(HostServices.current.context)
                val events = mutableListOf<String>()
                edit.setText("A📚B")
                val watcher = object : TextWatcher {
                    override fun beforeTextChanged(text: CharSequence, start: Int, count: Int, after: Int) { events.add("before:$text:$start:$count:$after") }
                    override fun onTextChanged(text: CharSequence, start: Int, before: Int, count: Int) { events.add("on:$text:$start:$before:$count") }
                    override fun afterTextChanged(text: Editable) { events.add("after:$text"); if (text.toString() == "AعB") text.append('!') }
                }
                edit.addTextChangedListener(watcher); edit.text.replace(1, 3, "ع")
                check(edit.text.toString() == "AعB!" && events.take(3) == listOf("before:A📚B:1:2:1", "on:AعB:1:2:1", "after:AعB"))
                edit.removeTextChangedListener(watcher); events.clear(); edit.text.clear(); check(events.isEmpty())
                val asTextView: android.widget.TextView = edit
                asTextView.setText("العربية 📚"); check(asTextView.text.toString() == "العربية 📚")
            }
            case("watcher_corrected_text_reaches_the_change_listener_and_durable_value") { registry ->
                val received = mutableListOf<String>()
                register(registry, Settings(16) { screen -> screen.addPreference(EditTextPreference(screen.context).apply {
                    key = "corrected"; setDefaultValue("seed")
                    setOnBindEditTextListener { editor -> editor.addTextChangedListener(object : TextWatcher {
                        override fun beforeTextChanged(text: CharSequence, start: Int, count: Int, after: Int) { }
                        override fun onTextChanged(text: CharSequence, start: Int, before: Int, count: Int) { }
                        override fun afterTextChanged(text: Editable) {
                            val trimmed = text.toString().trim()
                            if (trimmed != text.toString()) text.replace(0, text.length, trimmed)
                        }
                    }) }
                    setOnPreferenceChangeListener { _, value -> received.add(value as String); true }
                }) })
                val session = SourcePreferenceSession.open(registry, 16)
                try {
                    val validated = session.validateText(1, "  العربية 📚  ")
                    check(validated.allowed && validated.text == "العربية 📚" && received.isEmpty())
                    check(validated.screen.rows[0].value == SourcePreferenceSession.Value.Text("seed"))
                    val changed = session.change(1, SourcePreferenceSession.Value.Text("  العربية 📚  "))
                    check(changed.accepted && changed.screen.rows[0].value == SourcePreferenceSession.Value.Text("العربية 📚"))
                    check(received == listOf("العربية 📚"))
                    check(HostServices.current.context.getSharedPreferences("source_16", 0).getString("corrected", null) == "العربية 📚")
                } finally { session.closeAndJoin() }
            }
            case("cancelled_queued_change_is_skipped_and_following_requests_continue") { registry ->
                val entered = CountDownLatch(1); val release = CountDownLatch(1); val calls = AtomicInteger()
                register(registry, Settings(8) { screen -> screen.addPreference(EditTextPreference(screen.context).apply {
                    key = "text"; setDefaultValue("")
                    setOnPreferenceChangeListener { _, _ -> calls.incrementAndGet(); entered.countDown(); release.gate(); true }
                }) })
                val session = SourcePreferenceSession.open(registry, 8)
                try { coroutineScope {
                    val first = async(start = CoroutineStart.UNDISPATCHED) { session.change(1, SourcePreferenceSession.Value.Text("العربية 📚")) }
                    try {
                        entered.gate()
                        val cancelled = async(start = CoroutineStart.UNDISPATCHED) { session.change(1, SourcePreferenceSession.Value.Text("must not run")) }
                        cancelled.cancelAndJoin()
                        val later = async(start = CoroutineStart.UNDISPATCHED) { session.snapshot() }
                        release.countDown(); check(first.await().accepted)
                        check(later.await().rows[0].value == SourcePreferenceSession.Value.Text("العربية 📚") && calls.get() == 1)
                    } finally { release.countDown(); first.cancelAndJoin() }
                } } finally { release.countDown(); session.closeAndJoin() }
            }
            case("package_removal_cancels_settings_and_waits_for_callback_detachment_before_archive_close") { registry ->
                val entered = CountDownLatch(1); val release = CountDownLatch(1)
                val detached = CountDownLatch(1); val finish = CountDownLatch(1); val closed = AtomicBoolean()
                val cleanupDone = AtomicBoolean()
                val source = Settings(9) { screen -> screen.addPreference(object : EditTextPreference(screen.context) {
                    init { key = "text"; setDefaultValue(""); setOnPreferenceChangeListener { _, _ -> entered.countDown(); release.gate(); true } }
                    override fun onDetached() {
                        super.onDetached(); check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
                        check(!closed.get()); detached.countDown(); finish.gate(); check(!closed.get()); cleanupDone.set(true)
                    }
                }) }
                register(registry, source, AutoCloseable { check(cleanupDone.get()); check(closed.compareAndSet(false, true)) })
                register(registry, Source(10))
                val session = SourcePreferenceSession.open(registry, 9)
                try { coroutineScope {
                    val first = async(start = CoroutineStart.UNDISPATCHED) {
                        failure("source_preferences_closed") { session.change(1, SourcePreferenceSession.Value.Text("text")) }
                    }
                    val pending = async(start = CoroutineStart.UNDISPATCHED) { failure("source_preferences_closed") { session.snapshot() } }
                    try {
                        entered.gate(); val removed = registry.remove("fixture.settings9")
                        release.countDown(); detached.gate()
                        check(!removed.isCompleted && !closed.get() && !session.isClosed)
                        check(registry.withSource(10) { it.getPopularManga(1).mangas.isEmpty() })
                        finish.countDown(); first.await(); pending.await(); removed.await(); session.closeAndJoin()
                        check(closed.get() && session.isClosed)
                    } finally { release.countDown(); finish.countDown(); first.cancelAndJoin(); pending.cancelAndJoin() }
                } } finally { release.countDown(); finish.countDown(); session.closeAndJoin() }
                failure("source_preferences_closed") { session.snapshot() }
            }
            case("explicit_session_close_waits_for_detachment_and_keeps_source_installed") { registry ->
                val detached = CountDownLatch(1); val finish = CountDownLatch(1); val closed = AtomicBoolean()
                register(registry, Settings(11) { screen -> screen.addPreference(object : Preference() {
                    override fun onDetached() { detached.countDown(); finish.gate() }
                }) }, AutoCloseable { closed.set(true) })
                val session = SourcePreferenceSession.open(registry, 11)
                try { coroutineScope {
                    val closing = async(Dispatchers.IO) { session.closeAndJoin() }
                    try {
                        detached.gate(); check(!closing.isCompleted && !closed.get())
                        finish.countDown(); closing.await()
                        check(registry.withSource(11) { it.id } == 11L && !closed.get())
                    } finally { finish.countDown(); closing.cancelAndJoin() }
                } } finally { finish.countDown(); session.closeAndJoin() }
            }
            case("callback_failure_is_sanitized_pending_requests_finish_and_package_can_be_reopened") { registry ->
                val entered = CountDownLatch(1); val release = CountDownLatch(1); val detached = AtomicInteger()
                register(registry, Settings(12) { screen -> screen.addPreference(object : SwitchPreferenceCompat(screen.context) {
                    init { key = "throws"; setOnPreferenceChangeListener { _, _ -> entered.countDown(); release.gate(); throw IllegalStateException("private plugin exception") } }
                    override fun onDetached() { detached.incrementAndGet() }
                }) })
                val session = SourcePreferenceSession.open(registry, 12)
                try { coroutineScope {
                    val bad = async(start = CoroutineStart.UNDISPATCHED) { failure("source_preference_callback_failed") { session.change(1, SourcePreferenceSession.Value.Toggle(true)) } }
                    try {
                        entered.gate()
                        val pending = async(start = CoroutineStart.UNDISPATCHED) { failure("source_preference_callback_failed") { session.snapshot() } }
                        release.countDown(); bad.await(); pending.await(); session.closeAndJoin()
                        check(detached.get() == 1 && registry.withSource(12) { it.id } == 12L)
                        val reopened = SourcePreferenceSession.open(registry, 12)
                        try { check(reopened.snapshot().rows.size == 1) } finally { reopened.closeAndJoin() }
                    } finally { release.countDown(); bad.cancelAndJoin() }
                } } finally { release.countDown(); session.closeAndJoin() }
            }
            case("cancelled_open_drains_setup_and_detaches_rows_before_returning") { registry ->
                val entered = CountDownLatch(1); val release = CountDownLatch(1); val detached = AtomicBoolean()
                register(registry, Settings(13) { screen ->
                    screen.addPreference(object : Preference() { override fun onDetached() { detached.set(true) } })
                    entered.countDown(); release.gate()
                })
                coroutineScope {
                    val opening = async(start = CoroutineStart.UNDISPATCHED) { SourcePreferenceSession.open(registry, 13) }
                    try {
                        entered.gate(); opening.cancel(); check(!opening.isCompleted)
                        release.countDown()
                        try { opening.await(); error("Cancelled open returned a session") } catch (_: CancellationException) { }
                        opening.join(); check(detached.get() && registry.withSource(13) { it.id } == 13L)
                    } finally { release.countDown(); opening.cancelAndJoin() }
                }
            }
            case("unsupported_missing_and_malformed_screens_fail_without_releasing_a_live_package") { registry ->
                register(registry, Source(14))
                failure("source_not_configurable") { SourcePreferenceSession.open(registry, 14) }
                failure("source_unavailable") { SourcePreferenceSession.open(registry, 999) }
                val detached = AtomicBoolean()
                register(registry, Settings(15) { screen ->
                    screen.addPreference(object : Preference() { override fun onDetached() { detached.set(true) } })
                    screen.addPreference(ListPreference(screen.context).apply { key = "bad"; entries = arrayOf("one"); entryValues = emptyArray() })
                })
                failure("invalid_preference_choices") { SourcePreferenceSession.open(registry, 15) }
                check(detached.get() && registry.snapshot().size == 2)
            }
            case("screen_duplicate_key_rejection_and_failed_attach_leave_existing_rows_usable") { _ ->
                val context: Context = HostServices.current.context
                val screen = PreferenceScreen(context)
                try {
                    val row = Preference().apply { key = "existing"; title = "Ready" }
                    check(screen.addPreference(row) && !screen.addPreference(row))
                    fails<IllegalArgumentException> { screen.addPreference(Preference().apply { key = "existing" }) }
                    fails<IllegalStateException> { screen.addPreference(object : Preference() { override fun onAttached() { error("attach failed") } }) }
                    check(screen.mslRows().single() === row)
                    fails<IllegalStateException> { row.key = "new" }
                } finally { screen.close() }
                fails<IllegalStateException> { screen.mslRows() }
            }
        } finally { current?.close()?.forEach { it.await() }; HostServices.close() }
        println(buildJsonObject {
            put("passed", true); put("checks", buildJsonObject { checks.forEach { (name, value) -> put(name, value) } })
            put("scope", "Authored ConfigurableSource settings and source lifetime on host JVM; no published extension, Android rendering, Swift UI or iOS execution")
        })
    }
}
