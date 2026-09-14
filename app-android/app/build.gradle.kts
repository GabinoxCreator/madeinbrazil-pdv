import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

// Endereço e chave pública do servidor: arquivo FORA do git (app-android/credenciais.properties).
// Sem o arquivo o app compila e roda normalmente, só que sem falar com o servidor.
// O e-mail e a senha do terminal NÃO entram mais no APK: qualquer um com o
// arquivo instalado leria a senha. Agora são digitados no próprio aparelho
// (tela "Terminal") e ficam guardados só nele.
val credenciais = Properties().apply {
    val arquivo = rootProject.file("credenciais.properties")
    if (arquivo.exists()) arquivo.inputStream().use { load(it) }
}
fun credencial(chave: String): String = "\"" + (credenciais.getProperty(chave) ?: "") + "\""

android {
    namespace = "br.com.madeinbrazilbar.pdv"
    compileSdk = 35

    defaultConfig {
        applicationId = "br.com.madeinbrazilbar.pdv"
        minSdk = 24          // exigencia da Cielo
        targetSdk = 29       // piso exigido pela Cielo para distribuicao na Cielo Store
        versionCode = 2
        versionName = "0.2.0"

        buildConfigField("String", "SERVIDOR_URL", credencial("servidor.url"))
        buildConfigField("String", "SERVIDOR_CHAVE_PUBLICA", credencial("servidor.chave_publica"))

        // Maquininha Cielo Smart (pagamento por Deep Link). O Gabriel precisa
        // preencher em credenciais.properties as chaves cielo.client_id,
        // cielo.access_token e cielo.merchant_code (este último é opcional).
        // Sem client_id ou access_token o app não oferece "Cobrar na maquininha"
        // e o recebimento funciona como antes (registro manual).
        buildConfigField("String", "CIELO_CLIENT_ID", credencial("cielo.client_id"))
        buildConfigField("String", "CIELO_ACCESS_TOKEN", credencial("cielo.access_token"))
        buildConfigField("String", "CIELO_MERCHANT_CODE", credencial("cielo.merchant_code"))
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
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }

    // permite testar o Room de verdade (banco em memoria) na JVM, sem emulador
    testOptions { unitTests { isIncludeAndroidResources = true } }
}

// Guarda o esquema do banco local de cada versão (app/schemas): é a base pra
// escrever as migrações à mão e conferir que nada some numa atualização.
ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    implementation(libs.okhttp)
    ksp(libs.androidx.room.compiler)

    testImplementation("junit:junit:4.13.2")
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.kotlinx.coroutines.test)
}
