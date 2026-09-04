package br.com.madeinbrazilbar.pdv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import br.com.madeinbrazilbar.pdv.dados.*
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Regras do caixa com banco DE VERDADE (Room em memoria), sem emulador.
 *
 * Cobre as guardas que a especificacao lista como risco: dinheiro entrando
 * fora de sessao, sangria maior que a gaveta, comanda fechada recebendo mais
 * do que deve.
 */
@RunWith(RobolectricTestRunner::class)
class RegrasCaixaTest {

    private lateinit var banco: BancoLocal
    private lateinit var dao: PdvDao
    private lateinit var caixa: RepositorioCaixa

    @Before
    fun montar() {
        val ctx = ApplicationProvider.getApplicationContext<Context>()
        banco = Room.inMemoryDatabaseBuilder(ctx, BancoLocal::class.java)
            .allowMainThreadQueries().build()
        dao = banco.dao()
        caixa = RepositorioCaixa(dao)
    }

    @After
    fun desmontar() = banco.close()

    // ------------------------------------------------------------ apoio

    private suspend fun comandaCom(
        centavos: Long,
        numero: Int = 1,
        controle: Boolean = false,
        servicoPct: Double = 0.0
    ): Long {
        val id = dao.inserirComanda(
            Comanda(
                numero = numero, taxaServicoPct = servicoPct, controle = controle,
                abertaPor = "Beto", abertaEm = 0L
            )
        )
        val pedidoId = dao.inserirPedido(Pedido(comandaId = id, criadoPor = "Beto", criadoEm = 0L))
        dao.inserirItens(
            listOf(
                ItemLancado(
                    pedidoId = pedidoId, comandaId = id, itemCardapioId = "x", nome = "Prato",
                    quantidade = 1, precoUnitCentavos = centavos, pontoId = "cozinha"
                )
            )
        )
        dao.comandaAgora(id)?.let { dao.atualizarComanda(it.copy(status = StatusComanda.FECHADA)) }
        return id
    }

    private fun ok(r: ResultadoOperacao) = r is ResultadoOperacao.Ok
    private fun erro(r: ResultadoOperacao) = (r as? ResultadoOperacao.Erro)?.mensagem ?: ""

    // ------------------------------------------------ guarda da sessao

    @Test
    fun `nao recebe pagamento sem caixa aberto`() = runTest {
        val id = comandaCom(5_000)
        val r = caixa.receber(id, MetodoPagamento.DINHEIRO, 5_000, null, "Beto")
        assertTrue(erro(r).contains("caixa", ignoreCase = true))
        assertEquals(0L, dao.totalPagoDaComanda(id))
    }

    @Test
    fun `nao abre dois caixas ao mesmo tempo`() = runTest {
        assertTrue(ok(caixa.abrirCaixa(10_000, "Beto")))
        val r = caixa.abrirCaixa(5_000, "Ana")
        assertTrue(erro(r).contains("já existe", ignoreCase = true))
    }

    // ------------------------------------------------------ recebimento

    @Test
    fun `recebimento em dinheiro calcula o troco e quita a comanda`() = runTest {
        caixa.abrirCaixa(10_000, "Beto")
        val id = comandaCom(5_000)
        // cliente entrega 100 numa conta de 50
        val r = caixa.receber(id, MetodoPagamento.DINHEIRO, 5_000, 10_000, "Beto")
        assertTrue(ok(r))
        assertTrue((r as ResultadoOperacao.Ok).mensagem.contains("troco"))

        val pagamento = dao.pagamentosDaComandaAgora(id).single()
        assertEquals(5_000, pagamento.valorCentavos)
        assertEquals(5_000, pagamento.trocoCentavos)
        assertEquals(StatusComanda.RECEBIDA, dao.comandaAgora(id)!!.status)
    }

    @Test
    fun `nao aceita dinheiro menor que o valor a receber`() = runTest {
        caixa.abrirCaixa(10_000, "Beto")
        val id = comandaCom(5_000)
        val r = caixa.receber(id, MetodoPagamento.DINHEIRO, 5_000, 3_000, "Beto")
        assertTrue(erro(r).contains("menos"))
        assertEquals(0L, dao.totalPagoDaComanda(id))
    }

    @Test
    fun `pagamento parcial deixa a comanda fechada ate quitar`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaCom(10_000)

        assertTrue(ok(caixa.receber(id, MetodoPagamento.CREDITO, 6_000, null, "Beto")))
        assertEquals(StatusComanda.FECHADA, dao.comandaAgora(id)!!.status)
        assertEquals(4_000, caixa.saldo(id)!!.faltaCentavos)

        assertTrue(ok(caixa.receber(id, MetodoPagamento.DINHEIRO, 4_000, null, "Beto")))
        assertEquals(StatusComanda.RECEBIDA, dao.comandaAgora(id)!!.status)
        assertEquals(0, caixa.saldo(id)!!.faltaCentavos)
    }

    @Test
    fun `nao recebe mais do que a comanda deve`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaCom(5_000)
        val r = caixa.receber(id, MetodoPagamento.PIX, 9_999, null, "Beto")
        assertTrue(erro(r).contains("Falta apenas"))
    }

    @Test
    fun `forma de pagamento invalida e recusada`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaCom(5_000)
        assertTrue(erro(caixa.receber(id, "bitcoin", 5_000, null, "Beto")).contains("inválida"))
    }

    // -------------------------------------------------------- movimentos

    @Test
    fun `sangria maior que a gaveta e recusada`() = runTest {
        caixa.abrirCaixa(10_000, "Beto")   // gaveta com R$ 100
        val r = caixa.registrarMovimento(TipoMovimento.SANGRIA, 15_000, "cofre", "Beto")
        assertTrue(erro(r).contains("não dá para sangrar"))
    }

    @Test
    fun `sangria dentro do saldo passa e reduz a gaveta`() = runTest {
        caixa.abrirCaixa(10_000, "Beto")
        assertTrue(ok(caixa.registrarMovimento(TipoMovimento.SANGRIA, 4_000, "cofre", "Beto")))
        assertEquals(6_000, caixa.apuracao()!!.esperadoEmDinheiroCentavos)
    }

    @Test
    fun `movimento sem motivo e recusado`() = runTest {
        caixa.abrirCaixa(10_000, "Beto")
        assertTrue(erro(caixa.registrarMovimento(TipoMovimento.SANGRIA, 100, "", "Beto")).contains("motivo"))
    }

    // -------------------------------------------------------- fechamento

    @Test
    fun `nao fecha o caixa com comanda pendente`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        comandaCom(5_000, numero = 7)
        val r = caixa.fecharCaixa(0, "Beto", null)
        assertTrue(erro(r).contains("sem receber"))
        assertTrue(erro(r).contains("7"))
    }

    @Test
    fun `comanda de CONTROLE nao trava o fechamento`() = runTest {
        // banda e almoco da equipe ficam abertos de proposito; se travassem,
        // o caixa nunca fecharia
        caixa.abrirCaixa(0, "Beto")
        comandaCom(5_000, numero = 900, controle = true)
        assertTrue(ok(caixa.fecharCaixa(0, "Beto", null)))
    }

    @Test
    fun `fechamento apura a diferenca da gaveta`() = runTest {
        caixa.abrirCaixa(10_000, "Beto")
        val id = comandaCom(5_000)
        caixa.receber(id, MetodoPagamento.DINHEIRO, 5_000, 5_000, "Beto")

        // esperado: 100 de fundo + 50 recebido = 150; operador conta 148
        val r = caixa.fecharCaixa(14_800, "Beto", "duas notas amassadas")
        assertTrue(ok(r))
        assertTrue((r as ResultadoOperacao.Ok).mensagem.contains("faltando"))

        val sessoes = dao.historicoSessoesAgora()
        assertEquals(StatusSessao.FECHADA, sessoes.first().status)
        assertEquals(14_800L, sessoes.first().contadoCentavos)
    }

    @Test
    fun `depois de fechar nao recebe mais`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val idPago = comandaCom(1_000, numero = 1)
        caixa.receber(idPago, MetodoPagamento.PIX, 1_000, null, "Beto")
        caixa.fecharCaixa(0, "Beto", null)

        val novo = comandaCom(2_000, numero = 2)
        assertTrue(erro(caixa.receber(novo, MetodoPagamento.PIX, 2_000, null, "Beto")).contains("caixa"))
    }
}
