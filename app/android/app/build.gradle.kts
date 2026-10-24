plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.markitdown_ui"
    // desktop_drop requires compileSdk 36, higher than the Flutter default;
    // backward compatible.
    compileSdk = 36
    // Plugins (file_picker, super_native_extensions, receive_sharing_intent
    // and others) require 27.0.12077973 — higher than the Flutter default;
    // the NDK is backward compatible, so we take the max right away.
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.markitdown_ui"
        // super_native_extensions (a super_clipboard dependency, see Stage 1)
        // requires minSdk 23 — the Flutter default (21) doesn't build.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
