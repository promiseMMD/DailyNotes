import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.reader(Charsets.UTF_8).use { localProperties.load(it) }
}

val releaseKeystore = file("key.jks")
val releaseStorePassword = localProperties.getProperty("storePassword")
val releaseKeyPassword = localProperties.getProperty("keyPassword")
val hasReleaseSigning = releaseKeystore.isFile &&
    !releaseStorePassword.isNullOrBlank() && !releaseKeyPassword.isNullOrBlank()

val previewKeystorePath = providers.environmentVariable("DAILYNOTES_PREVIEW_KEYSTORE").orNull
val previewStorePassword = providers.environmentVariable("DAILYNOTES_PREVIEW_STORE_PASSWORD").orNull
val previewKeyPassword = providers.environmentVariable("DAILYNOTES_PREVIEW_KEY_PASSWORD").orNull
val hasPreviewSigning = previewKeystorePath != null && file(previewKeystorePath).isFile &&
    !previewStorePassword.isNullOrBlank() && !previewKeyPassword.isNullOrBlank()

android {
    namespace = "cn.yooss.moodiary"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    signingConfigs {
        if (hasPreviewSigning) {
            create("dailynotesPreview") {
                storeFile = file(previewKeystorePath!!)
                storePassword = previewStorePassword
                keyPassword = previewKeyPassword
                keyAlias = "dailynotes-preview"
            }
        }
        if (hasReleaseSigning) {
            create("config") {
                storeFile = releaseKeystore
                storePassword = releaseStorePassword
                keyPassword = releaseKeyPassword
                keyAlias = "key0"
                enableV3Signing = true
            }
        }
    }

    val appSigningConfig = signingConfigs.getByName(
        if (hasReleaseSigning) "config" else if (hasPreviewSigning) "dailynotesPreview" else "debug",
    )
    if (!hasReleaseSigning) {
        logger.lifecycle("Local signing is unavailable; using the default Android debug keystore.")
    }

    defaultConfig {
        applicationId = "cn.yooss.moodiary"
        // 28 起才认 DT_ANDROID_RELR；native_toolchain_rust 把 apiTarget 硬编码成 35，26/27 会静默跳过全部重定位
        minSdk = 28
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    flavorDimensions += "channel"
    productFlavors {
        create("dailynotes") {
            dimension = "channel"
            applicationId = "io.github.promisemmd.dailynotes"
        }
        create("production") {
            dimension = "channel"
        }
        create("alpha") {
            dimension = "channel"
            applicationIdSuffix = ".alpha"
        }
        create("beta") {
            dimension = "channel"
            applicationIdSuffix = ".beta"
        }
        create("v3dev") {
            dimension = "channel"
            applicationIdSuffix = ".v3dev"
        }
        create("v3safe") {
            dimension = "channel"
            applicationIdSuffix = ".v3safe"
        }
    }

    buildTypes {
        release {
            signingConfig = appSigningConfig
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            signingConfig = appSigningConfig
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        maybeCreate("profile").apply {
            signingConfig = appSigningConfig
            applicationIdSuffix = ".profile"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.material:material:1.14.0")
}
