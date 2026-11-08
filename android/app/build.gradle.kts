import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key, from a file that is never checked in. It holds the key the
// app has always been signed with — once Flutter's debug key — so an update
// still installs over what is on the phone: Android refuses one signed by
// any other key unless the app is uninstalled first, and that takes every
// task with it. Kept apart from ~/.android, which tools regenerate.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use(::load)
}

android {
    namespace = "com.igor.caldo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications schedules through java.time, which only
        // exists on newer Android than this app supports. Desugaring is how
        // the plugin reaches back; it is not optional, the build fails without
        // it even if nothing is ever scheduled.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.igor.caldo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = keyProperties.getProperty("storeFile")?.let(::file)
            storePassword = keyProperties.getProperty("storePassword")
            keyAlias = keyProperties.getProperty("keyAlias")
            keyPassword = keyProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            // No fallback to the debug key when key.properties is missing.
            // A fresh machine has a debug key of its own, and a release
            // signed with it is one the updater offers and the phone cannot
            // install. Failing the build is better than that — see below.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Without the file AGP does not fail: it quietly builds the release
// unsigned. Asked for a release with no key, say so and stop.
gradle.taskGraph.whenReady {
    val release = allTasks.any { it.project == project && it.name.endsWith("Release") }
    if (release && keyProperties.isEmpty) {
        throw GradleException(
            "android/key.properties is missing: it names the keystore every " +
                "Caldo release is signed with (see CLAUDE.md, Building).",
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
