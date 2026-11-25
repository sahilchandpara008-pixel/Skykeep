package com.skykeep.app

import android.app.Activity
import android.os.Build
import com.facebook.FacebookSdk
import com.facebook.appevents.AppEventsLogger
import com.google.android.gms.ads.identifier.AdvertisingIdClient
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Meta SDK + advertising ID, started only after the user allowed ad measurement (the Dart side calls
 * "enable"). The manifest turns off the SDK's auto start, auto events and advertiser-id collection,
 * so nothing reaches Meta from this phone before that choice. The app id and client token are public
 * build values (--dart-define META_APP_ID / META_CLIENT_TOKEN).
 */
object MetaIds {
    private val io = Executors.newSingleThreadExecutor()

    fun handle(activity: Activity, method: String, appId: String?, clientToken: String?, result: MethodChannel.Result) {
        when (method) {
            "context" -> result.success(mapOf(
                "os" to Build.VERSION.RELEASE, "model" to Build.MODEL, "cores" to Runtime.getRuntime().availableProcessors()))
            "disable" -> {
                try { if (FacebookSdk.isInitialized()) FacebookSdk.setAdvertiserIDCollectionEnabled(false) } catch (_: Throwable) {}
                result.success(null)
            }
            "enable" -> {
                if (appId.isNullOrBlank() || clientToken.isNullOrBlank()) return result.error("no_config", "Meta app id missing", null)
                val app = activity.application
                io.execute {
                    // Advertising ID: only when the user has not turned off ad personalisation on the phone.
                    val adId = try {
                        val info = AdvertisingIdClient.getAdvertisingIdInfo(app)
                        if (info.isLimitAdTrackingEnabled) null else info.id
                    } catch (_: Throwable) { null }
                    activity.runOnUiThread {
                        try {
                            FacebookSdk.setApplicationId(appId)
                            FacebookSdk.setClientToken(clientToken)
                            FacebookSdk.setAutoLogAppEventsEnabled(false) // events go to Meta from SkyKeep's server
                            FacebookSdk.setAdvertiserIDCollectionEnabled(adId != null)
                            @Suppress("DEPRECATION")
                            FacebookSdk.sdkInitialize(app)
                            FacebookSdk.setAutoInitEnabled(true)
                            FacebookSdk.fullyInitialize()
                            AppEventsLogger.activateApp(app)
                            result.success(mapOf("anon_id" to AppEventsLogger.getAnonymousAppDeviceGUID(app), "ad_id" to adId))
                        } catch (e: Throwable) {
                            result.error("meta", e.message, null)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }
}
