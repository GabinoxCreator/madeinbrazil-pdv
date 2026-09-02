package br.com.madeinbrazilbar.pdv

import br.com.madeinbrazilbar.pdv.dados.Conta
import br.com.madeinbrazilbar.pdv.dados.Dinheiro
import br.com.madeinbrazilbar.pdv.dados.ItemLancado
import br.com.madeinbrazilbar.pdv.dados.StatusItem
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A matematica do dinheiro e o lugar onde erro vira diferenca de caixa.
 * Estes testes existem para que ela nunca mude sem aviso.
 */
class ContaTest {

    private fun item(nome: String, qtd: Int, centavos: Long, status: String = StatusItem.ATIVO) =
        ItemLancado(
            id = 0, pedidoId = 1, comandaId = 1, itemCardapioId = "x", nome = nome,
            quantidade = qtd, precoUnitCentavos = centavos, pontoId = "cozinha", status = status
        )

    @Test
    fun `soma itens e aplica servico de 10 por cento`() {
        val conta = Conta.calcular(
            listOf(item("Feijoada", 2, 2690), item("CDB", 1, 300)),
            taxaServicoPct = 10.0, descontoCentavos = 0, pessoas = 2
        )
        assertEquals(5680, conta.subtotalCentavos)   // 2 x 26,90 + 3,00
        assertEquals(568, conta.servicoCentavos)     // 10%
        assertEquals(6248, conta.totalCentavos)
        assertEquals(3124, conta.porPessoaCentavos)  // 62,48 / 2
    }

    @Test
    fun `item cancelado nao entra na conta`() {
        val conta = Conta.calcular(
            listOf(item("Fica", 1, 1000), item("Cancelado", 1, 5000, StatusItem.CANCELADO)),
            taxaServicoPct = 0.0, descontoCentavos = 0, pessoas = 1
        )
        assertEquals(1000, conta.subtotalCentavos)
    }

    @Test
    fun `desconto nunca deixa o total negativo`() {
        val conta = Conta.calcular(
            listOf(item("Agua", 1, 500)),
            taxaServicoPct = 0.0, descontoCentavos = 999_999, pessoas = 1
        )
        assertEquals(0, conta.totalCentavos)
        assertEquals(500, conta.descontoCentavos)  // limitado ao valor da conta
    }

    @Test
    fun `divisao por pessoa arredonda para cima para nao faltar centavo`() {
        // 10,00 entre 3 nao pode dar 3,33 cada (somaria 9,99)
        val conta = Conta.calcular(
            listOf(item("Porcao", 1, 1000)),
            taxaServicoPct = 0.0, descontoCentavos = 0, pessoas = 3
        )
        assertEquals(1000, conta.totalCentavos)
        assertEquals(334, conta.porPessoaCentavos)
    }

    @Test
    fun `comanda de controle nao cobra servico`() {
        val conta = Conta.calcular(
            listOf(item("Almoco da equipe", 4, 2690)),
            taxaServicoPct = 0.0, descontoCentavos = 0, pessoas = 4
        )
        assertEquals(10760, conta.subtotalCentavos)
        assertEquals(0, conta.servicoCentavos)
        assertEquals(10760, conta.totalCentavos)
    }

    @Test
    fun `pessoas zero nao quebra a divisao`() {
        val conta = Conta.calcular(
            listOf(item("X", 1, 1000)), taxaServicoPct = 0.0, descontoCentavos = 0, pessoas = 0
        )
        assertEquals(1, conta.pessoas)
        assertEquals(1000, conta.porPessoaCentavos)
    }

    @Test
    fun `dinheiro em centavos nao acumula erro de ponto flutuante`() {
        // o classico: 0,1 + 0,2 em Double da 0,30000000000000004
        val a = Dinheiro.deReais(0.1)
        val b = Dinheiro.deReais(0.2)
        assertEquals(30, a + b)
        assertEquals("0,30", Dinheiro.formatar(a + b))
    }

    @Test
    fun `formata valores no padrao brasileiro`() {
        assertEquals("R$ 26,90", Dinheiro.comSimbolo(2690))
        assertEquals("R$ 0,00", Dinheiro.comSimbolo(0))
        assertEquals("R$ 1234,56", Dinheiro.comSimbolo(123456))
    }
}
