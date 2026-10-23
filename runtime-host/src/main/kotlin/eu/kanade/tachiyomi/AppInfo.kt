package eu.kanade.tachiyomi

import mangashelf.host.HostServices

object AppInfo {
    fun getVersionCode(): Int = HostServices.current.versionCode
    fun getVersionName(): String = HostServices.current.versionName
}
