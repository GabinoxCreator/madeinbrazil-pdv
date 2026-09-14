package br.com.madeinbrazilbar.pdv

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import br.com.madeinbrazilbar.pdv.dados.*
import br.com.madeinbrazilbar.pdv.sincronia.ClienteServidor
import br.com.madeinbrazilbar.pdv.sincronia.DataIso
import br.com.madeinbrazilbar.pdv.sincronia.ErroServidor
import br.com.madeinbrazilbar.pdv.sincronia.Mapeamento
import br.com.madeinbrazilbar.pdv.sincronia.MotorSincronizacao
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import br.com.madeinbrazilbar.pdv.sincronia.texto
import br.com.madeinbrazilbar.pdv.sincronia.textoObrigatorio
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Sincronização com um servidor FALSO (em memória), sem internet.
 * Cada `Terminal` é um aparelho com banco próprio; todos falam com o mesmo
 * servidor falso - dá pra simular dois garçons na mesma comanda.
 */
@RunWith(RobolectricTestRunner::class)
class SincronizacaoTest {

    private val contexto: Context = ApplicationProvider.getApplicationContext()
    private lateinit var servidor: ServidorFalso
    private val bancos = mutableListOf<BancoLocal>()

    inner class Terminal {
        val banco: BancoLocal = Room.inMemoryDatabaseBuilder(contexto, BancoLocal::class.java)
            .allowMainThreadQueries().build().also { bancos += it }
        val dao = banco.dao()
        val cardapio = Cardapio.carregar(contexto)
        val sincronia = Sincronia(banco)
        val repo = Repositorio(dao, cardapio, sincronia)
        val caixa = RepositorioCaixa(dao, sincronia)
        val motor = MotorSincronizacao(banco, servidor)
        fun item(codigo: String) = cardapio.itens.first { it.codigo == codigo }
    }

    private fun ok(r: ResultadoOperacao) {
        if (r is ResultadoOperacao.Erro) fail(r.mensagem)
    }

    private val feijoada get() = "103"   // cozinha
    private val caipirinha get() = "188" // bar de drink

    @Before
    fun montar() {
        servidor = ServidorFalso()
    }

    @After
    fun desmontar() = bancos.forEach { it.close() }

    private suspend fun comandaComPedido(t: Terminal, numero: Int = 15): Long {
        ok(t.repo.abrirComanda(numero, "3", 2, null, false, "Beto"))
        val id = t.dao.comandasVivasAgora().single { it.numero == numero }.id
        ok(
            t.repo.lancarPedido(
                id,
                listOf(ItemEscolhido(t.item(feijoada), 2), ItemEscolhido(t.item(caipirinha), 1)),
                "Beto"
            )
        )
        return id
    }

    // ------------------------------------------------------------ envio

    @Test
    fun `abrir comanda e lancar pedido entram na fila na ordem certa`() = runBlocking {
        val a = Terminal()
        comandaComPedido(a)
        assertEquals(
            listOf(
                "inserir pdv_cards", "inserir pdv_card_orders",
                "inserir pdv_card_items", "inserir pdv_card_items",
                "atualizar pdv_cards"
            ),
            a.dao.todasOperacoes().map { "${it.tipo} ${it.tabela}" }
        )
    }

    @Test
    fun `envio sobe tudo e troca o codigo do ponto pelo id do servidor`() = runBlocking {
        val a = Terminal()
        comandaComPedido(a)
        assertTrue(a.motor.enviarPendentes())
        assertEquals(0, a.dao.operacoesPendentesAgora())
        assertEquals("15", servidor.linhas(Mapeamento.COMANDAS).single().texto("card_number"))
        val itens = servidor.linhas(Mapeamento.ITENS)
        assertEquals(2, itens.size)
        assertEquals(setOf("p-cozinha", "p-drink"), itens.map { it.texto("production_point_id") }.toSet())
        assertTrue(itens.none { it.containsKey(Mapeamento.CAMPO_CODIGO_PONTO) })
    }

    @Test
    fun `falha no meio para o envio sem pular nada e retoma depois`() = runBlocking {
        val a = Terminal()
        comandaComPedido(a)
        servidor.falharNaChamada = 3   // 1 comanda, 2 pedido, 3 primeiro item

        assertFalse(a.motor.enviarPendentes())
        val restantes = a.dao.todasOperacoes()
        assertEquals(3, restantes.size)
        assertTrue(restantes.first().ultimoErro!!.contains("falha simulada"))
        assertEquals(1, servidor.linhas(Mapeamento.COMANDAS).size)
        assertTrue(servidor.linhas(Mapeamento.ITENS).isEmpty())

        servidor.falharNaChamada = null
        assertTrue(a.motor.enviarPendentes())
        assertEquals(2, servidor.linhas(Mapeamento.ITENS).size)
    }

    @Test
    fun `enviar o mesmo registro duas vezes nao duplica no servidor`() = runBlocking {
        val a = Terminal()
        comandaComPedido(a)
        val primeira = a.dao.todasOperacoes().first()
        assertTrue(a.motor.enviarPendentes())
        a.dao.inserirOperacao(primeira.copy(id = 0))
        assertTrue(a.motor.enviarPendentes())
        assertEquals(1, servidor.linhas(Mapeamento.COMANDAS).size)
    }

    // --------------------------------------------------------- recepção

    @Test
    fun `outro terminal ve a comanda, os itens e o caixa, sem reimprimir`() = runBlocking {
        val a = Terminal()
        val b = Terminal()
        ok(a.caixa.abrirCaixa(10_000, "Beto"))
        val idA = comandaComPedido(a)
        assertTrue(a.motor.enviarPendentes())

        b.motor.receber()

        val naB = b.dao.comandasVivasAgora().single()
        assertEquals(15, naB.numero)
        assertEquals(2, b.dao.itensDaComandaAgora(naB.id).size)
        assertEquals(setOf("cozinha", "drink"), b.dao.itensDaComandaAgora(naB.id).map { it.pontoId }.toSet())
        assertEquals(a.repo.conta(idA)!!.totalCentavos, b.repo.conta(naB.id)!!.totalCentavos)
        assertNotNull(b.dao.sessaoAbertaAgora())
        assertTrue("pedido de outro terminal nao pode imprimir de novo", b.dao.impressoesPendentes().isEmpty())
        assertEquals(0, b.dao.operacoesPendentesAgora())
    }

    @Test
    fun `recebimento feito em B aparece como recebida em A`() = runBlocking {
        val a = Terminal()
        val b = Terminal()
        ok(a.caixa.abrirCaixa(10_000, "Beto"))
        val idA = comandaComPedido(a)
        assertTrue(a.motor.enviarPendentes())

        b.motor.receber()
        val idB = b.dao.comandasVivasAgora().single().id
        ok(b.repo.fecharComanda(idB, "Ana"))
        val falta = b.caixa.saldo(idB)!!.faltaCentavos
        ok(b.caixa.receber(idB, MetodoPagamento.DINHEIRO, falta, falta + 500, "Ana"))
        assertTrue(b.motor.enviarPendentes())

        a.motor.receber()
        assertEquals(StatusComanda.RECEBIDA, a.dao.comandaAgora(idA)!!.status)
        assertEquals(falta, a.dao.totalPagoDaComanda(idA))
        assertEquals(500L, a.dao.pagamentosDaComandaAgora(idA).single().trocoCentavos)
        // o dinheiro recebido em B entra na gaveta da sessão aberta em A
        assertEquals(10_000 + falta, a.caixa.apuracao()!!.esperadoEmDinheiroCentavos)
    }

    @Test
    fun `cancelamento feito em B chega em A`() = runBlocking {
        val a = Terminal()
        val b = Terminal()
        val idA = comandaComPedido(a)
        assertTrue(a.motor.enviarPendentes())

        b.motor.receber()
        val idB = b.dao.comandasVivasAgora().single().id
        val caipB = b.dao.itensDaComandaAgora(idB).single { it.pontoId == "drink" }
        ok(b.repo.cancelarItem(caipB.id, "cliente desistiu", "Ana"))
        assertTrue(b.motor.enviarPendentes())

        a.motor.receber()
        val ativosA = a.dao.itensDaComandaAgora(idA)
        assertEquals(1, ativosA.size)
        assertEquals("cozinha", ativosA.single().pontoId)
    }

    @Test
    fun `nao recebe do servidor enquanto ha envio pendente`() = runBlocking {
        val a = Terminal()
        val b = Terminal()
        comandaComPedido(a)
        assertTrue(a.motor.enviarPendentes())
        b.motor.receber()
        val idB = b.dao.comandasVivasAgora().single().id

        ok(b.repo.fecharComanda(idB, "Ana"))   // ainda não subiu
        b.motor.receber()                       // servidor ainda diz "aberta"

        assertEquals(StatusComanda.FECHADA, b.dao.comandaAgora(idB)!!.status)
    }

    @Test
    fun `caixa fechado em A aparece fechado em B`() = runBlocking {
        val a = Terminal()
        val b = Terminal()
        ok(a.caixa.abrirCaixa(5_000, "Beto"))
        assertTrue(a.motor.enviarPendentes())
        b.motor.receber()
        assertNotNull(b.dao.sessaoAbertaAgora())

        ok(a.caixa.fecharCaixa(5_000, "Beto", null))
        assertTrue(a.motor.enviarPendentes())
        b.motor.receber()
        assertNull(b.dao.sessaoAbertaAgora())
    }

    @Test
    fun `cardapio incompleto no servidor nao substitui o do aparelho`() = runBlocking {
        val a = Terminal()
        assertNull(a.motor.baixarCardapio(a.cardapio))
    }
}

/**
 * Servidor de mentira, em memória. Entende só os filtros que o motor usa
 * (eq, in, gte e "or"), dá carimbo de updated_at a cada gravação e repete a
 * trava de "dinheiro só com caixa aberto" do banco de verdade.
 */
class ServidorFalso : ClienteServidor {

    private val tabelas = mutableMapOf<String, LinkedHashMap<String, JsonObject>>()
    var falharNaChamada: Int? = null
    private var chamadas = 0
    private var relogio = 1_789_000_000_000L

    init {
        listOf("caixa", "cozinha", "drink", "cerveja").forEach { codigo ->
            tabela(Mapeamento.PONTOS)["p-$codigo"] = buildJsonObject {
                put("id", "p-$codigo")
                put("code", codigo)
            }
        }
    }

    private fun tabela(nome: String) = tabelas.getOrPut(nome) { LinkedHashMap() }
    fun linhas(nome: String): List<JsonObject> = tabela(nome).values.toList()

    private fun carimbo(): JsonPrimitive {
        relogio += 1_000
        return JsonPrimitive(DataIso.deMillis(relogio))
    }

    private fun contar() {
        chamadas++
        if (falharNaChamada == chamadas) throw ErroServidor("falha simulada", 503, true)
    }

    override suspend fun inserir(tabela: String, registro: JsonObject) {
        contar()
        if (tabela == Mapeamento.PAGAMENTOS || tabela == Mapeamento.MOVIMENTOS) {
            val sessao = tabela(Mapeamento.SESSOES)[registro.textoObrigatorio("session_id")]
            if (sessao?.texto("status") != "aberta") throw ErroServidor("caixa não está aberto", 400, false)
        }
        val id = registro.textoObrigatorio("id")
        val t = tabela(tabela)
        if (!t.containsKey(id)) t[id] = JsonObject(registro + ("updated_at" to carimbo()))
    }

    override suspend fun atualizar(tabela: String, id: String, campos: JsonObject) {
        contar()
        val t = tabela(tabela)
        val atual = t[id] ?: throw ErroServidor("registro $id não existe", 404, true)
        t[id] = JsonObject(atual + campos + ("updated_at" to carimbo()))
    }

    override suspend fun buscar(tabela: String, filtros: List<Pair<String, String>>): List<JsonObject> {
        var resultado = linhas(tabela)
        for ((chave, valor) in filtros) {
            resultado = when (chave) {
                "select", "order" -> resultado
                "or" -> resultado.filter { l -> dividir(valor).any { atende(l, it) } }
                else -> resultado.filter { l -> atende(l, "$chave.$valor") }
            }
        }
        return resultado
    }

    /** "(a.eq.1,b.in.(x,y))" -> ["a.eq.1", "b.in.(x,y)"] */
    private fun dividir(expressao: String): List<String> {
        val interno = expressao.removePrefix("(").removeSuffix(")")
        val partes = mutableListOf<String>()
        val atual = StringBuilder()
        var nivel = 0
        for (ch in interno) {
            when {
                ch == '(' -> { nivel++; atual.append(ch) }
                ch == ')' -> { nivel--; atual.append(ch) }
                ch == ',' && nivel == 0 -> { partes += atual.toString(); atual.clear() }
                else -> atual.append(ch)
            }
        }
        if (atual.isNotEmpty()) partes += atual.toString()
        return partes
    }

    private fun atende(linha: JsonObject, condicao: String): Boolean {
        val coluna = condicao.substringBefore('.')
        val resto = condicao.substringAfter('.')
        val operador = resto.substringBefore('.')
        val valor = resto.substringAfter('.')
        val atual = linha.texto(coluna)
        return when (operador) {
            "eq" -> atual == valor
            "in" -> atual != null && valor.removePrefix("(").removeSuffix(")").split(",").contains(atual)
            "gte" -> atual != null && DataIso.paraMillis(atual) >= DataIso.paraMillis(valor)
            else -> error("operador não suportado no servidor falso: $operador")
        }
    }
}
