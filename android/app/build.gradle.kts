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

// Firebase, for the Agents tab's pushes (Push.kt): what the project's
// google-services.json says, written as the strings Firebase reads when the
// app starts — what Google's own plugin writes, without the plugin, so a
// build without the file still builds, only with no pushes. Kept beside the
// release key, out of git: the repository is public.
val firebaseConfig = System.getenv("CALDO_FIREBASE_CONFIG")?.let(::File)
    ?: File(System.getProperty("user.home"), "keys/caldo-google-services.json")

/** google-services.json's strings for this app, by the names Firebase reads. */
fun firebaseStrings(file: File): Map<String, String> {
    @Suppress("UNCHECKED_CAST")
    val json = groovy.json.JsonSlurper().parse(file) as Map<String, Any?>
    val project = json["project_info"] as Map<String, Any?>
    val client = (json["client"] as List<Map<String, Any?>>).first {
        val info = it["client_info"] as Map<String, Any?>
        (info["android_client_info"] as Map<String, Any?>)["package_name"] == "com.igor.caldo"
    }
    val info = client["client_info"] as Map<String, Any?>
    val key = (client["api_key"] as List<Map<String, Any?>>).first()
    return mapOf(
        "google_app_id" to info["mobilesdk_app_id"] as String,
        "google_api_key" to key["current_key"] as String,
        "gcm_defaultSenderId" to project["project_number"] as String,
        "project_id" to project["project_id"] as String,
    )
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
        if (firebaseConfig.exists()) {
            firebaseStrings(firebaseConfig).forEach { (name, value) -> resValue("string", name, value) }
        }
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
    if (release && !firebaseConfig.exists()) {
        logger.warn("$firebaseConfig is missing: this build gets no pushes (Push.kt).")
    }
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
    // The daily sync round while the app is closed (DailySync).
    implementation("androidx.work:work-runtime-ktx:2.10.5")
    // The Agents tab's pushes (Push).
    implementation("com.google.firebase:firebase-messaging:26.0.2")
}
