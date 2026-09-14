package br.com.madeinbrazilbar.pdv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import br.com.madeinbrazilbar.pdv.dados.*
import br.com.madeinbrazilbar.pdv.sincronia.ClienteSupabase
import br.com.madeinbrazilbar.pdv.sincronia.MotorSincronizacao
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.util.Properties

/**
 * DOIS terminais operando a MESMA comanda no SERVIDOR DE VERDADE, com a conta
 * real do terminal e o código real de sincronização.
 *
 * Não roda por padrão (grava no servidor). Para rodar:
 *   PDV_INTEGRACAO=1 gradle :app:testDebugUnitTest --tests '*IntegracaoServidorTest*'
 *
 * Tudo que o teste grava leva o operador "TESTE-INTEGRACAO", pra ser achado
 * e limpo depois. A comanda termina recebida e o caixa termina fechado, pra
 * não travar a operação real.
 */
@RunWith(RobolectricTestRunner::class)
class IntegracaoServidorTest {

    companion object {
        const val OPERADOR = "TESTE-INTEGRACAO"
        const val NUMERO = 97
    }

    private val contexto: Context = ApplicationProvider.getApplicationContext()
    private val bancos = mutableListOf<BancoLocal>()

    private fun credenciais(): Properties? {
        val arquivo = File("../credenciais.properties")
        if (!arquivo.exists()) return null
        return Properties().apply { arquivo.inputStream().use { load(it) } }
    }

    inner class Terminal(cfg: Properties) {
        val banco: BancoLocal = Room.inMemoryDatabaseBuilder(contexto, BancoLocal::class.java)
            .allowMainThreadQueries().build().also { bancos += it }
        val dao = banco.dao()
        val cardapio = Cardapio.carregar(contexto)
        val sincronia = Sincronia(banco)
        val repo = Repositorio(dao, cardapio, sincronia)
        val caixa = RepositorioCaixa(dao, sincronia)
        val motor = MotorSincronizacao(
            banco,
            ClienteSupabase(
                cfg.getProperty("servidor.url"),
                cfg.getProperty("servidor.chave_publica"),
                cfg.getProperty("terminal.email"),
                cfg.getProperty("terminal.senha")
            )
        )
        fun item(codigo: String) = cardapio.itens.first { it.codigo == codigo }

        suspend fun enviar() {
            if (!motor.enviarPendentes()) fail("envio travou: ${motor.estado.value.ultimoErro}")
        }
    }

    private fun ok(r: ResultadoOperacao) {
        if (r is ResultadoOperacao.Erro) fail(r.mensagem)
    }

    @After
    fun desmontar() = bancos.forEach { it.close() }

    @Test
    fun `dois terminais operando a mesma comanda no servidor real`() = runBlocking {
        assumeTrue("defina PDV_INTEGRACAO=1 para rodar", System.getenv("PDV_INTEGRACAO") == "1")
        val cfg = credenciais()
        assumeTrue("sem credenciais.properties", cfg != null)

        val a = Terminal(cfg!!)
        val b = Terminal(cfg)

        // 1. A abre o caixa e a comanda, lança feijoada x2 e caipirinha
        ok(a.caixa.abrirCaixa(10_000, OPERADOR))
        ok(a.repo.abrirComanda(NUMERO, "TESTE", 2, "Integração", false, OPERADOR))
        val idA = a.dao.comandasVivasAgora().single { it.numero == NUMERO }.id
        ok(a.repo.lancarPedido(idA, listOf(ItemEscolhido(a.item("103"), 2), ItemEscolhido(a.item("188"), 1)), OPERADOR))
        a.enviar()
        println("1) A enviou caixa, comanda $NUMERO e 2 itens")

        // 2. B recebe e enxerga tudo
        b.motor.receber()
        val idB = b.dao.comandasVivasAgora().single { it.numero == NUMERO }.id
        assertEquals(2, b.dao.itensDaComandaAgora(idB).size)
        assertNotNull(b.dao.sessaoAbertaAgora())
        assertEquals(a.repo.conta(idA)!!.totalCentavos, b.repo.conta(idB)!!.totalCentavos)
        println("2) B viu a comanda, os 2 itens e o caixa aberto")

        // 3. B lança uma água; A vê
        ok(b.repo.lancarPedido(idB, listOf(ItemEscolhido(b.item("230"), 1)), OPERADOR))
        b.enviar()
        a.motor.receber()
        assertEquals(3, a.dao.itensDaComandaAgora(idA).size)
        println("3) B lançou água; A viu 3 itens")

        // 4. A cancela a caipirinha; B vê
        val caipirinha = a.dao.itensDaComandaAgora(idA).single { it.nome == "Caipirinha" }
        ok(a.repo.cancelarItem(caipirinha.id, "teste de integração", OPERADOR))
        a.enviar()
        b.motor.receber()
        assertEquals(2, b.dao.itensDaComandaAgora(idB).size)
        println("4) A cancelou a caipirinha; B viu 2 itens ativos")

        // 5. B fecha e recebe em dinheiro com troco; A vê recebida
        ok(b.repo.fecharComanda(idB, OPERADOR))
        val falta = b.caixa.saldo(idB)!!.faltaCentavos
        ok(b.caixa.receber(idB, MetodoPagamento.DINHEIRO, falta, falta + 1_000, OPERADOR))
        b.enviar()
        a.motor.receber()
        assertEquals(StatusComanda.RECEBIDA, a.dao.comandaAgora(idA)!!.status)
        assertEquals(falta, a.dao.totalPagoDaComanda(idA))
        println("5) B recebeu ${Dinheiro.comSimbolo(falta)} com troco de R$ 10,00; A viu a comanda recebida")

        // 6. A fecha o caixa com o valor esperado; B vê fechado
        val esperado = a.caixa.apuracao()!!.esperadoEmDinheiroCentavos
        assertEquals(10_000 + falta, esperado)
        ok(a.caixa.fecharCaixa(esperado, OPERADOR, "teste de integração"))
        a.enviar()
        b.motor.receber()
        assertNull(b.dao.sessaoAbertaAgora())
        println("6) A fechou o caixa (${Dinheiro.comSimbolo(esperado)}); B viu fechado")

        // 7. cardápio do servidor
        val cardapio = a.motor.baixarCardapio(a.cardapio)
        assertEquals(180, cardapio!!.itens.size)
        assertTrue(cardapio.itens.all { it.id.length == 36 })
        println("7) cardápio baixado: ${cardapio.itens.size} itens")

        println("COMANDA_UUID=" + a.dao.comandaAgora(idA)!!.uuid)
    }
}
