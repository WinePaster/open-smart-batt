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
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.winepaster.openSmartBatt"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_blue_plus (BLE) requires API 21+. Never go below 21.
        minSdk = maxOf(flutter.minSdkVersion, 21)
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
