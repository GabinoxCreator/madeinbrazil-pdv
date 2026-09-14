package br.com.madeinbrazilbar.pdv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import br.com.madeinbrazilbar.pdv.dados.*
import br.com.madeinbrazilbar.pdv.impressao.FilaImpressao
import br.com.madeinbrazilbar.pdv.impressao.Impressora
import br.com.madeinbrazilbar.pdv.sincronia.Mapeamento
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import br.com.madeinbrazilbar.pdv.sincronia.texto
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import kotlin.coroutines.EmptyCoroutineContext

/**
 * Situação de impressão do pedido (enviado / falha / parcial) calculada pela
 * fila e mandada pro servidor. Banco de verdade (Room em memória) e térmica
 * de mentira: nos testes nenhuma impressora da rede é acessível.
 */
@RunWith(RobolectricTestRunner::class)
class StatusImpressaoPedidoTest {

    private val contexto: Context = ApplicationProvider.getApplicationContext()
    private lateinit var banco: BancoLocal
    private lateinit var dao: PdvDao
    private lateinit var cardapio: Cardapio
    private lateinit var sincronia: Sincronia
    private lateinit var repo: Repositorio

    /** Pontos de produção cuja térmica está "fora do ar". */
    private val pontosFora = mutableSetOf<String>()

    private val termicaFalsa: suspend (PontoProducao, ByteArray) -> Impressora.Resultado = { ponto, _ ->
        if (ponto.id in pontosFora) Impressora.Resultado.Falha("sem resposta") else Impressora.Resultado.Ok
    }

    @Before
    fun montar() {
        banco = Room.inMemoryDatabaseBuilder(contexto, BancoLocal::class.java)
            .allowMainThreadQueries().build()
        dao = banco.dao()
        cardapio = Cardapio.carregar(contexto)
        sincronia = Sincronia(banco)
        repo = Repositorio(dao, cardapio, sincronia)
    }

    @After
    fun desmontar() = banco.close()

    private fun ok(r: ResultadoOperacao) {
        if (r is ResultadoOperacao.Erro) fail(r.mensagem)
    }

    private fun fila(comSincronia: Boolean = true) =
        FilaImpressao(dao, { cardapio }, CoroutineScope(EmptyCoroutineContext), if (comSincronia) sincronia else null, termicaFalsa)

    /** Comanda 15 com feijoada (cozinha) e caipirinha (drink): um cupom em cada ponto. */
    private suspend fun pedidoEmDoisPontos(): Pedido {
        ok(repo.abrirComanda(15, null, 1, null, false, "Beto"))
        val comandaId = dao.comandasVivasAgora().single().id
        val itens = listOf("103", "188").map { codigo -> ItemEscolhido(cardapio.itens.first { it.codigo == codigo }, 1) }
        ok(repo.lancarPedido(comandaId, itens, "Beto"))
        val pedidoId = dao.impressoesPendentes().mapNotNull { it.pedidoId }.distinct().single()
        return dao.pedido(pedidoId)!!
    }

    private suspend fun statusDe(p: Pedido) = dao.pedido(p.id)!!.statusImpressao

    /** Atualizações de pedido na fila de envio, na ordem. */
    private suspend fun enviosDeStatus() = dao.todasOperacoes()
        .filter { it.tabela == Mapeamento.PEDIDOS && it.tipo == TipoOperacao.ATUALIZAR }

    private suspend fun rodadas(f: FilaImpressao, n: Int) = repeat(n) { f.processarPendentes() }

    // ----------------------------------------------------------------------

    @Test
    fun `situacao do pedido sai dos cupons de todos os pontos`() {
        assertNull(StatusImpressao.doPedido(emptyList()))
        assertNull(StatusImpressao.doPedido(listOf(StatusImpressao.ENVIADO, StatusImpressao.PENDENTE)))
        assertEquals(StatusImpressao.ENVIADO, StatusImpressao.doPedido(listOf("enviado", "enviado")))
        assertEquals(StatusImpressao.FALHA, StatusImpressao.doPedido(listOf("falha", "falha")))
        assertEquals(StatusImpressao.PARCIAL, StatusImpressao.doPedido(listOf("enviado", "falha")))
    }

    @Test
    fun `todos os cupons impressos marcam enviado e sobem so o print_status`() = runBlocking {
        val p = pedidoEmDoisPontos()
        fila().processarPendentes()

        assertEquals(StatusImpressao.ENVIADO, statusDe(p))
        val envio = enviosDeStatus().single()
        assertEquals(p.uuid, envio.registroUuid)
        val campos = Json.parseToJsonElement(envio.payload).jsonObject
        assertEquals(setOf("print_status"), campos.keys)
        assertEquals("enviado", campos.texto("print_status"))
    }

    @Test
    fun `termicas fora do ar so marcam falha depois de esgotar as tentativas`() = runBlocking {
        val p = pedidoEmDoisPontos()
        pontosFora += listOf("cozinha", "drink")
        val f = fila()

        f.processarPendentes()
        assertEquals("ainda vai tentar de novo: nada muda", StatusImpressao.PENDENTE, statusDe(p))
        assertTrue(enviosDeStatus().isEmpty())

        rodadas(f, Configuracao.IMPRESSAO_TENTATIVAS - 1)
        assertEquals(StatusImpressao.FALHA, statusDe(p))
        assertEquals(1, enviosDeStatus().size)
    }

    @Test
    fun `um ponto imprime e outro nao marca parcial`() = runBlocking {
        val p = pedidoEmDoisPontos()
        pontosFora += "drink"
        val f = fila()

        f.processarPendentes()
        assertEquals("o drink ainda está na fila", StatusImpressao.PENDENTE, statusDe(p))

        rodadas(f, Configuracao.IMPRESSAO_TENTATIVAS - 1)
        assertEquals(StatusImpressao.PARCIAL, statusDe(p))
        val campos = Json.parseToJsonElement(enviosDeStatus().single().payload).jsonObject
        assertEquals("parcial", campos.texto("print_status"))
    }

    @Test
    fun `reimprimir o cupom que falhou recalcula quando ele sai`() = runBlocking {
        val p = pedidoEmDoisPontos()
        pontosFora += "drink"
        val f = fila()
        rodadas(f, Configuracao.IMPRESSAO_TENTATIVAS)
        assertEquals(StatusImpressao.PARCIAL, statusDe(p))

        pontosFora.clear()
        val falhou = dao.historicoImpressao().first().single { it.status == StatusImpressao.FALHA }
        ok(repo.reimprimir(falhou.id))
        assertEquals("reenfileirado ainda não saiu", StatusImpressao.PARCIAL, statusDe(p))

        f.processarPendentes()
        assertEquals(StatusImpressao.ENVIADO, statusDe(p))
        assertEquals(
            listOf("parcial", "enviado"),
            enviosDeStatus().map { Json.parseToJsonElement(it.payload).jsonObject.texto("print_status") }
        )
    }

    @Test
    fun `pedido vindo de outro terminal fica como veio`() = runBlocking {
        val comandaId = dao.inserirComanda(
            Comanda(numero = 20, taxaServicoPct = 0.0, abertaPor = "Ana", abertaEm = 0L)
        )
        val remotoId = dao.inserirPedido(
            Pedido(comandaId = comandaId, criadoPor = "Ana", criadoEm = 0L, statusImpressao = StatusImpressao.FALHA)
        )
        ok(repo.imprimirConferencia(comandaId))   // cupom sem pedido
        val f = fila()

        f.processarPendentes()
        f.atualizarImpressaoDoPedido(remotoId)

        assertEquals(StatusImpressao.FALHA, dao.pedido(remotoId)!!.statusImpressao)
        assertTrue(enviosDeStatus().isEmpty())
    }

    @Test
    fun `sem sincronia a situacao muda so no aparelho`() = runBlocking {
        val p = pedidoEmDoisPontos()
        fila(comSincronia = false).processarPendentes()
        assertEquals(StatusImpressao.ENVIADO, statusDe(p))
        assertTrue(enviosDeStatus().isEmpty())
    }
}
