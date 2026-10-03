package dev.musecompanion.muse_companion

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Remembers the notifications currently posted on the phone so Muse can
 * read them with `phone.notifications`. The user turns this on in system
 * settings; until then [recent] is empty.
 */
class MuseNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        instance = this
        refresh()
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        refresh()
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        refresh()
    }

    private fun refresh() {
        val posted = activeNotifications ?: return
        val next = posted.map { posted ->
            val extras = posted.notification.extras
            mapOf(
                "package" to posted.packageName,
                "title" to extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
                "text" to extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty(),
                "when" to posted.postTime,
            )
        }.takeLast(30)
        synchronized(lock) { latest = next }
    }

    companion object {
        private val lock = Any()
        private var latest: List<Map<String, Any?>> = emptyList()

        @Volatile
        var instance: MuseNotificationListener? = null

        fun recent(): List<Map<String, Any?>> = synchronized(lock) { latest.toList() }

        fun enabled(): Boolean = instance != null
    }
}
