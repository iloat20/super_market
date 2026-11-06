import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // `supermarket.app`：两段都是合法的 Java 标识符（`super` 不行——它是保留字，
    // 见 defaultConfig 里的注释）。namespace 决定 R 类与 `MainActivity` 的包，
    // 所以 `MainActivity.kt` 在 `kotlin/supermarket/app/`、包声明同为 `supermarket.app`。
    namespace = "supermarket.app"
    // 显式钉 37（Android 17），不再跟 `flutter.compileSdkVersion`：
    // Flutter 3.47.9 的默认值仍是 36，跟着它走就永远差一代；而将来 Flutter
    // 提默认值的时候，也应该是我们自己决定要不要跟，不是被静默拽走。
    // 注意 SDK 平台的包名是 `platforms;android-37.0`（Android 17 起有 minor
    // 版本），目录是 android-37.0，AGP 9 会按 37 + minor 0 解析。
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // 21 是 LTS，也是 AGP 9 推荐的 JDK 基线。JDK 17 在这套 AGP 上还能
        // 编，但 Android 17 的工具链（d8/r8 的新 API）已经开始按 21 校准。
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    defaultConfig {
        // 2026-11-05：从 Flutter 模板的 `com.example.super_market` 一路改成
        // `supermarket.app`，**applicationId 与 namespace 现在一致**。
        //
        // 为什么不是 `super.market`（第一版选的名字）：`super` 是 Java 关键字，
        // namespace 必须是合法 Java 包名，AGP 会直接拒绝
        // （`Namespace 'super.market' is not a valid Java package name as 'super'
        // is a Java keyword.`）。applicationId 不受这条限制，但两边对不上就得
        // 永远解释一遍——所以最后换成两段都合法的 `supermarket.app`。
        //
        // 代价（已确认接受）：每换一次 applicationId = 换一次应用身份，
        // 旧包只能卸载重装；`getApplicationSupportDirectory()` 在旧包目录下、
        // 跨 UID 读不到，旧自选与目录缓存无法迁移，重装后回到默认列表。
        applicationId = "supermarket.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // R-09：release 不再无条件用 debug 密钥。存在 keystore.properties
    // （android/keystore.properties，内容：storeFile/storePassword/keyAlias/
    // keyPassword，已被 .gitignore 排除）时用它签名；否则回退 debug 签名，
    // 保证 `flutter run --release` 仍可用——但自用分发前应生成正式密钥：
    //   keytool -genkey -v -keystore release-key.jks -keyalg RSA \
    //     -keysize 2048 -validity 10000 -alias itick
    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("keystore.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(keystorePropertiesFile.inputStream())
    }

    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.create("release") {
                    storeFile = file(keystoreProperties["storeFile"] as String)
                    storePassword = keystoreProperties["storePassword"] as String
                    keyAlias = keystoreProperties["keyAlias"] as String
                    keyPassword = keystoreProperties["keyPassword"] as String
                }
            } else {
                // 没有正式密钥时才落回 debug——继续保留 `flutter run --release` 能力
                signingConfig = signingConfigs.getByName("debug")
            }

            // R8：压缩代码（删除未引用类/方法/字段）+ 混淆成短名。
            // 保留规则见 app/proguard-rules.pro —— Flutter 的 flutter.jar 不带
            // consumer 规则，不自己写 keep 的话 release 包会 JNI 找不到符号而闪退。
            isMinifyEnabled = true
            // R8 的资源压缩：移除未被引用的 res/ 与 assets/。
            // 必须和 isMinifyEnabled 一起开，单独开会被 AGP 忽略。
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // 产物名：应用叫「超级市场」。flutter tool 把 APK 统一命名为
    // app-<variant>.apk 且不可配置，所以用 finalizedBy 在每次
    // assembleRelease 完成后复制一份 "super market.apk" 到同一目录。
    tasks.matching { it.name == "assembleRelease" }.configureEach {
        finalizedBy("copySuperMarketApk")
    }

    // 只留 64 位的「补刀」。
    //
    // `flutter build --target-platform android-arm64` 只管 Flutter 自己的产物
    // （libflutter.so / libapp.so）。第三方插件自带的**预编译 .so** 不归它管：
    // path_provider_android 经 jni_flutter 引入 libdartjni.so，它对
    // arm64-v8a / armeabi-v7a / x86_64 各带一份，于是「只打了 arm64」的包里
    // `aapt2 dump badging` 的 native-code 仍然写着三个 ABI。
    //
    // 这不只是数字难看：声明了 v7a 就等于告诉系统「32 位也能装」，
    // 真装到 32 位机器上却没有 libflutter.so，属于装得上、起不来的包。
    //
    // 踩过的坑：`buildTypes.release.ndk { abiFilters += "arm64-v8a" }` **无效** ——
    // ABI 过滤器作用于 ndkBuild / jniLibs 源码目录，不作用于从 AAR 带进来的 .so；
    // 实测加了它之后包里照样是三个 ABI。真正生效的是打包期的 excludes。
    //
    // 只点名单个文件、不按整目录剔：模拟器（x86_64）上还要 `flutter run`，
    // 剔掉整个 lib/x86_64/** 会连 libflutter.so 一起没了，App 根本装不上；
    // 而只缺 libdartjni.so 时，档位降级是「读写失败 → 退回默认三只」，
    // 不崩（KeyValueStore 那层全是 try/catch）。
    // 将来若别的插件又带进来其它 ABI 的 .so，`tool/verify_apk.py` 会当场报出来。
    packaging {
        jniLibs {
            // 2026-11-06：把 .so 从 stored 改成 DEFLATE 存储（等价于 Manifest 的
            // extractNativeLibs=true）。AGP 8+ 默认**不压缩**原生库（安装后直接
            // mmap APK 里的页），于是三个 .so 白占 15.59MB 中本该省下的 8.7MB。
            // 自用 sideload 场景下「发出去的文件小一半」比「装后省 7MB」值钱：
            //   - 传输体积 16.59MB → 约 7.8MB（deflate-9 实测三 .so 6.86MB）
            //   - 代价：安装时解压一次，装后占用 +约 7MB；冷启动需复测（基线 403ms，
            //     门槛 450ms，超了就删掉这一行回滚）
            useLegacyPackaging = true
            excludes += setOf(
                "lib/armeabi-v7a/libdartjni.so",
                "lib/x86_64/libdartjni.so",
            )
        }
        // 编译器元数据不是代码，R8 不会碰它：`kotlin/*.kotlin_builtins` 是给
        // 编译器/IDE 读的声明文件，运行期没有任何代码去加载。不点名剔掉的话
        // 它们会原样躺在 APK 根目录（实测 8 个文件 53KB）。
        // `tool/verify_apk.py` 有一条断言守着，剔漏了会当场报出来。
        resources {
            excludes += setOf(
                "kotlin/**",
                "kotlin-tooling-metadata.json",
                "DebugProbesKt.bin",
            )
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

// 复制 release 产物为 "super market.apk"。输出到**独立目录**：
// 不能写 apk/release（与 createReleaseApkListingFileRedirect 的输出重叠，
// Gradle 9 隐式依赖校验会拒绝构建），也不能写 flutter-apk（flutter tool
// 管理的目录，会干扰其产物探测）。
tasks.register<Copy>("copySuperMarketApk") {
    from(rootProject.file("../build/app/outputs/apk/release/app-release.apk"))
    into(rootProject.file("../build/app/outputs/supermarket"))
    rename { "super market.apk" }
}
