import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

/**
 * The Spotify Client ID, mirroring the macOS app's `Secrets.xcconfig` pattern: it lives in
 * `android/local.properties` (gitignored) rather than in git, so a fresh checkout has to be
 * told the ID once. An empty value builds fine and fails visibly at login rather than at
 * compile time, so the spike/debug builds still install without it.
 */
val clientId: String = Properties().run {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
    getProperty("spotify.clientId", "")
}

// Warn, don't fail: an empty ID has to keep building (see above). But it must not be *silent* —
// a build without one installs and runs perfectly until the first token refresh an hour later,
// then breaks in a way that looks nothing like its cause.
if (clientId.isEmpty()) {
    logger.warn(
        "\n" +
            "WARNING: spotify.clientId is empty — set it in android/local.properties.\n" +
            "         This build will log in and run for up to an hour on an existing token,\n" +
            "         then fail every Spotify call once that token needs refreshing.\n"
    )
}

/** Must match a Redirect URI registered on the Spotify dashboard. Shared with the macOS app. */
val redirectScheme = "spotifymenubar"
val redirectHost = "callback"

android {
    namespace = "com.nathanlmeyers.spotifycurator"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.nathanlmeyers.spotifycurator"
        minSdk = 33
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"

        buildConfigField("String", "SPOTIFY_CLIENT_ID", "\"$clientId\"")
        buildConfigField("String", "REDIRECT_URI", "\"$redirectScheme://$redirectHost\"")
        manifestPlaceholders["redirectScheme"] = redirectScheme
        manifestPlaceholders["redirectHost"] = redirectHost
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    sourceSets["main"].java.srcDirs("src/main/kotlin")
    sourceSets["test"].java.srcDirs("src/test/kotlin")
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.browser)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
