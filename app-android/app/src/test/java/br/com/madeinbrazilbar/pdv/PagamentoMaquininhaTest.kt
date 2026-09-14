package br.com.madeinbrazilbar.pdv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import br.com.madeinbrazilbar.pdv.dados.*
import br.com.madeinbrazilbar.pdv.pagamento.CieloSmart
import br.com.madeinbrazilbar.pdv.pagamento.CredenciaisCielo
import br.com.madeinbrazilbar.pdv.pagamento.PagamentoMaquininha
import br.com.madeinbrazilbar.pdv.pagamento.ResultadoCielo
import br.com.madeinbrazilbar.pdv.sincronia.Mapeamento
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Cobrança na maquininha com banco DE VERDADE (Room em memória) e fila de
 * envio ligada, sem maquininha: a resposta da Cielo é simulada.
 */
@RunWith(RobolectricTestRunner::class)
class PagamentoMaquininhaTest {

    private lateinit var banco: BancoLocal
    private lateinit var dao: PdvDao
    private lateinit var caixa: RepositorioCaixa
    private lateinit var maquininha: PagamentoMaquininha

    private val credenciais = CredenciaisCielo("cliente-123", "token-abc")

    @Before
    fun montar() {
        val ctx = ApplicationProvider.getApplicationContext<Context>()
        banco = Room.inMemoryDatabaseBuilder(ctx, BancoLocal::class.java)
            .allowMainThreadQueries().build()
        dao = banco.dao()
        caixa = RepositorioCaixa(dao, Sincronia(banco))
        maquininha = PagamentoMaquininha(dao, caixa)
    }

    @After
    fun desmontar() = banco.close()

    // ------------------------------------------------------------ apoio

    private suspend fun comandaFechadaCom(centavos: Long, numero: Int = 15): Long {
        val id = dao.inserirComanda(Comanda(numero = numero, taxaServicoPct = 0.0, abertaPor = "Beto", abertaEm = 0L))
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

    private suspend fun preparar(comandaId: Long, valor: Long, metodo: String = MetodoPagamento.CREDITO) =
        when (val p = maquininha.preparar(comandaId, metodo, valor, "Ana", credenciais)) {
            is PagamentoMaquininha.Preparo.Pronto -> p
            is PagamentoMaquininha.Preparo.Erro -> { fail(p.mensagem); throw AssertionError() }
        }

    private fun aprovado(referencia: String, valor: Long) = ResultadoCielo.Aprovado(
        referencia = referencia, idPedido = "pedido-cielo-1", idPagamento = "pagamento-cielo-9",
        autorizacao = "123456", nsu = "987654", bandeira = "VISA", mascara = "424242-4242",
        valorCentavos = valor
    )

    private suspend fun operacoesDePagamento() =
        dao.todasOperacoes().filter { it.tabela == Mapeamento.PAGAMENTOS }

    private fun ok(r: ResultadoOperacao) {
        if (r is ResultadoOperacao.Erro) fail(r.mensagem)
    }

    // ------------------------------------------------------------ preparo

    @Test
    fun `preparar grava o pendente antes de abrir a Cielo`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(6_248)
        val pronto = preparar(id, 6_248)

        val p = maquininha.pendente()!!
        assertEquals(pronto.pendente, p)
        assertTrue(Mapeamento.ehUuid(p.referencia))
        assertEquals(id, p.comandaId)
        assertEquals(15, p.comandaNumero)
        assertEquals(6_248L, p.valorCentavos)
        assertEquals("Ana", p.operador)
        assertEquals(dao.sessaoAbertaAgora()!!.id, p.sessaoId)
        assertTrue(pronto.uri.startsWith("lio://payment?request="))
        // nada registrado ainda
        assertEquals(0L, dao.totalPagoDaComanda(id))
    }

    @Test
    fun `sem caixa aberto nao grava pendente`() = runTest {
        val id = comandaFechadaCom(5_000)
        val r = maquininha.preparar(id, MetodoPagamento.CREDITO, 5_000, "Ana", credenciais)
        assertTrue((r as PagamentoMaquininha.Preparo.Erro).mensagem.contains("caixa"))
        assertNull(maquininha.pendente())
    }

    @Test
    fun `valor maior que a falta ou dinheiro nao vao pra maquininha`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(5_000)
        assertTrue(maquininha.preparar(id, MetodoPagamento.PIX, 9_999, "Ana", credenciais) is PagamentoMaquininha.Preparo.Erro)
        assertTrue(maquininha.preparar(id, MetodoPagamento.DINHEIRO, 5_000, "Ana", credenciais) is PagamentoMaquininha.Preparo.Erro)
        assertNull(maquininha.pendente())
    }

    @Test
    fun `nao abre segunda cobranca com pendente aberto`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(5_000)
        preparar(id, 2_000)
        val r = maquininha.preparar(id, MetodoPagamento.DEBITO, 1_000, "Ana", credenciais)
        assertTrue((r as PagamentoMaquininha.Preparo.Erro).mensagem.contains("sem confirmação"))
    }

    // ----------------------------------------------------------- aprovado

    @Test
    fun `aprovado registra o pagamento com os campos cielo e entra na fila de envio`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(6_248)
        val ref = preparar(id, 6_248).pendente.referencia

        ok(maquininha.processarRetorno(aprovado(ref, 6_248)))

        val pagamento = dao.pagamentosDaComandaAgora(id).single()
        assertEquals(ref, pagamento.uuid)
        assertEquals(MetodoPagamento.CREDITO, pagamento.metodo)
        assertEquals(6_248L, pagamento.valorCentavos)
        assertEquals("Ana", pagamento.recebidoPor)
        assertEquals("pagamento-cielo-9", pagamento.cieloTransacaoId)
        assertEquals("987654", pagamento.cieloNsu)
        assertEquals("123456", pagamento.cieloAutorizacao)
        assertEquals(StatusComanda.RECEBIDA, dao.comandaAgora(id)!!.status)
        assertNull(maquininha.pendente())

        val op = operacoesDePagamento().single()
        assertEquals(ref, op.registroUuid)
        val payload = Json.parseToJsonElement(op.payload) as JsonObject
        assertEquals("pagamento-cielo-9", (payload["cielo_transaction_id"] as JsonPrimitive).content)
        assertEquals("987654", (payload["cielo_nsu"] as JsonPrimitive).content)
        assertEquals("123456", (payload["cielo_authorization"] as JsonPrimitive).content)
        // a comanda quitada também sobe
        assertTrue(dao.todasOperacoes().any { it.tabela == Mapeamento.COMANDAS })
    }

    @Test
    fun `resposta de verdade em base64 passa pelo fluxo inteiro`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(3_000)
        val ref = preparar(id, 1_000, MetodoPagamento.PIX).pendente.referencia
        val json = """{"id":"p1","reference":"$ref","status":"PAID","paidAmount":1000,"extra":1,
            "payments":[{"id":"pg1","amount":1000,"authCode":"A1","brand":"PIX","paymentFields":{"nsu":"N1"}}]}"""
        val b64 = CieloSmart.paraBase64(json).trimEnd('=')

        ok(maquininha.processarRetorno(CieloSmart.lerRetorno("mibpdv://pagamento?responsecode=0&response=$b64")))

        val pagamento = dao.pagamentosDaComandaAgora(id).single()
        assertEquals(ref, pagamento.uuid)
        assertEquals("N1", pagamento.cieloNsu)
        assertEquals("pg1", pagamento.cieloTransacaoId)
        // parcial: a comanda continua esperando o resto
        assertEquals(StatusComanda.FECHADA, dao.comandaAgora(id)!!.status)
        assertEquals(2_000L, caixa.saldo(id)!!.faltaCentavos)
    }

    @Test
    fun `resposta duplicada nao registra duas vezes`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(10_000)
        val ref = preparar(id, 4_000).pendente.referencia

        ok(maquininha.processarRetorno(aprovado(ref, 4_000)))
        ok(maquininha.processarRetorno(aprovado(ref, 4_000)))

        assertEquals(1, dao.pagamentosDaComandaAgora(id).size)
        assertEquals(4_000L, dao.totalPagoDaComanda(id))
        assertEquals(1, operacoesDePagamento().size)
    }

    @Test
    fun `aprovado de outra cobranca nao registra e mantem o pendente`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(5_000)
        preparar(id, 5_000)

        val r = maquininha.processarRetorno(aprovado("11111111-1111-1111-1111-111111111111", 5_000))
        assertTrue(r is ResultadoOperacao.Erro)
        assertEquals(0L, dao.totalPagoDaComanda(id))
        assertNotNull(maquininha.pendente())
    }

    @Test
    fun `aprovado barrado pelo caixa fica como pendente com o motivo`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(5_000)
        val ref = preparar(id, 5_000).pendente.referencia
        // outro terminal recebeu a comanda enquanto a maquininha cobrava
        ok(caixa.receber(id, MetodoPagamento.DINHEIRO, 5_000, null, "Beto"))

        val r = maquininha.processarRetorno(aprovado(ref, 5_000))
        assertTrue(r is ResultadoOperacao.Erro)
        assertEquals(1, dao.pagamentosDaComandaAgora(id).size)
        assertNotNull(maquininha.pendente()!!.problema)
    }

    // ------------------------------------------------ recusado / inválido

    @Test
    fun `recusado nao registra nada e apaga o pendente`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(5_000)
        preparar(id, 5_000)

        val r = maquininha.processarRetorno(ResultadoCielo.Recusado(1, "CANCELADO PELO USUÁRIO"))
        assertTrue((r as ResultadoOperacao.Erro).mensagem.contains("CANCELADO"))
        assertEquals(0L, dao.totalPagoDaComanda(id))
        assertTrue(operacoesDePagamento().isEmpty())
        assertNull(maquininha.pendente())
    }

    @Test
    fun `invalido mantem o pendente e o operador registra como pago`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(5_000)
        val ref = preparar(id, 5_000, MetodoPagamento.DEBITO).pendente.referencia

        assertTrue(maquininha.processarRetorno(ResultadoCielo.Invalido("???")) is ResultadoOperacao.Erro)
        assertEquals(0L, dao.totalPagoDaComanda(id))
        assertNotNull(maquininha.pendente()!!.problema)

        ok(maquininha.registrarComoPago())
        val pagamento = dao.pagamentosDaComandaAgora(id).single()
        assertEquals(ref, pagamento.uuid)
        assertEquals(MetodoPagamento.DEBITO, pagamento.metodo)
        assertNull(pagamento.cieloTransacaoId)
        assertEquals(StatusComanda.RECEBIDA, dao.comandaAgora(id)!!.status)
        assertEquals(1, operacoesDePagamento().size)
        assertNull(maquininha.pendente())

        // e se a resposta de verdade chegar depois, não duplica
        ok(maquininha.processarRetorno(aprovado(ref, 5_000)))
        assertEquals(1, dao.pagamentosDaComandaAgora(id).size)
    }

    @Test
    fun `pendente orfao pode ser descartado`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(5_000)
        preparar(id, 5_000)

        // app "morreu": um novo objeto lê o pendente do banco
        val depois = PagamentoMaquininha(dao, caixa)
        assertNotNull(depois.pendente())
        ok(depois.descartar())
        assertNull(depois.pendente())
        assertEquals(0L, dao.totalPagoDaComanda(id))
        assertTrue(operacoesDePagamento().isEmpty())
    }

    @Test
    fun `ao abrir o app some o pendente que ja virou pagamento`() = runTest {
        caixa.abrirCaixa(0, "Beto")
        val id = comandaFechadaCom(5_000)
        val ref = preparar(id, 5_000).pendente.referencia
        // pagamento gravado, mas o app morreu antes de apagar o pendente
        ok(caixa.receber(id, MetodoPagamento.CREDITO, 5_000, null, "Ana", uuid = ref))
        assertNotNull(maquininha.pendente())

        PagamentoMaquininha(dao, caixa).arrumarAoAbrir()
        assertNull(maquininha.pendente())
    }
}
