plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dotwave.dotwave"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Install identifier. Must match `DOTWAVE_PACKAGE_NAME` in the
        // Rust `zk-pki-integrity` crate AND the hardcoded constant in
        // `ZkPkiCeremony.kt` — the ZK-PKI pallet's mint-cert cross-check
        // compares all three plus the `attestationApplicationId` baked
        // into the cert_ec chain by the Android Keystore daemon. A
        // mismatch between dev and prod application IDs is a bug waiting
        // to bite at the worst moment.
        //
        // The Kotlin `namespace` above stays at `com.dotwave.dotwave` on
        // purpose — that's the code-organization path under
        // `android/app/src/main/kotlin/com/dotwave/dotwave/` and changing
        // it would mean moving every Kotlin file. Android Gradle allows
        // applicationId ≠ namespace; only the applicationId ends up in
        // the installed package identity and the attestation extension.
        applicationId = "com.dotwave.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    packaging {
        resources {
            // BouncyCastle (bcprov-jdk18on) and jspecify both ship
            // META-INF/versions/9/OSGI-INF/MANIFEST.MF — OSGi metadata that
            // Android ignores at runtime. Excluding the conflicting entry
            // lets the merge pass without picking one jar's copy over the
            // other's (both are functionally empty for our purposes).
            excludes += setOf(
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/versions/9/OSGI-INF/*.MF",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Blake2b-256 for the ZK-PKI binding proof commitment. Android's stock
    // MessageDigest providers don't ship Blake2b, and we need byte-identical
    // output against sp_io::hashing::blake2_256 on the pallet side.
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
}