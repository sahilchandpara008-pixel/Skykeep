package com.skykeep.app

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.plugin.common.MethodChannel

/**
 * Google Play install referrer (official library). A Play install from a Meta ad carries
 * utm_source=apps.facebook.com / utm_source=meta; the server decides it is an ads install.
 * Sideloaded APKs never borrow a Play referrer: they answer "non_play".
 */
object InstallReferrer {
    fun read(context: Context, result: MethodChannel.Result) {
        val installer = try {
            if (Build.VERSION.SDK_INT >= 30) context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
            else @Suppress("DEPRECATION") context.packageManager.getInstallerPackageName(context.packageName)
        } catch (_: Exception) { null }
        if (installer != "com.android.vending") {
            result.success(mapOf("status" to "non_play", "referrer" to "")); return
        }
        val handler = Handler(Looper.getMainLooper())
        var finished = false
        var client: InstallReferrerClient? = null
        fun finish(data: Map<String, Any>) {
            handler.post {
                if (!finished) {
                    finished = true
                    try { client?.endConnection() } catch (_: Exception) {}
                    result.success(data)
                }
            }
        }
        handler.postDelayed({ finish(mapOf("status" to "not_available", "referrer" to "")) }, 5000)
        try {
            client = InstallReferrerClient.newBuilder(context).build()
            client?.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(code: Int) {
                    if (code != InstallReferrerClient.InstallReferrerResponse.OK) {
                        finish(mapOf("status" to "not_available", "referrer" to "")); return
                    }
                    try {
                        val detail = client!!.installReferrer
                        finish(mapOf("status" to "play_ok", "referrer" to (detail.installReferrer ?: "").take(2048),
                            "click_ts" to detail.referrerClickTimestampSeconds, "install_ts" to detail.installBeginTimestampSeconds))
                    } catch (_: Exception) { finish(mapOf("status" to "not_available", "referrer" to "")) }
                }
                override fun onInstallReferrerServiceDisconnected() { finish(mapOf("status" to "not_available", "referrer" to "")) }
            })
        } catch (_: Exception) { finish(mapOf("status" to "not_available", "referrer" to "")) }
    }
}
