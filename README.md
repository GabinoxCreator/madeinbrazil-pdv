# Made in Brazil PDV

Sistema de comandas do salão do Made in Brazil Bar.

**Corpo à parte.** Não compartilha código nem banco com a plataforma do bar
(site, bilheteria, CRM, financeiro). Integração é assunto para depois de o PDV
estar de pé.

Especificação: `_docs/especificacao-modulo-pdv.md` no repositório do bar.

## O que tem aqui

```
app-android/    App Kotlin nativo (Compose) para o terminal Cielo Smart (ex-LIO)
ferramentas/    Diagnóstico das térmicas pelo computador (Python, sem dependências)
marca/          Ícones no formato exigido pela Cielo (140x140, fundo sólido)
prints/         Telas do app rodando
email-cielo.txt Rascunho de e-mail para o suporte da Cielo
```

## O que já funciona

Tudo isto roda em **celular Android comum** — não precisa do terminal.

- **Mapa de comandas** — abertas e fechadas, busca por número, mesa ou cliente,
  colaborador do último lançamento e tempo desde o último pedido.
- **Abrir comanda** — número, mesa, pessoas, cliente. Comanda de **controle**
  (banda, equipe) não cobra serviço.
- **Lançamento** — cardápio por categoria, busca por nome ou código curto,
  carrinho, envio do pedido.
- **Impressão por ponto de produção** — o pedido é dividido automaticamente
  entre Cozinha, Bar de drink e Bar de cerveja; cada um recebe só o que lhe cabe.
- **Fila de impressão** com 3 tentativas, log, motivo do erro e reimpressão manual.
- **Conta** — pessoas, retirar serviço, desconto, total por pessoa.
- **Prévia do cupom na tela** — confere o papel sem gastar bobina.
- **Cancelamento de item** com motivo, registrado.
- **Diagnóstico de impressoras** — varre a rede e imprime cupom de teste.
- **Caixa**: abertura com fundo de troco, sangria, suprimento, recebimento
  (dinheiro com troco, Pix, crédito, débito, voucher), **pagamento parcial e
  múltiplas formas na mesma conta**, e fechamento com apuração da diferença.

Ainda não tem: pagamento pelo terminal Cielo (depende do SDK), sincronização
com servidor, transferência entre comandas.

**Limitação atual:** o banco é local do aparelho. Dois celulares não veem as
mesmas comandas — isso só se resolve com o servidor.

## Decisões que valem para sempre

- **Dinheiro em centavos (`Long`), nunca `Double`.** `0.1 + 0.2` em ponto
  flutuante dá `0.30000000000000004`; num PDV isso vira diferença de caixa.
- **Nada imprime fora da `FilaImpressao`.** Ponto único de saída, com retry e
  log — mesmo princípio do motor de envio de WhatsApp do sistema do bar.
  Veio de um problema real: imprimir de forma síncrona travava a tela ~15s
  quando as térmicas estavam fora do ar.
- **O lançamento grava ANTES de tentar imprimir.** Se a impressora cair, o
  consumo já está na conta e o cupom pode ser reimpresso. O contrário deixaria
  comida saindo sem estar na conta de ninguém.
- **Nome e preço são congelados no lançamento.** Mudar o preço do cardápio não
  reescreve comanda antiga.
- **PC860 por tabela própria**, gerada da tabela oficial do codepage, e não via
  `Charset.forName("IBM860")` — nem todo Android traz esse charset e a falha
  seria silenciosa: acento torto no cupom no meio do almoço.
- **A faixa de rede é descoberta em runtime**, não chumbada no código.
- **Nenhum recebimento sem caixa aberto.** Dinheiro entrando fora de sessão é
  divergência garantida no fechamento — está na tabela de riscos da spec.
- **O troco não entra na conta da gaveta.** Cliente paga conta de 50 com nota de
  100: o pagamento vale 50, o troco é 50, e a gaveta cresce 50. Somar o troco
  criaria sobra falsa todo dia. Tem teste para isso.
- **Comanda de controle não trava o fechamento do caixa.** Banda e equipe ficam
  abertas de propósito; se bloqueassem, o caixa nunca fecharia.

## Restrições da Cielo (verificadas no APK gerado)

- **WebView é proibido.** App com WebView não é certificado. Por isso Kotlin nativo.
- `minSdk 24`, `targetSdk 29` (piso da Cielo para distribuição).
- `targetSdk >= 31` pode dar erro de assinatura — contorno é assinar com esquema v2.

## Compilar e testar

O `gradlew` ainda não está versionado; use o Gradle do Android Studio.

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
gradle -p app-android :app:assembleDebug        # compila
gradle -p app-android :app:testDebugUnitTest    # 43 testes
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

## Testes

43 testes, sem emulador:

| Suíte | O que cobre |
|---|---|
| `ContaTest` | serviço, desconto, divisão por pessoa, centavos vs. ponto flutuante |
| `ImpressaoTest` | bytes do PC860, alinhamento em 48 colunas, quebra de parágrafo |
| `CaixaTest` | apuração da gaveta, troco fora da conta, diferença de fechamento |
| `RegrasCaixaTest` | **as guardas, com banco Room de verdade em memória** (Robolectric) |

`RegrasCaixaTest` roda o banco real na JVM, então as regras críticas —
recebimento sem caixa aberto, sangria maior que a gaveta, pagamento parcial,
comanda de controle no fechamento — são verificadas sem depender de emulador.

## Pendências

- **66 itens do cardápio com ponto de produção provisório** — combos, sucos,
  refrigerantes, energéticos, águas e sorvetes. Estão marcados no app com
  "ponto a confirmar" (em vermelho). Precisa da confirmação da operação.
- **IP da térmica da cozinha** (`192.168.0.71` é chute) e a faixa de rede real.
- **Login do colaborador** — hoje é só um seletor sem senha, marcado como
  provisório na própria tela. Código + PIN é o padrão de salão.
- `cardapio.json` é **massa de teste** (cópia do cardápio real de 02/09/2026),
  não integração. Some quando o banco do PDV existir.
