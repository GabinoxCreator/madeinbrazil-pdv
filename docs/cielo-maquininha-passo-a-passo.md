# App do PDV na maquininha Cielo Smart — passo a passo

Fonte: documentação oficial em docs.cielo.com.br/cielo-smart (consultada em 14/09/2026).
Onde a documentação não responde, está marcado **[A CONFIRMAR]**.

## Antes de começar

1. **Credenciais preenchidas** em `app-android/credenciais.properties`:
   `cielo.client_id`, `cielo.access_token` (Portal de Desenvolvedores → Perfil → Client-IDs Cadastrados).
2. **Arquivo do app gerado já com as credenciais:**
   `app-android/app/build/outputs/apk/release/app-release.apk` (versão 0.3.0, assinado).
3. **Maquininha no Wi-Fi do bar** (rede das térmicas) com o app **"Test Your App"** instalado.

## 1. Criar a loja privada (uma vez só)

1. Entrar no Dev Console: https://www.cieloliostore.com.br/sign-in
2. Menu **"Lojas privadas"** → **"+ Criar loja privada"** → nome: `Made in Brazil Bar` → **Concluir**.
3. Associar o estabelecimento (EC) do bar à loja. **[A CONFIRMAR]** tela e dados exigidos (número do EC da loja 9400).

## 2. Cadastrar o app e subir o arquivo

1. **"+ Aplicativo"** → **"Subir na Loja Privada"**.
2. Enviar o `app-release.apk` (até 200 MB). Nome do pacote: `br.com.madeinbrazilbar.pdv`.
3. Ícone: `marca/icone-cielo-140.png` (140×140, fundo azul, sem transparência).
4. Ao enviar, a Cielo faz a etapa **Assinatura**. Depois o app fica **"Em desenvolvimento"**.

## 3. Instalar na maquininha para testar

1. Dev Console → **Meus aplicativos** → **Ver detalhes** → **Detalhes** → **Baixar App** → escolher o tipo de terminal (**L400**).
2. Aparece um QR Code.
3. Na maquininha, abrir **"Test Your App"** → ler o QR → o app baixa e instala.
4. **[A CONFIRMAR]** se isso funciona numa maquininha de produção do bar. Se der erro, pedir a máquina de teste (e-mail abaixo).

## 4. Primeiro uso na maquininha

1. Abrir o app → tela **Terminal** → e-mail e senha da conta do terminal (Terminal 10).
2. Conferir no **Diagnóstico** se as 4 térmicas respondem.
3. Abrir caixa → abrir comanda → lançar 1 item barato → conferir se imprimiu no ponto certo.
4. Fechar a conta → **Receber** → **Cobrar na maquininha** → Pix ou débito de valor baixo.
5. Conferir no painel (https://madeinbrazil-pdv.lovable.app → Caixa) se o pagamento apareceu.
6. Guardar o **comprovante dessa transação** (a certificação pede).

## 5. Certificação (para ficar definitivo)

A análise leva até **48 horas úteis**. Se faltar algum item obrigatório, a reprovação é automática. Itens:

- descrição curta e principal, segmento;
- **vídeo no YouTube** (pode ser "não listado") mostrando o uso;
- capturas de tela;
- contato de suporte (empresa, e-mail, site, telefones);
- termos de uso;
- versão do SDK / integração (Deep Link);
- login e senha de teste para a Cielo;
- **comprovante de transação**.

Depois de aprovado: **Piloto** (só os terminais escolhidos) → **Produção**. Uma versão nova usa o mesmo nome de pacote, número de versão maior e a **mesma chave de assinatura**. Nas lojas privadas, a maquininha atualiza sozinha quando está com mais de 50% de bateria e internet.

## E-mail para a Cielo (integracaosmart@cielo.com.br)

> Assunto: Made in Brazil Bar — app privado de comandas na Cielo Smart
>
> Olá, somos o MADE IN BRAZIL BAR LTDA (CNPJ 53.035.204/0001-24), com conta no Dev Console. Estamos desenvolvendo um app próprio de comandas para uso só nas nossas maquininhas (loja privada), com pagamento pela integração via Deep Link (lio://payment). Temos três dúvidas:
>
> 1. O app "Test Your App" instala um aplicativo em desenvolvimento numa maquininha de **produção** do nosso próprio estabelecimento? Se não, podem nos enviar uma Cielo Smart de desenvolvimento?
> 2. Para associar nosso EC à loja privada, quais dados são necessários?
> 3. Na certificação, o "comprovante de transação" pode ser de um pagamento real de valor baixo feito no nosso próprio terminal?
>
> Obrigado!
