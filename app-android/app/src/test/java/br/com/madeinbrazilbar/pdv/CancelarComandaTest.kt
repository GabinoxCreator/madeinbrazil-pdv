package br.com.madeinbrazilbar.pdv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import br.com.madeinbrazilbar.pdv.dados.*
import br.com.madeinbrazilbar.pdv.sincronia.Mapeamento
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import br.com.madeinbrazilbar.pdv.sincronia.texto
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Cancelar comanda aberta por engano, com banco DE VERDADE (Room em memória).
 * As regras repetem a função pdv_cancelar_comanda do servidor.
 */
@RunWith(RobolectricTestRunner::class)
class CancelarComandaTest {

    private val contexto: Context = ApplicationProvider.getApplicationContext()
    private lateinit var banco: BancoLocal
    private lateinit var dao: PdvDao
    private lateinit var repo: Repositorio
    private lateinit var caixa: RepositorioCaixa

    @Before
    fun montar() {
        banco = Room.inMemoryDatabaseBuilder(contexto, BancoLocal::class.java)
            .allowMainThreadQueries().build()
        dao = banco.dao()
        val sincronia = Sincronia(banco)
        repo = Repositorio(dao, Cardapio.carregar(contexto), sincronia)
        caixa = RepositorioCaixa(dao, sincronia)
    }

    @After
    fun desmontar() = banco.close()

    private fun ok(r: ResultadoOperacao) {
        if (r is ResultadoOperacao.Erro) fail(r.mensagem)
    }

    private fun erro(r: ResultadoOperacao) = (r as? ResultadoOperacao.Erro)?.mensagem ?: ""

    private suspend fun abrir(numero: Int = 15): Long {
        ok(repo.abrirComanda(numero, null, 1, null, false, "Beto"))
        return dao.comandasVivasAgora().single { it.numero == numero }.id
    }

    // ------------------------------------------------------------ regras

    @Test
    fun `cancelar exige motivo`() = runBlocking {
        val id = abrir()
        assertEquals("Informe o motivo do cancelamento", erro(repo.cancelarComanda(id, "  ", "Beto")))
        assertEquals(StatusComanda.ABERTA, dao.comandaAgora(id)!!.status)
    }

    @Test
    fun `so cancela comanda aberta ou fechada`() = runBlocking {
        val id = abrir()
        ok(repo.fecharComanda(id, "Beto"))
        ok(repo.cancelarComanda(id, "aberta por engano", "Beto"))   // fechada também cancela
        assertEquals(
            "Comanda 15 já está cancelada",
            erro(repo.cancelarComanda(id, "de novo", "Beto"))
        )
    }

    @Test
    fun `comanda com pagamento nao pode ser cancelada`() = runBlocking {
        ok(caixa.abrirCaixa(0, "Beto"))
        val id = abrir()
        val sessao = dao.sessaoAbertaAgora()!!
        dao.inserirPagamento(
            Pagamento(
                comandaId = id, sessaoId = sessao.id, metodo = MetodoPagamento.PIX,
                valorCentavos = 1_000, recebidoPor = "Beto", recebidoEm = 0L
            )
        )
        assertEquals(
            "A comanda 15 já tem pagamento registrado e não pode ser cancelada",
            erro(repo.cancelarComanda(id, "engano", "Beto"))
        )
        assertEquals(StatusComanda.ABERTA, dao.comandaAgora(id)!!.status)
    }

    @Test
    fun `comanda com item ativo so cancela depois de cancelar os itens`() = runBlocking {
        val cardapio = Cardapio.carregar(contexto)
        val id = abrir()
        ok(repo.lancarPedido(id, listOf(ItemEscolhido(cardapio.itens.first { it.codigo == "103" }, 1)), "Beto"))

        assertEquals(
            "A comanda 15 tem itens lançados: cancele os itens (com motivo) antes de cancelar a comanda",
            erro(repo.cancelarComanda(id, "engano", "Beto"))
        )

        ok(repo.cancelarItem(dao.itensDaComandaAgora(id).single().id, "lançado errado", "Beto"))
        ok(repo.cancelarComanda(id, "engano", "Beto"))
        assertEquals(StatusComanda.CANCELADA, dao.comandaAgora(id)!!.status)
    }

    // ------------------------------------------------------- efeitos

    @Test
    fun `cancelamento sai da lista e sobe so os campos liberados no servidor`() = runBlocking {
        val id = abrir()
        ok(repo.cancelarComanda(id, "  aberta por engano ", "Ana"))

        val c = dao.comandaAgora(id)!!
        assertEquals(StatusComanda.CANCELADA, c.status)
        assertNotNull(c.fechadaEm)
        assertEquals("Ana", c.ultimaAtividadePor)
        assertTrue(dao.comandasVivasAgora().isEmpty())

        val op = dao.todasOperacoes().last()
        assertEquals(TipoOperacao.ATUALIZAR, op.tipo)
        assertEquals(Mapeamento.COMANDAS, op.tabela)
        assertEquals(c.uuid, op.registroUuid)
        val campos = Json.parseToJsonElement(op.payload).jsonObject
        assertEquals(
            setOf("status", "closed_at", "cancelled_reason", "last_activity_by_name", "last_activity_at"),
            campos.keys
        )
        assertEquals("cancelada", campos.texto("status"))
        assertEquals("aberta por engano", campos.texto("cancelled_reason"))
        assertEquals("Ana", campos.texto("last_activity_by_name"))
    }

    @Test
    fun `caixa fecha depois de cancelar a comanda aberta por engano`() = runBlocking {
        ok(caixa.abrirCaixa(10_000, "Beto"))
        val id = abrir(numero = 7)
        assertTrue(erro(caixa.fecharCaixa(10_000, "Beto", null)).contains("7"))

        ok(repo.cancelarComanda(id, "aberta por engano", "Beto"))
        ok(caixa.fecharCaixa(10_000, "Beto", null))
    }
}
