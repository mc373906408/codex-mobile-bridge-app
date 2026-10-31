plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

require(!providers.gradleProperty("dev.steenbakker.mobile_scanner.useUnbundled").orNull.equals("true", ignoreCase = true)) {
    "Bridge Mobile requires the bundled QR scanner so it works without Google Play Services"
}

val pushAppKey = providers.environmentVariable("UMENG_PUSH_APP_KEY").orNull?.trim().orEmpty()
val pushMessageSecret = providers.environmentVariable("UMENG_PUSH_MESSAGE_SECRET").orNull?.trim().orEmpty()
val pushChannel = providers.environmentVariable("UMENG_PUSH_CHANNEL").orNull?.trim()
    ?.takeIf { it.isNotEmpty() } ?: "lenovo_test"
require(pushAppKey.isEmpty() == pushMessageSecret.isEmpty()) {
    "Set both UMENG_PUSH_APP_KEY and UMENG_PUSH_MESSAGE_SECRET, or leave both unset"
}
val productionPush = providers.environmentVariable("BRIDGE_ANDROID_PUSH").orNull?.trim().orEmpty()
require(productionPush in setOf("", "none", "umeng")) { "BRIDGE_ANDROID_PUSH must be none or umeng" }
val productionEnabled = productionPush == "umeng"
val productionAppKey = providers.environmentVariable("UMENG_PRODUCTION_APP_KEY").orNull?.trim().orEmpty()
val productionMessageSecret = providers.environmentVariable("UMENG_PRODUCTION_MESSAGE_SECRET").orNull?.trim().orEmpty()
val productionChannel = providers.environmentVariable("UMENG_PRODUCTION_CHANNEL").orNull?.trim()
    ?.takeIf { it.isNotEmpty() } ?: "bridge_cloud"
require(if (productionEnabled) productionAppKey.isNotEmpty() && productionMessageSecret.isNotEmpty()
    else productionAppKey.isEmpty() && productionMessageSecret.isEmpty()) {
    "Production Umeng requires explicit BRIDGE_ANDROID_PUSH=umeng and both UMENG_PRODUCTION_* credentials"
}
fun buildString(value: String): String = "\"" + value
    .replace("\\", "\\\\").replace("\"", "\\\"")
    .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\""

android {
    namespace = "dev.waken.bridge_mobile"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { buildConfig = true }

    defaultConfig {
        applicationId = "dev.waken.bridge_mobile"
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Remote push is opt-in; the ordinary release/profile remain SDK-free.
        buildConfigField("boolean", "UMENG_PUSH_PRODUCTION", "false")
        buildConfigField("boolean", "UMENG_PUSH_CONFIGURED", "false")
        buildConfigField("String", "UMENG_PUSH_APP_KEY", "\"\"")
        buildConfigField("String", "UMENG_PUSH_MESSAGE_SECRET", "\"\"")
        buildConfigField("String", "UMENG_PUSH_CHANNEL", "\"\"")
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
        debug {
            buildConfigField("boolean", "UMENG_PUSH_CONFIGURED", (pushAppKey.isNotEmpty()).toString())
            buildConfigField("String", "UMENG_PUSH_APP_KEY", buildString(pushAppKey))
            buildConfigField("String", "UMENG_PUSH_MESSAGE_SECRET", buildString(pushMessageSecret))
            buildConfigField("String", "UMENG_PUSH_CHANNEL", buildString(pushChannel))
            manifestPlaceholders["UMENG_PUSH_APP_KEY"] = pushAppKey
            manifestPlaceholders["UMENG_PUSH_MESSAGE_SECRET"] = pushMessageSecret
        }
        getByName("profile") {
            buildConfigField("boolean", "UMENG_PUSH_PRODUCTION", productionEnabled.toString())
            buildConfigField("boolean", "UMENG_PUSH_CONFIGURED", productionEnabled.toString())
            buildConfigField("String", "UMENG_PUSH_APP_KEY", buildString(if (productionEnabled) productionAppKey else ""))
            buildConfigField("String", "UMENG_PUSH_MESSAGE_SECRET", buildString(if (productionEnabled) productionMessageSecret else ""))
            buildConfigField("String", "UMENG_PUSH_CHANNEL", buildString(if (productionEnabled) productionChannel else ""))
            manifestPlaceholders["UMENG_PUSH_APP_KEY"] = if (productionEnabled) productionAppKey else ""
            manifestPlaceholders["UMENG_PUSH_MESSAGE_SECRET"] = if (productionEnabled) productionMessageSecret else ""
        }
        release {
            buildConfigField("boolean", "UMENG_PUSH_PRODUCTION", productionEnabled.toString())
            buildConfigField("boolean", "UMENG_PUSH_CONFIGURED", productionEnabled.toString())
            buildConfigField("String", "UMENG_PUSH_APP_KEY", buildString(if (productionEnabled) productionAppKey else ""))
            buildConfigField("String", "UMENG_PUSH_MESSAGE_SECRET", buildString(if (productionEnabled) productionMessageSecret else ""))
            buildConfigField("String", "UMENG_PUSH_CHANNEL", buildString(if (productionEnabled) productionChannel else ""))
            manifestPlaceholders["UMENG_PUSH_APP_KEY"] = if (productionEnabled) productionAppKey else ""
            manifestPlaceholders["UMENG_PUSH_MESSAGE_SECRET"] = if (productionEnabled) productionMessageSecret else ""
            signingConfig = signingConfigs.findByName("distribution")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    sourceSets {
        getByName("debug") {
            java.srcDir("src/umeng/kotlin")
            res.srcDir("src/umeng/res")
            manifest.srcFile("src/umeng/AndroidManifest.xml")
        }
        if (productionEnabled) {
            for (mode in listOf("profile", "release")) getByName(mode) {
                java.setSrcDirs(listOf("src/umeng/kotlin"))
                res.srcDir("src/umeng/res")
                manifest.srcFile("src/umeng/AndroidManifest.xml")
            }
        }
    }
}

// Resolve the matching Java component from the refreshed Rust dependency snapshot.
val lockText = file("../../rust/Cargo.lock").readText()
val rustlsAndroidVersion = Regex("name = \"rustls-platform-verifier-android\"\\s+version = \"([^\"]+)\"")
    .find(lockText)?.groupValues?.get(1)
    ?: error("The refreshed Cargo.lock is missing rustls-platform-verifier-android")
dependencies {
    implementation(project(":bridge_preview"))
    implementation("org.rustls:rustls-platform-verifier:$rustlsAndroidVersion")
    debugImplementation("com.umeng.umsdk:common:10.0.1")
    debugImplementation("com.umeng.umsdk:asms:1.8.7.2")
    debugImplementation("com.umeng.umsdk:push:6.7.6")
    if (productionEnabled) {
        for (mode in listOf("profileImplementation", "releaseImplementation")) {
            add(mode, "com.umeng.umsdk:common:10.0.1")
            add(mode, "com.umeng.umsdk:asms:1.8.7.2")
            add(mode, "com.umeng.umsdk:push:6.7.6")
        }
    }
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    sourceSets {
        if (productionEnabled) {
            // Kotlin has its own default src/<mode>/kotlin roots; replacing Java roots alone keeps the SDK-free stub.
            for (mode in listOf("profile", "release")) getByName(mode) {
                kotlin.setSrcDirs(listOf("src/umeng/kotlin"))
            }
        }
    }
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
