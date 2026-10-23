package eu.kanade.tachiyomi.source.model

/** Public immutable-list facade; individual filter states remain mutable. */
@Suppress("JavaDefaultMethodsNotOverriddenByDelegation")
data class FilterList(val list: List<Filter<*>>) : List<Filter<*>> by list {
    constructor(vararg fs: Filter<*>) : this(fs.asList())
}
