/// Build-time configuration (pass with --dart-define).
class Config {
  static const appName = 'SkyKeep';
  static const shortCode = 'SK';
  static const supportEmail = 'help.skykeep@gmail.com';
  static const websiteUrl = String.fromEnvironment('WEBSITE_URL', defaultValue: 'https://skykeep.vercel.app');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// Google Play build (package com.skykeep.play, Play Integrity for 15 GB free).
  static const playStore = bool.fromEnvironment('PLAY_STORE');

  /// Owner's choice: the Play build also sells plans with UPI (PLAY_SELLS_UPI=true).
  /// Without it the Play build shows no prices, UPI or plans.
  static const sellsPlans = !playStore || bool.fromEnvironment('PLAY_SELLS_UPI');

  /// Set only for the ads APK, e.g. utm_source=meta&utm_medium=paid_social&utm_campaign=apk_download.
  static const apkReferrer = String.fromEnvironment('APK_REFERRER');

  static const androidAppId = String.fromEnvironment('ANDROID_APP_ID',
      defaultValue: playStore ? 'com.skykeep.play' : 'com.skykeep.app');
  static String get authCallback => '$androidAppId://login-callback';

  /// Meta (Facebook) app id + client token for the Meta SDK. Public build values (not secrets), passed by CI with
  /// --dart-define=META_APP_ID=... --dart-define=META_CLIENT_TOKEN=... Empty: the Meta SDK never starts.
  static const metaAppId = String.fromEnvironment('META_APP_ID');
  static const metaClientToken = String.fromEnvironment('META_CLIENT_TOKEN');

  /// SkyKeep's own Firebase project (skykeep-a345c) for push notifications. Public client values, not secrets.
  static const firebaseApiKey = 'AIzaSyBFloSqXBySoPJ4u8CprmUXqbrFmmXQQ_k';
  static const firebaseSenderId = '129670905169';
  static const firebaseProjectId = 'skykeep-a345c';
  static const firebaseStorageBucket = 'skykeep-a345c.firebasestorage.app';

  /// Firebase app id per package (com.skykeep.app for website/ads APKs, com.skykeep.play for the Play build).
  static const firebaseDirectAppId = '1:129670905169:android:867b5c8efcab4d6b2de770';
  static const firebasePlayAppId = String.fromEnvironment('FIREBASE_PLAY_APP_ID', defaultValue: '1:129670905169:android:8f435e6b69837a002de770');
  static const firebaseAppId = playStore ? firebasePlayAppId : firebaseDirectAppId;

  static const jsChannel = '${appName}App';
  static const policyVersion = '2026-11';
}
