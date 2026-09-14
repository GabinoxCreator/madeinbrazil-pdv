package br.com.madeinbrazilbar.pdv

import br.com.madeinbrazilbar.pdv.dados.Configuracao
import br.com.madeinbrazilbar.pdv.impressao.Cupons
import br.com.madeinbrazilbar.pdv.impressao.EscPos
import br.com.madeinbrazilbar.pdv.impressao.Pc860
import br.com.madeinbrazilbar.pdv.impressao.TrabalhoDelivery
import br.com.madeinbrazilbar.pdv.sincronia.DataIso
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class CuponsDeliveryTest {

    private fun ler(j: JsonObject) = TrabalhoDelivery.ler(j)

    private val horaEsperada =
        SimpleDateFormat("dd/MM/yyyy HH:mm", Locale("pt", "BR")).format(Date(DataIso.paraMillis(ExemplosDelivery.CRIADO_EM)))

    private fun contem(texto: String, vararg trechos: String) = trechos.forEach {
        assertTrue("faltou '$it' no cupom:\n$texto", texto.contains(it))
    }

    private fun ByteArray.contemSequencia(seq: ByteArray): Boolean =
        (0..size - seq.size).any { i -> seq.indices.all { this[i + it] == seq[it] } }

    @Test
    fun `producao traz numero, modo, hora, ponto, itens com complementos e observacoes, sem preco`() {
        val cupom = Cupons.deliveryProducao(ler(ExemplosDelivery.trabalho("t1")), "Cozinha")
        val texto = cupom.textoDaPrevia()
        contem(
            texto, "DELIVERY #42", "ENTREGA", "COZINHA", horaEsperada,
            "2x Feijoada", "   + Acompanhamento: Farofa", "   + Adicional: 2x Torresmo", "   obs: bem quente",
            "1x Porção de limão", "OBS DO PEDIDO", "sem cebola"
        )
        assertFalse("produção não leva valor", texto.contains("79,80"))
        assertFalse(texto.contains(Configuracao.RODAPE_CUPOM))
        // acentuação em PC860, não em UTF-8
        assertTrue(cupom.bytes().contemSequencia(Pc860.codificar("Porção")))
    }

    @Test
    fun `producao de retirada diz RETIRADA`() {
        val texto = Cupons.deliveryProducao(ler(ExemplosDelivery.trabalho("t1", modo = "retirada")), "Cozinha").textoDaPrevia()
        contem(texto, "RETIRADA")
        assertFalse(texto.contains("ENTREGA"))
    }

    @Test
    fun `via de entrega traz o pedido completo, troco em destaque e o mapa em texto e QR`() {
        val cupom = Cupons.deliveryViaEntrega(ler(ExemplosDelivery.trabalho("t2", tipo = "via_entrega", ponto = "caixa")))
        val texto = cupom.textoDaPrevia()
        contem(
            texto, Configuracao.CABECALHO_CUPOM, "DELIVERY #42", "ENTREGA", horaEsperada,
            "Maria Souza", "11 99999-0000",
            "ENDEREÇO", "Rua das Flores, 100 - Centro", "Compl.: apto 12", "Ref.: perto da praça", "3,2 km",
            "2x Feijoada", "79,80", "   + Acompanhamento: Farofa", "1x Porção de limão", "10,00",
            "Subtotal", "89,80", "Taxa de entrega", "7,00", "Desconto", "-5,00", "TOTAL", "91,80",
            "Pagamento", "Dinheiro", "TROCO PARA R$ 100,00", "Motoboy", "Zé da Moto",
            "Mapa:", "[QR CODE]", Configuracao.RODAPE_CUPOM
        )
        assertFalse("dinheiro não pago não pode sair como PAGO", texto.lines().any { it.trim() == "PAGO" })

        // link impresso inteiro, em pedaços que cabem na bobina
        val linhasDoMapa = texto.lines().dropWhile { it != "Mapa:" }.drop(1).takeWhile { !it.startsWith("[QR") }
        assertEquals(ExemplosDelivery.MAPA, linhasDoMapa.joinToString(""))
        texto.lines().forEach { assertTrue("linha longa demais: '$it'", it.length <= EscPos.COLUNAS) }

        // GS ( k com o link guardado dentro
        val bytes = cupom.bytes()
        assertTrue(bytes.contemSequencia(byteArrayOf(0x1D, 0x28, 0x6B)))
        assertTrue(bytes.contemSequencia(ExemplosDelivery.MAPA.toByteArray(Charsets.US_ASCII)))
    }

    @Test
    fun `pix pago aparece como PAGO e sem troco`() {
        val t = ler(ExemplosDelivery.trabalho("t3", tipo = "via_entrega", pagamento = "pix_online", pago = true, trocoPara = null))
        val texto = Cupons.deliveryViaEntrega(t).textoDaPrevia()
        contem(texto, "Pix online")
        assertTrue(texto.lines().any { it.trim() == "PAGO" })
        assertFalse(texto.contains("TROCO"))
    }

    @Test
    fun `retirada sem endereco nao imprime bloco de endereco nem mapa`() {
        val t = ler(ExemplosDelivery.trabalho("t4", tipo = "via_entrega", modo = "retirada", comEndereco = false))
        assertNull(t.pedido.endereco)
        val texto = Cupons.deliveryViaEntrega(t).textoDaPrevia()
        contem(texto, "RETIRADA", "TOTAL")
        assertFalse(texto.contains("ENDEREÇO"))
        assertFalse(texto.contains("[QR CODE]"))
    }

    @Test
    fun `cancelamento avisa em letra grande com o motivo`() {
        val t = ler(ExemplosDelivery.trabalho("t5", tipo = "cancelamento", motivo = "cliente desistiu"))
        val cupom = Cupons.deliveryCancelamento(t, "Cozinha")
        contem(cupom.textoDaPrevia(), "PEDIDO #42", "CANCELADO", "COZINHA", "MOTIVO", "cliente desistiu", "2x Feijoada")
        // letra dobrada ligada logo antes do aviso
        assertTrue(cupom.bytes().contemSequencia(byteArrayOf(0x1D, 0x21, 0x11)))
    }

    @Test
    fun `numero que chega como texto tambem e lido`() {
        val j = ExemplosDelivery.trabalho("t6")
        val pedido = JsonObject(j["pedido"] as JsonObject + ("numero" to JsonPrimitive("0042")))
        val t = ler(JsonObject(j + ("pedido" to pedido)))
        assertEquals("0042", t.pedido.numero)
    }
}
