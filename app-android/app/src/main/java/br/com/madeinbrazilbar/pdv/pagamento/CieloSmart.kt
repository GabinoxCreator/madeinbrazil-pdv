package br.com.madeinbrazilbar.pdv.pagamento

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import br.com.madeinbrazilbar.pdv.BuildConfig
import br.com.madeinbrazilbar.pdv.dados.MetodoPagamento
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.net.URLDecoder

/** Credenciais da Cielo, vindas do BuildConfig (credenciais.properties). */
data class CredenciaisCielo(
    val clientId: String,
    val accessToken: String,
    val merchantCode: String = ""
) {
    val preenchidas: Boolean get() = clientId.isNotBlank() && accessToken.isNotBlank()

    companion object {
        fun doApp() = CredenciaisCielo(
            BuildConfig.CIELO_CLIENT_ID, BuildConfig.CIELO_ACCESS_TOKEN, BuildConfig.CIELO_MERCHANT_CODE
        )
    }
}

/** O que a maquininha respondeu, já traduzido. */
sealed class ResultadoCielo {
    /** Pagamento aprovado. `referencia` é o uuid que o app mandou no pedido. */
    data class Aprovado(
        val referencia: String,
        val idPedido: String?,
        val idPagamento: String?,
        val autorizacao: String?,
        /** cieloCode, ou paymentFields.nsu quando o cieloCode não vier. */
        val nsu: String?,
        val bandeira: String?,
        val mascara: String?,
        val valorCentavos: Long?
    ) : ResultadoCielo()

    /** Cancelado ou com erro. Códigos: 1 cancelado pelo usuário, 2 erro genérico, 3 erro no pagamento, 4 erro de autenticação. */
    data class Recusado(val codigo: Int, val motivo: String) : ResultadoCielo()

    /** Retorno que não deu pra entender. Não dá pra afirmar se foi pago ou não. */
    data class Invalido(val textoCru: String) : ResultadoCielo()
}

/**
 * Integração com a Cielo Smart (Positivo L400) por Deep Link, conforme
 * docs.cielo.com.br/cielo-smart. O SDK Order Manager foi descontinuado.
 *
 * Ida: o app abre `lio://payment?request=<BASE64(JSON)>&urlCallback=mibpdv://pagamento`.
 * Volta: a Cielo abre `mibpdv://pagamento?response=<BASE64(JSON)>`.
 *
 * TODO estorno (fora do escopo desta versão):
 *   lio://payment-reversal?request=<BASE64(JSON)>&urlCallback=mibpdv://pagamento
 */
object CieloSmart {

    const val ESQUEMA_RETORNO = "mibpdv"
    const val HOST_RETORNO = "pagamento"
    const val URL_RETORNO = "$ESQUEMA_RETORNO://$HOST_RETORNO"
    const val URI_PAGAMENTO = "lio://payment"

    const val CODIGO_CANCELADO = 1
    const val CODIGO_ERRO_GENERICO = 2

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** Forma de pagamento do PDV -> paymentCode da Cielo. Dinheiro não passa na maquininha. */
    fun codigoPagamento(metodo: String): String? = when (metodo) {
        MetodoPagamento.CREDITO -> "CREDITO_AVISTA"
        MetodoPagamento.DEBITO -> "DEBITO_AVISTA"
        MetodoPagamento.PIX -> "PIX"
        // [A CONFIRMAR] voucher alimentação ou refeição? A Cielo tem os dois
        // (VOUCHER_ALIMENTACAO e VOUCHER_REFEICAO). Num bar/restaurante o mais
        // comum é refeição; ficou alimentação até o Gabriel confirmar.
        MetodoPagamento.VOUCHER -> "VOUCHER_ALIMENTACAO"
        else -> null
    }

    /**
     * JSON do pedido. Atenção aos tipos, é como a Cielo exige:
     * `value` é TEXTO em centavos; `unitPrice` e `installments` são números.
     */
    fun montarPedido(
        referencia: String,
        comandaNumero: Int,
        valorCentavos: Long,
        metodo: String,
        credenciais: CredenciaisCielo
    ): JsonObject {
        val codigo = codigoPagamento(metodo)
            ?: throw IllegalArgumentException("${MetodoPagamento.rotulo(metodo)} não é cobrado na maquininha")
        return buildJsonObject {
            put("accessToken", credenciais.accessToken)
            put("clientID", credenciais.clientId)
            put("reference", referencia)
            if (credenciais.merchantCode.isNotBlank()) put("merchantCode", credenciais.merchantCode)
            put("installments", 0)   // 0 = à vista
            putJsonArray("items") {
                addJsonObject {
                    put("name", "Comanda $comandaNumero")
                    put("quantity", 1)
                    put("sku", comandaNumero.toString())
                    put("unitOfMeasure", "unidade")
                    put("unitPrice", valorCentavos)
                }
            }
            put("paymentCode", codigo)
            put("value", valorCentavos.toString())
        }
    }

    fun paraBase64(texto: String): String =
        Base64.encodeToString(texto.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)

    /** URI que abre a cobrança no app da Cielo. */
    fun montarUri(
        referencia: String,
        comandaNumero: Int,
        valorCentavos: Long,
        metodo: String,
        credenciais: CredenciaisCielo
    ): String {
        val pedido = montarPedido(referencia, comandaNumero, valorCentavos, metodo, credenciais)
        return "$URI_PAGAMENTO?request=${paraBase64(pedido.toString())}&urlCallback=$URL_RETORNO"
    }

    // ------------------------------------------------------------- retorno

    /**
     * Pega o valor CRU de `response` na URI de volta. Não usa
     * Uri.getQueryParameter de propósito: ele troca "+" por espaço e estraga
     * o base64. Também não confunde com o parâmetro `responsecode`.
     */
    fun extrairResponse(uriCrua: String): String? {
        val inicio = uriCrua.indexOf('?')
        if (inicio < 0) return null
        val consulta = uriCrua.substring(inicio + 1).substringBefore('#')
        for (parte in consulta.split('&')) {
            val igual = parte.indexOf('=')
            if (igual < 0) continue
            // só o primeiro "=" separa nome e valor: o base64 pode terminar em "="
            if (parte.substring(0, igual) == "response") return parte.substring(igual + 1)
        }
        return null
    }

    /**
     * Decodifica o base64 da Cielo sem ser exigente: aceita quebra de linha,
     * falta de "=" no fim, "+" que virou espaço, alfabeto URL-safe ("-" e "_")
     * e valor ainda codificado com %XX. Devolve null se não for base64.
     */
    fun decodificarBase64(texto: String): String? {
        var s = texto
        if (s.contains('%')) {
            // "+" protegido: o URLDecoder trocaria por espaço
            s = try { URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") } catch (e: IllegalArgumentException) { s }
        }
        s = s.replace("\\n", "").replace("\\r", "")   // "\n" escrito como texto
            .replace(' ', '+')
            .replace('-', '+')
            .replace('_', '/')
            .filterNot { it == '\n' || it == '\r' || it == '\t' || it == '=' }
        if (s.isEmpty()) return null
        when (s.length % 4) {
            1 -> return null
            2 -> s += "=="
            3 -> s += "="
        }
        return try {
            String(Base64.decode(s, Base64.DEFAULT), Charsets.UTF_8)
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    /** Lê a URI inteira que a Cielo abriu (mibpdv://pagamento?response=...). */
    fun lerRetorno(uriCrua: String): ResultadoCielo {
        val response = extrairResponse(uriCrua) ?: return ResultadoCielo.Invalido(uriCrua)
        return lerResposta(response)
    }

    /**
     * Decide pelo FORMATO do JSON, não pelo parâmetro responsecode (que não
     * distingue sucesso de erro): tem "payments" = aprovado; tem "code" ou
     * "reason" = falha. Campos desconhecidos são ignorados, porque a Cielo
     * adiciona campos sem avisar.
     */
    fun lerResposta(base64: String): ResultadoCielo {
        val texto = decodificarBase64(base64) ?: return ResultadoCielo.Invalido(base64)
        val obj = try {
            json.parseToJsonElement(texto) as? JsonObject
        } catch (e: Exception) {
            null
        } ?: return ResultadoCielo.Invalido(texto)

        val pagamentos = obj["payments"] as? JsonArray
        if (pagamentos != null && pagamentos.isNotEmpty()) {
            val p = pagamentos.first() as? JsonObject ?: return ResultadoCielo.Invalido(texto)
            val referencia = obj.textoCielo("reference")?.takeIf { it.isNotBlank() }
                ?: return ResultadoCielo.Invalido(texto)
            val campos = p["paymentFields"] as? JsonObject
            return ResultadoCielo.Aprovado(
                referencia = referencia,
                idPedido = obj.textoCielo("id"),
                idPagamento = p.textoCielo("id"),
                autorizacao = p.textoCielo("authCode"),
                nsu = p.textoCielo("cieloCode")?.takeIf { it.isNotBlank() } ?: campos?.textoCielo("nsu"),
                bandeira = p.textoCielo("brand"),
                mascara = p.textoCielo("mask"),
                valorCentavos = p.numeroCielo("amount") ?: obj.numeroCielo("paidAmount")
            )
        }
        if (obj.containsKey("code") || obj.containsKey("reason")) {
            return ResultadoCielo.Recusado(
                codigo = obj.numeroCielo("code")?.toInt() ?: CODIGO_ERRO_GENERICO,
                motivo = obj.textoCielo("reason")?.takeIf { it.isNotBlank() } ?: "sem motivo informado"
            )
        }
        return ResultadoCielo.Invalido(texto)
    }

    private fun JsonObject.textoCielo(chave: String): String? = (this[chave] as? JsonPrimitive)?.contentOrNull

    /** Número que pode vir como número ou como texto. */
    private fun JsonObject.numeroCielo(chave: String): Long? =
        textoCielo(chave)?.trim()?.let { it.toLongOrNull() ?: it.toDoubleOrNull()?.toLong() }

    // ------------------------------------------------------------ aparelho

    /**
     * A maquininha só é oferecida quando o app tem as credenciais E existe
     * no aparelho um app que abre lio://payment (ou seja, é uma Cielo Smart).
     * Num celular comum dá false e o recebimento fica como sempre foi.
     */
    fun maquininhaDisponivel(context: Context, credenciais: CredenciaisCielo = CredenciaisCielo.doApp()): Boolean {
        if (!credenciais.preenchidas) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(URI_PAGAMENTO))
            context.packageManager.queryIntentActivities(intent, 0).isNotEmpty()
        } catch (e: Exception) {
            false
        }
    }

    /** Abre o app da Cielo. False se não houver quem abra. */
    fun abrir(context: Context, uri: String): Boolean = try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)))
        true
    } catch (e: ActivityNotFoundException) {
        false
    }
}
