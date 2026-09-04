package br.com.madeinbrazilbar.pdv

import br.com.madeinbrazilbar.pdv.dados.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Conferencia de caixa. Erro aqui e dinheiro faltando na gaveta no fim do dia.
 */
class CaixaTest {

    private val sessao = SessaoCaixa(
        id = 1, abertaPor = "Beto", abertaEm = 0L, fundoTrocoCentavos = 10_000  // R$ 100,00
    )

    private fun mov(tipo: String, centavos: Long) =
        MovimentoCaixa(0, 1, tipo, centavos, "teste", "Beto", 0L)

    private fun pag(metodo: String, valor: Long, troco: Long = 0, comanda: Long = 1) =
        Pagamento(0, comanda, 1, metodo, valor, troco, "Beto", 0L)

    @Test
    fun `gaveta vazia so tem o fundo de troco`() {
        val f = Fechamento.calcular(sessao, emptyList(), emptyList())
        assertEquals(10_000, f.esperadoEmDinheiroCentavos)
        assertEquals(0, f.totalRecebidoCentavos)
    }

    @Test
    fun `o TROCO nao entra na conta da gaveta`() {
        // conta de 50, cliente deu 100, troco 50: a gaveta cresce 50, nao 100.
        // somar o troco aqui criaria sobra falsa de 50 todo dia.
        val f = Fechamento.calcular(
            sessao, emptyList(),
            listOf(pag(MetodoPagamento.DINHEIRO, valor = 5_000, troco = 5_000))
        )
        assertEquals(15_000, f.esperadoEmDinheiroCentavos)  // 100 de fundo + 50
    }

    @Test
    fun `cartao e pix nao entram no dinheiro da gaveta`() {
        val f = Fechamento.calcular(
            sessao, emptyList(),
            listOf(
                pag(MetodoPagamento.DINHEIRO, 3_000),
                pag(MetodoPagamento.CREDITO, 8_000, comanda = 2),
                pag(MetodoPagamento.PIX, 5_000, comanda = 3)
            )
        )
        assertEquals(13_000, f.esperadoEmDinheiroCentavos)  // 100 + 30 apenas
        assertEquals(16_000, f.totalRecebidoCentavos)       // 30 + 80 + 50
        assertEquals(3, f.comandasRecebidas)
    }

    @Test
    fun `sangria tira e suprimento poe`() {
        val f = Fechamento.calcular(
            sessao,
            listOf(
                mov(TipoMovimento.SANGRIA, 4_000),
                mov(TipoMovimento.SUPRIMENTO, 1_500)
            ),
            listOf(pag(MetodoPagamento.DINHEIRO, 2_000))
        )
        // 100 - 40 + 15 + 20
        assertEquals(9_500, f.esperadoEmDinheiroCentavos)
        assertEquals(4_000, f.sangriasCentavos)
        assertEquals(1_500, f.suprimentosCentavos)
    }

    @Test
    fun `diferenca negativa quando falta dinheiro`() {
        val f = Fechamento.calcular(
            sessao, emptyList(), listOf(pag(MetodoPagamento.DINHEIRO, 5_000)),
            contadoCentavos = 14_000   // deveria ter 150
        )
        assertEquals(15_000, f.esperadoEmDinheiroCentavos)
        assertEquals(-1_000L, f.diferencaCentavos)   // faltam R$ 10
    }

    @Test
    fun `diferenca zero quando bate certinho`() {
        val f = Fechamento.calcular(
            sessao, emptyList(), listOf(pag(MetodoPagamento.DINHEIRO, 5_000)),
            contadoCentavos = 15_000
        )
        assertEquals(0L, f.diferencaCentavos)
    }

    @Test
    fun `diferenca nula enquanto nao contou a gaveta`() {
        val f = Fechamento.calcular(sessao, emptyList(), emptyList(), contadoCentavos = null)
        assertEquals(null, f.diferencaCentavos)
    }

    @Test
    fun `total por forma de pagamento agrupa certo`() {
        val f = Fechamento.calcular(
            sessao, emptyList(),
            listOf(
                pag(MetodoPagamento.CREDITO, 3_000),
                pag(MetodoPagamento.CREDITO, 4_500, comanda = 2),
                pag(MetodoPagamento.DEBITO, 2_000, comanda = 3)
            )
        )
        assertEquals(7_500L, f.porMetodo[MetodoPagamento.CREDITO])
        assertEquals(2_000L, f.porMetodo[MetodoPagamento.DEBITO])
        assertEquals(null, f.porMetodo[MetodoPagamento.PIX])
    }

    // ---------------- saldo da comanda ----------------

    @Test
    fun `comanda sem pagamento deve tudo`() {
        val s = SaldoComanda(totalCentavos = 6_248, pagoCentavos = 0)
        assertEquals(6_248, s.faltaCentavos)
        assertFalse(s.quitada)
    }

    @Test
    fun `pagamento parcial deixa saldo`() {
        val s = SaldoComanda(totalCentavos = 6_248, pagoCentavos = 3_000)
        assertEquals(3_248, s.faltaCentavos)
        assertFalse(s.quitada)
    }

    @Test
    fun `pagamento exato quita a comanda`() {
        val s = SaldoComanda(totalCentavos = 6_248, pagoCentavos = 6_248)
        assertEquals(0, s.faltaCentavos)
        assertTrue(s.quitada)
    }

    @Test
    fun `falta nunca fica negativa`() {
        val s = SaldoComanda(totalCentavos = 1_000, pagoCentavos = 1_500)
        assertEquals(0, s.faltaCentavos)
        assertTrue(s.quitada)
    }

    @Test
    fun `varias formas na mesma conta somam para quitar`() {
        // caso real: metade no cartao, metade em dinheiro
        val pagos = listOf(
            pag(MetodoPagamento.CREDITO, 3_124),
            pag(MetodoPagamento.DINHEIRO, 3_124)
        ).sumOf { it.valorCentavos }
        val s = SaldoComanda(totalCentavos = 6_248, pagoCentavos = pagos)
        assertTrue(s.quitada)
        assertEquals(0, s.faltaCentavos)
    }
}
