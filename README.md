# Made in Brazil PDV

Sistema de comandas do salão do Made in Brazil Bar.

**Corpo à parte.** Não compartilha código nem banco com a plataforma do bar
(site, bilheteria, CRM, financeiro). Integração é assunto para depois de o PDV
estar de pé.

Especificação: `_docs/especificacao-modulo-pdv.md` no repositório do bar.

## O que tem aqui

```
app-android/    App Kotlin nativo para o terminal Cielo Smart (ex-LIO) Positivo L400
ferramentas/    Diagnóstico das térmicas pelo computador (Python, sem dependências)
marca/          Ícones no formato exigido pela Cielo (140x140, fundo sólido)
```

## Estado

**Fatia 1 — diagnóstico de impressão.** O app conecta nas térmicas Elgin i9 da
rede local por ESC/POS na porta 9100, com codepage PC860 (acentuação em
português). Roda em **celular Android comum** — não precisa do terminal.

Ainda não tem: comanda, cardápio, pagamento.

## Restrições da Cielo que valem para sempre

- **WebView é proibido.** App com WebView não é certificado. Kotlin nativo.
- `minSdk 24`, `targetSdk 29` (piso da Cielo para distribuição).
- `targetSdk >= 31` pode dar erro de assinatura — contorno é assinar com esquema v2.

## Compilar

O `gradlew` não está versionado ainda; use o Gradle do Android Studio ou abra a
pasta `app-android/` no próprio Studio.

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
gradle :app:assembleDebug
```

APK: `app-android/app/build/outputs/apk/debug/app-debug.apk`

## Instalar no celular

```sh
~/Library/Android/sdk/platform-tools/adb install -r \
  app-android/app/build/outputs/apk/debug/app-debug.apk
```

## Diagnosticar as térmicas pelo computador

Precisa estar no Wi-Fi do bar.

```sh
python3 ferramentas/impressoras.py procurar
python3 ferramentas/impressoras.py testar todas
```
