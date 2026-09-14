package br.com.madeinbrazilbar.pdv

import android.util.Base64
import br.com.madeinbrazilbar.pdv.dados.MetodoPagamento
import br.com.madeinbrazilbar.pdv.pagamento.CieloSmart
import br.com.madeinbrazilbar.pdv.pagamento.CredenciaisCielo
import br.com.madeinbrazilbar.pdv.pagamento.ResultadoCielo
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Conversa com a maquininha Cielo Smart por Deep Link, sem maquininha:
 * montagem do pedido e leitura (tolerante) da resposta.
 * Robolectric por causa do android.util.Base64.
 */
@RunWith(RobolectricTestRunner::class)
class CieloSmartTest {

    private val credenciais = CredenciaisCielo("cliente-123", "token-abc", "0000000000000001")
    private val referencia = "0f8fad5b-d9cb-469f-a165-70867728950e"

    private fun base64(texto: String) = Base64.encodeToString(texto.toByteArray(), Base64.NO_WRAP)

    private val sucesso = """
        {"id":"pedido-cielo-1","reference":"$referencia","status":"PAID","paidAmount":6248,
         "pendingAmount":0,"campoQueACieloInventouOntem":{"x":[1,2,3]},"createdAt":"2026-09-14T20:00:00Z",
         "items":[{"name":"Comanda 15","quantity":1,"sku":"15","unitPrice":6248}],
         "payments":[{"id":"pagamento-cielo-9","externalId":"ext-9","amount":6248,"authCode":"123456",
           "cieloCode":"987654","brand":"VISA","mask":"424242-4242","installments":0,"terminal":"12345678",
           "merchantCode":"0000000000000001","novoCampo":true,
           "paymentFields":{"nsu":"555","statusCode":"1","primaryProductName":"CREDITO",
             "paymentTransactionId":"abc","v40Code":"4","outroCampoNovo":"?"}}]}
    """.trimIndent()

    // ------------------------------------------------------------ pedido

    @Test
    fun `json do pedido tem value em texto e unitPrice e installments em numero`() {
        val j = CieloSmart.montarPedido(referencia, 15, 6_248, MetodoPagamento.CREDITO, credenciais)

        val value = j["value"] as JsonPrimitive
        assertTrue(value.isString)
        assertEquals("6248", value.content)

        val installments = j["installments"] as JsonPrimitive
        assertFalse(installments.isString)
        assertEquals("0", installments.content)

        val item = (j["items"] as JsonArray).single() as JsonObject
        val unitPrice = item["unitPrice"] as JsonPrimitive
        assertFalse(unitPrice.isString)
        assertEquals("6248", unitPrice.content)
        assertEquals("Comanda 15", (item["name"] as JsonPrimitive).content)
        assertEquals("15", (item["sku"] as JsonPrimitive).content)
        assertFalse((item["quantity"] as JsonPrimitive).isString)

        assertEquals("CREDITO_AVISTA", (j["paymentCode"] as JsonPrimitive).content)
        assertEquals(referencia, (j["reference"] as JsonPrimitive).content)
        assertEquals("cliente-123", (j["clientID"] as JsonPrimitive).content)
        assertEquals("token-abc", (j["accessToken"] as JsonPrimitive).content)
        assertEquals("0000000000000001", (j["merchantCode"] as JsonPrimitive).content)
    }

    @Test
    fun `merchantCode vazio nao vai no pedido`() {
        val j = CieloSmart.montarPedido(referencia, 1, 100, MetodoPagamento.PIX, credenciais.copy(merchantCode = ""))
        assertFalse(j.containsKey("merchantCode"))
    }

    @Test
    fun `paymentCode por forma de pagamento`() {
        assertEquals("CREDITO_AVISTA", CieloSmart.codigoPagamento(MetodoPagamento.CREDITO))
        assertEquals("DEBITO_AVISTA", CieloSmart.codigoPagamento(MetodoPagamento.DEBITO))
        assertEquals("PIX", CieloSmart.codigoPagamento(MetodoPagamento.PIX))
        assertEquals("VOUCHER_ALIMENTACAO", CieloSmart.codigoPagamento(MetodoPagamento.VOUCHER))
        assertNull(CieloSmart.codigoPagamento(MetodoPagamento.DINHEIRO))
    }

    @Test
    fun `uri abre lio payment com o pedido em base64 e o retorno do app`() {
        val uri = CieloSmart.montarUri(referencia, 15, 6_248, MetodoPagamento.DEBITO, credenciais)
        assertTrue(uri.startsWith("lio://payment?request="))
        assertTrue(uri.endsWith("&urlCallback=mibpdv://pagamento"))

        val request = uri.substringAfter("request=").substringBefore("&urlCallback=")
        assertFalse("NO_WRAP: sem quebra de linha", request.contains('\n'))
        val j = Json.parseToJsonElement(String(Base64.decode(request, Base64.DEFAULT))) as JsonObject
        assertEquals("DEBITO_AVISTA", (j["paymentCode"] as JsonPrimitive).content)
        assertEquals("6248", (j["value"] as JsonPrimitive).content)
    }

    @Test
    fun `sem client id ou token as credenciais nao estao preenchidas`() {
        assertFalse(CredenciaisCielo("", "token").preenchidas)
        assertFalse(CredenciaisCielo("cliente", " ").preenchidas)
        assertTrue(CredenciaisCielo("cliente", "token").preenchidas)
    }

    // ----------------------------------------------------------- resposta

    @Test
    fun `sucesso com campos desconhecidos vira Aprovado`() {
        val r = CieloSmart.lerRetorno("mibpdv://pagamento?responsecode=0&response=${base64(sucesso)}")
        r as ResultadoCielo.Aprovado
        assertEquals(referencia, r.referencia)
        assertEquals("pedido-cielo-1", r.idPedido)
        assertEquals("pagamento-cielo-9", r.idPagamento)
        assertEquals("123456", r.autorizacao)
        assertEquals("987654", r.nsu)
        assertEquals("VISA", r.bandeira)
        assertEquals("424242-4242", r.mascara)
        assertEquals(6_248L, r.valorCentavos)
    }

    @Test
    fun `sem cieloCode o nsu vem do paymentFields`() {
        val semCieloCode = sucesso.replace("\"cieloCode\":\"987654\",", "")
        val r = CieloSmart.lerResposta(base64(semCieloCode)) as ResultadoCielo.Aprovado
        assertEquals("555", r.nsu)
    }

    @Test
    fun `erro code 1 vira Recusado cancelado pelo usuario`() {
        val erro = """{"code":1,"reason":"CANCELADO PELO USUÁRIO"}"""
        // responsecode não distingue sucesso de erro: quem decide é o formato
        val r = CieloSmart.lerRetorno("mibpdv://pagamento?response=${base64(erro)}&responsecode=0")
        r as ResultadoCielo.Recusado
        assertEquals(CieloSmart.CODIGO_CANCELADO, r.codigo)
        assertEquals("CANCELADO PELO USUÁRIO", r.motivo)
    }

    @Test
    fun `lixo e json sem formato conhecido viram Invalido`() {
        assertTrue(CieloSmart.lerRetorno("mibpdv://pagamento?responsecode=0") is ResultadoCielo.Invalido)
        assertTrue(CieloSmart.lerResposta("!!!nao e base64!!!") is ResultadoCielo.Invalido)
        assertTrue(CieloSmart.lerResposta(base64("isto nao e json")) is ResultadoCielo.Invalido)
        assertTrue(CieloSmart.lerResposta(base64("""{"status":"PAID"}""")) is ResultadoCielo.Invalido)
        // aprovado sem reference não dá pra casar com a cobrança
        val semReferencia = sucesso.replace("\"reference\":\"$referencia\",", "")
        assertTrue(CieloSmart.lerResposta(base64(semReferencia)) is ResultadoCielo.Invalido)
    }

    // -------------------------------------------- base64 fora do padrão

    /** Base64 do sucesso que tenha "+", "/" e "=" no fim: força o pior caso. */
    private fun base64Dificil(): String {
        // "~?>" em três alinhamentos de byte garante "+" e "/"; os espaços do fim ajustam o "="
        for (n in 0..30) {
            val texto = sucesso.replace("\"status\":\"PAID\"", "\"status\":\"PAID\",\"pad\":\"~?> ~?>  ~?>${" ".repeat(n)}\"")
            val b = base64(texto)
            if (b.contains('+') && b.contains('/') && b.endsWith("=")) return b
        }
        throw AssertionError("não achei base64 com + / e =")
    }

    private fun aprovado(response: String) =
        CieloSmart.lerRetorno("mibpdv://pagamento?response=$response&responsecode=0") is ResultadoCielo.Aprovado

    @Test
    fun `base64 com quebras de linha`() {
        val comQuebras = Base64.encodeToString(sucesso.toByteArray(), Base64.DEFAULT)
        assertTrue(comQuebras.contains('\n'))
        assertTrue(aprovado(comQuebras))
        // "\n" escrito como texto
        assertTrue(aprovado(base64Dificil().chunked(60).joinToString("\\n")))
    }

    @Test
    fun `base64 sem padding`() {
        val b = base64Dificil()
        assertTrue(aprovado(b.trimEnd('=')))
    }

    @Test
    fun `base64 com mais trocado por espaco`() {
        val b = base64Dificil()
        assertTrue(aprovado(b.replace('+', ' ')))
        assertTrue(aprovado(b.replace("+", "%20")))
    }

    @Test
    fun `base64 no alfabeto url-safe`() {
        val b = base64Dificil()
        assertTrue(aprovado(b.replace('+', '-').replace('/', '_').trimEnd('=')))
    }

    @Test
    fun `base64 ainda codificado com porcento`() {
        val b = base64Dificil()
        assertTrue(aprovado(b.replace("+", "%2B").replace("/", "%2F").replace("=", "%3D")))
    }

    @Test
    fun `nao confunde response com responsecode`() {
        assertEquals("abc=", CieloSmart.extrairResponse("mibpdv://pagamento?responsecode=1&response=abc="))
        assertNull(CieloSmart.extrairResponse("mibpdv://pagamento?responsecode=1"))
    }
}
