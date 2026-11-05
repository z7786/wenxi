import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}
val signingDirectory = rootProject.file("../.local")
val signingProperties = Properties().apply {
    signingDirectory.resolve("keystore.properties").takeIf { it.isFile }?.inputStream()?.use(::load)
}
val unsignedBuild = providers.gradleProperty("ASTERLINK_UNSIGNED").getOrElse("false").toBooleanStrict()
android {
    namespace = "com.asterlink.app"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }
    defaultConfig {
        applicationId = providers.gradleProperty("ASTERLINK_APPLICATION_ID")
            // A direct local release build is the official package. The
            // community workflow passes its own id explicitly.
            .getOrElse("com.asterlink.app")
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["umengAppKey"] = providers.gradleProperty("UMENG_APPKEY")
            .getOrElse("6aac7c0a7431916083082d36")
        manifestPlaceholders["umengChannel"] = providers.gradleProperty("UMENG_CHANNEL")
            .getOrElse("official")
    }
    signingConfigs {
        if (!unsignedBuild && signingProperties.getProperty("storeFile") != null) {
            create("release") {
                storeFile = signingDirectory.resolve(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            ndk {
                // Flutter prepopulates three ABIs; replace that set rather than
                // adding to it, so unsupported native slices cannot bloat APKs.
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    packaging { jniLibs.useLegacyPackaging = true }
}
flutter { source = "../.." }
dependencies {
    implementation(files("libs/gopeed-1.8.1.aar"))
    implementation(libs.bundles.platform)
    implementation(libs.zxing.embedded)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
}

tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
    val testHome = rootProject.file("../.local/android-unit-test")
    // Keep SDK test runtimes and their download lock in the project cache.
    systemProperty("user.home", testHome.absolutePath)
    systemProperty("maven.repo.local", testHome.resolve("m2").absolutePath)
    systemProperty("robolectric.dependency.repo.url", "https://maven.aliyun.com/repository/public")
    doFirst { check(testHome.mkdirs() || testHome.isDirectory) }
}
