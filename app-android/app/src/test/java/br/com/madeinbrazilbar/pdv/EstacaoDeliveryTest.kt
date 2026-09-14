package br.com.madeinbrazilbar.pdv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import br.com.madeinbrazilbar.pdv.dados.*
import br.com.madeinbrazilbar.pdv.impressao.ConclusaoDelivery
import br.com.madeinbrazilbar.pdv.impressao.EstacaoDelivery
import br.com.madeinbrazilbar.pdv.impressao.FilaImpressao
import br.com.madeinbrazilbar.pdv.impressao.Impressora
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import br.com.madeinbrazilbar.pdv.sincronia.texto
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Estação de impressão do delivery com banco de verdade (Room em memória),
 * servidor falso e térmica de mentira.
 */
@RunWith(RobolectricTestRunner::class)
class EstacaoDeliveryTest {

    private val contexto: Context = ApplicationProvider.getApplicationContext()
    private lateinit var banco: BancoLocal
    private lateinit var dao: PdvDao
    private lateinit var cardapio: Cardapio
    private lateinit var servidor: ServidorFalso
    private lateinit var conclusao: ConclusaoDelivery
    private lateinit var estacao: EstacaoDelivery
    private lateinit var fila: FilaImpressao

    /** Avisos ao servidor que a fila dispara em segundo plano. */
    private val avisos = SupervisorJob()
    private val pontosFora = mutableSetOf<String>()
    private val impressos = mutableListOf<String>()

    private val termicaFalsa: suspend (PontoProducao, ByteArray) -> Impressora.Resultado = { ponto, _ ->
        if (ponto.id in pontosFora) Impressora.Resultado.Falha("sem resposta")
        else Impressora.Resultado.Ok.also { impressos += ponto.id }
    }

    @Before
    fun montar() {
        banco = Room.inMemoryDatabaseBuilder(contexto, BancoLocal::class.java).allowMainThreadQueries().build()
        dao = banco.dao()
        cardapio = Cardapio.carregar(contexto)
        servidor = ServidorFalso()
        conclusao = ConclusaoDelivery(dao) { servidor }
        estacao = EstacaoDelivery(dao, servidor, conclusao, { cardapio })
        fila = FilaImpressao(
            dao, { cardapio }, CoroutineScope(Dispatchers.Unconfined + avisos), null, termicaFalsa, conclusao
        )
    }

    @After
    fun desmontar() {
        avisos.cancel()
        banco.close()
    }

    private suspend fun esperarAvisos() = avisos.children.toList().forEach { it.join() }

    private suspend fun imprimir(rodadas: Int = 1) {
        repeat(rodadas) { fila.processarPendentes() }
        esperarAvisos()
    }

    private suspend fun cupons() = dao.historicoImpressao().first()

    // ----------------------------------------------------------------------

    @Test
    fun `reserva e enfileira o cupom no ponto pelo codigo, sem pedido do PDV`() = runBlocking {
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")

        assertEquals(1, estacao.rodada())

        val t = cupons().single()
        assertEquals("cozinha", t.pontoId)
        assertEquals(TipoImpressao.DELIVERY, t.tipo)
        assertEquals("t1", t.trabalhoDeliveryId)
        assertNull(t.pedidoId)
        assertEquals(StatusImpressao.PENDENTE, t.status)
        assertTrue(t.previa.contains("DELIVERY #42"))
        assertEquals(listOf("dlv_reservar_impressoes"), servidor.chamadasRpc)
    }

    @Test
    fun `rodada sem trabalho tambem chama o servidor, que e o sinal de vida`() = runBlocking {
        assertEquals(0, estacao.rodada())
        assertEquals(0, estacao.rodada())
        assertEquals(listOf("dlv_reservar_impressoes", "dlv_reservar_impressoes"), servidor.chamadasRpc)
        assertNotNull(estacao.estado.value.ultimaReservaEm)
        assertTrue(cupons().isEmpty())
    }

    @Test
    fun `mesmo trabalho entregue duas vezes nao entra duas vezes na fila`() = runBlocking {
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        estacao.rodada()
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")   // reserva venceu e voltou
        assertEquals(0, estacao.rodada())

        assertEquals(1, cupons().size)
        assertTrue("ainda na fila: nada a avisar", servidor.conclusoesDelivery.isEmpty())
    }

    @Test
    fun `cupom impresso avisa o servidor com ok`() = runBlocking {
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        estacao.rodada()
        imprimir()

        assertEquals(listOf("cozinha"), impressos)
        val aviso = servidor.conclusoesDelivery.single()
        assertEquals("t1", aviso.texto("p_trabalho"))
        assertEquals("true", aviso.texto("p_ok"))
        assertNull(aviso.texto("p_erro"))
        assertTrue(cupons().single().concluidoNoServidor)
    }

    @Test
    fun `falha so avisa o servidor depois de esgotar as tentativas`() = runBlocking {
        pontosFora += "cozinha"
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        estacao.rodada()

        imprimir()
        assertTrue("ainda vai tentar de novo", servidor.conclusoesDelivery.isEmpty())

        imprimir(Configuracao.IMPRESSAO_TENTATIVAS - 1)
        val aviso = servidor.conclusoesDelivery.single()
        assertEquals("false", aviso.texto("p_ok"))
        assertEquals("sem resposta", aviso.texto("p_erro"))
        assertEquals(StatusImpressao.FALHA, cupons().single().status)
        assertTrue(cupons().single().concluidoNoServidor)
    }

    @Test
    fun `sem rede o aviso nao trava a fila e a proxima rodada reenvia`() = runBlocking {
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        servidor.filaDelivery += ExemplosDelivery.trabalho("t2", tipo = "via_entrega", ponto = "caixa")
        estacao.rodada()

        servidor.rpcForaDoAr = true
        imprimir()
        assertEquals("os dois cupons saíram mesmo sem servidor", setOf("cozinha", "caixa"), impressos.toSet())
        assertTrue(cupons().all { it.status == StatusImpressao.ENVIADO && !it.concluidoNoServidor })

        // a reserva do t1 venceu no servidor e ele voltou pra fila de lá
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        servidor.rpcForaDoAr = false
        assertEquals(0, estacao.rodada())

        assertEquals(setOf("t1", "t2"), servidor.conclusoesDelivery.map { it.texto("p_trabalho") }.toSet())
        assertTrue(servidor.conclusoesDelivery.all { it.texto("p_ok") == "true" })
        assertTrue(cupons().all { it.concluidoNoServidor })
        assertEquals("nada reimprime", 2, cupons().size)
        assertEquals(2, impressos.size)
    }

    @Test
    fun `trabalho que volta antes do aviso chegar so reenvia o aviso`() = runBlocking {
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        estacao.rodada()
        servidor.rpcForaDoAr = true
        imprimir()
        servidor.rpcForaDoAr = false
        assertFalse(cupons().single().concluidoNoServidor)

        // o reenvio do começo da rodada não consegue (cliente ainda sem login),
        // e a reserva devolve o mesmo trabalho: o aviso sai na hora de receber
        var pedidosDeCliente = 0
        val conclusaoAtrasada = ConclusaoDelivery(dao) { if (pedidosDeCliente++ == 0) null else servidor }
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        assertEquals(0, EstacaoDelivery(dao, servidor, conclusaoAtrasada, { cardapio }).rodada())

        val aviso = servidor.conclusoesDelivery.single()
        assertEquals("t1", aviso.texto("p_trabalho"))
        assertEquals("true", aviso.texto("p_ok"))
        assertEquals(StatusImpressao.ENVIADO, cupons().single().status)
        assertTrue(cupons().single().concluidoNoServidor)
        assertEquals("não reimprime", 1, impressos.size)
    }

    @Test
    fun `ponto desconhecido no aparelho devolve falha sem enfileirar`() = runBlocking {
        servidor.filaDelivery += ExemplosDelivery.trabalho("t9", ponto = "churrasqueira")

        assertEquals(0, estacao.rodada())

        assertTrue(cupons().isEmpty())
        val aviso = servidor.conclusoesDelivery.single()
        assertEquals("t9", aviso.texto("p_trabalho"))
        assertEquals("false", aviso.texto("p_ok"))
        assertEquals("ponto churrasqueira desconhecido no aparelho", aviso.texto("p_erro"))
    }

    @Test
    fun `servidor mandando de novo cupom que falhou e ja foi avisado imprime de novo`() = runBlocking {
        pontosFora += "cozinha"
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        estacao.rodada()
        imprimir(Configuracao.IMPRESSAO_TENTATIVAS)
        assertTrue(cupons().single().concluidoNoServidor)

        // o servidor devolveu o trabalho pra fila (nova tentativa) e a térmica voltou
        pontosFora.clear()
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        estacao.rodada()
        val volta = cupons().single()
        assertEquals(StatusImpressao.PENDENTE, volta.status)
        assertEquals(0, volta.tentativas)
        assertFalse(volta.concluidoNoServidor)

        imprimir()
        assertEquals(listOf("false", "true"), servidor.conclusoesDelivery.map { it.texto("p_ok") })
        assertEquals(listOf("cozinha"), impressos)
    }

    @Test
    fun `cupom do delivery nao pode ser reimpresso a mao`() = runBlocking {
        pontosFora += "cozinha"
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        estacao.rodada()
        imprimir(Configuracao.IMPRESSAO_TENTATIVAS)
        val t = cupons().single()

        val r = Repositorio(dao, cardapio, null).reimprimir(t.id)

        assertTrue(r is ResultadoOperacao.Erro)
        assertEquals(StatusImpressao.FALHA, cupons().single().status)
    }

    @Test
    fun `cupom do delivery nao mexe na situacao de impressao de pedido do PDV`() = runBlocking {
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        estacao.rodada()
        val comSincronia = FilaImpressao(
            dao, { cardapio }, CoroutineScope(Dispatchers.Unconfined + avisos), Sincronia(banco), termicaFalsa, conclusao
        )
        comSincronia.processarPendentes()
        esperarAvisos()

        assertEquals(StatusImpressao.ENVIADO, cupons().single().status)
        assertTrue("print_status do PDV não sobe por cupom do delivery", dao.todasOperacoes().isEmpty())
    }

    @Test
    fun `laco so conversa com o servidor com a chave ligada`() = runBlocking {
        val rapida = EstacaoDelivery(dao, servidor, conclusao, { cardapio }, intervaloMs = 20)
        val ligada = AtomicBoolean(false)
        val escopo = CoroutineScope(SupervisorJob())
        servidor.filaDelivery += ExemplosDelivery.trabalho("t1")
        try {
            rapida.iniciar(escopo) { ligada.get() }
            delay(200)
            assertTrue("desligada: nenhuma chamada", servidor.chamadasRpc.isEmpty())

            ligada.set(true)
            withTimeout(5_000) {
                while (rapida.estado.value.cuponsRecebidos < 1) delay(20)
            }
        } finally {
            escopo.coroutineContext[kotlinx.coroutines.Job]!!.cancelAndJoin()
        }
        assertEquals("t1", cupons().single().trabalhoDeliveryId)
    }
}
