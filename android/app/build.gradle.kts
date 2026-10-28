plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

require(!providers.gradleProperty("dev.steenbakker.mobile_scanner.useUnbundled").orNull.equals("true", ignoreCase = true)) {
    "Bridge Mobile requires the bundled QR scanner so it works without Google Play Services"
}

android {
    namespace = "dev.waken.bridge_mobile"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.waken.bridge_mobile"
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += providers.gradleProperty("target-platform")
                .orElse("android-arm,android-arm64,android-x64").get().split(",").map {
                    when (it) {
                        "android-arm" -> "armeabi-v7a"
                        "android-arm64" -> "arm64-v8a"
                        "android-x64" -> "x86_64"
                        else -> error("Unsupported Android target: $it")
                    }
                }
        }
    }

    val signingValues = listOf("BRIDGE_KEYSTORE_PATH", "BRIDGE_KEYSTORE_PASSWORD", "BRIDGE_KEY_ALIAS", "BRIDGE_KEY_PASSWORD")
        .map { System.getenv(it) }
    require(signingValues.all { it.isNullOrEmpty() } || signingValues.all { !it.isNullOrEmpty() }) {
        "Provide all four BRIDGE_KEYSTORE_* / BRIDGE_KEY_* variables, or leave all unset for an unsigned build"
    }
    if (signingValues.all { !it.isNullOrEmpty() }) {
        signingConfigs.create("distribution") {
            storeFile = file(signingValues[0]!!)
            storePassword = signingValues[1]
            keyAlias = signingValues[2]
            keyPassword = signingValues[3]
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("distribution")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

// Must match rustls-platform-verifier-android in rust/Cargo.lock, not the Rust wrapper version.
val rustlsAndroidVersion = "0.2.0"
val lockText = file("../../rust/Cargo.lock").readText()
require(Regex("name = \"rustls-platform-verifier-android\"\\s+version = \"${Regex.escape(rustlsAndroidVersion)}\"").containsMatchIn(lockText)) {
    "Update the Android TLS component to match Cargo.lock"
}
dependencies {
    implementation("org.rustls:rustls-platform-verifier:$rustlsAndroidVersion")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
