import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material, supplied out-of-band and never committed
// (`android/.gitignore` already excludes `key.properties` and `*.keystore`).
//
// WHY THIS EXISTS: the release build used to sign with the DEBUG key. On a CI
// runner there is no `~/.android/debug.keystore`, so Gradle generated a fresh
// one on every run — three release APKs, three different certificates, two of
// them from the same CI. Android refuses to install an update signed by a
// different key, so nobody could ever update in place: every release forced an
// uninstall, which wipes the database (history, saved devices, settings) and
// with it the very data this app exists to collect.
//
// Absent = fall back to debug signing, so `flutter run --release` and
// pull-request CI keep working on a machine with no secrets.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseSigning = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.winepaster.openSmartBatt"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications 10+ (design 0080 P3), even
        // though this app schedules nothing: the plugin's own AAR is built with
        // core-library desugaring on, so the app has to be too or the build
        // fails at dexing with a missing java.time class. The plugin pins
        // desugar_jdk_libs 2.1.4 and AGP 8.11.1; this module is on AGP 9.0.1
        // (android/settings.gradle.kts), which is above that floor.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.winepaster.openSmartBatt"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Two floors, and the higher one now belongs to notifications:
        // flutter_blue_plus (BLE) needs 21, flutter_local_notifications needs
        // **24** (design 0080 P3 — its own AAR declares `minSdkVersion 24`).
        // `flutter.minSdkVersion` is already 24 on Flutter 3.44, so today this
        // expression is a no-op; it is written this way so that a future
        // Flutter that LOWERED its default could not silently take the app
        // below a plugin's floor and fail at manifest merge instead.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The real key when one was supplied; otherwise debug, so a
            // developer machine and pull-request CI still build. A build
            // signed with the debug key is NOT distributable — see the note
            // above `keystorePropertiesFile` and docs/VERSIONING.md.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // See `compileOptions` above — the plugin's own version, so the two AARs
    // agree about which backport they are calling into.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
