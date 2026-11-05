-keep class com.umeng.** { *; }
-keep class org.repackage.** { *; }
-keepclassmembers class * {
    public <init>(org.json.JSONObject);
}
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
-keep public class com.asterlink.app.R$* {
    public static final int *;
}

# JNI names are part of the Go and media_kit native ABIs.
-keep class go.** { *; }
-keep class com.asterlink.nativecore.** { *; }
-keep class com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper { *; }
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
# Preserve JavaScript bridge callbacks invoked by WebView reflection.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
# Keep entry points inspected by verify_apk; their implementation is optimized.
-keep,allowoptimization class com.asterlink.app.NativeBridge { *; }
-keep,allowoptimization class com.asterlink.app.PlaybackBridge { *; }
-keep,allowoptimization class com.asterlink.app.PlaybackActionReceiver { *; }
-keep,allowoptimization class com.asterlink.app.DownloadKeepAlive { *; }
-keep,allowoptimization class com.asterlink.app.DownloadProtection { *; }
-keep,allowoptimization class com.asterlink.app.AppKeepAlive { *; }
-keep,allowoptimization class com.asterlink.app.AppKeepAliveService { *; }
-keep,allowoptimization class com.asterlink.app.NotificationPermission { *; }
-keep,allowoptimization class com.asterlink.app.metrics.** { *; }
