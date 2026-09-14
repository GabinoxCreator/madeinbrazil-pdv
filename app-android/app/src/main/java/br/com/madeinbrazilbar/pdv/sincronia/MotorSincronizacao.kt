package br.com.madeinbrazilbar.pdv.sincronia

import androidx.room.withTransaction
import br.com.madeinbrazilbar.pdv.dados.BancoLocal
import br.com.madeinbrazilbar.pdv.dados.Cardapio
import br.com.madeinbrazilbar.pdv.dados.Categoria
import br.com.madeinbrazilbar.pdv.dados.ChaveValor
import br.com.madeinbrazilbar.pdv.dados.ItemCardapio
import br.com.madeinbrazilbar.pdv.dados.OperacaoSync
import br.com.madeinbrazilbar.pdv.dados.PontoProducao
import br.com.madeinbrazilbar.pdv.dados.TipoOperacao
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/** Situação da conversa com o servidor, pra mostrar na tela. */
data class EstadoSincronia(
    val habilitada: Boolean = false,
    val pendentes: Int = 0,
    val online: Boolean = false,
    val ultimoErro: String? = null,
    val ultimaSincronizacaoEm: Long? = null
)

/**
 * Motor de sincronização. Roda sozinho, em segundo plano, como a fila de
 * impressão:
 *
 *  1. ENVIA a fila do aparelho, em ordem. Para no primeiro erro e tenta de
 *     novo depois - nunca pula uma operação (em PDV, pular é perder dinheiro).
 *  2. RECEBE do servidor o que mudou, inclusive o que outros terminais
 *     fizeram, e grava no aparelho. Só recebe com a fila vazia, pra nunca
 *     sobrescrever algo daqui que ainda não subiu.
 *  3. De tempos em tempos BAIXA o cardápio do servidor.
 *
 * O garçom nunca espera o servidor: tudo que ele faz grava no aparelho na
 * hora. Sem internet, a fila só cresce e esvazia quando a rede voltar.
 */
class MotorSincronizacao(
    private val banco: BancoLocal,
    private val cliente: ClienteServidor,
    private val relogio: () -> Long = System::currentTimeMillis
) {
    private val dao = banco.dao()
    private val json = Json { ignoreUnknownKeys = true }

    private val _estado = MutableStateFlow(EstadoSincronia(habilitada = true))
    val estado: StateFlow<EstadoSincronia> = _estado.asStateFlow()

    private var pontoIdPorCodigo: Map<String, String> = emptyMap()
    private var pontoCodigoPorId: Map<String, String> = emptyMap()

    companion object {
        const val INTERVALO_MS = 3_000L
        const val INTERVALO_RECEBER_MS = 5_000L
        const val INTERVALO_CARDAPIO_MS = 10 * 60_000L
        const val ESPERA_MAXIMA_MS = 60_000L
        const val CURSOR_SESSOES = "cursor_sessoes"
        const val CURSOR_COMANDAS = "cursor_comandas"
        private const val TAMANHO_LOTE = 40
    }

    // ================================================================ laço

    fun iniciar(
        escopo: CoroutineScope,
        cardapioAtual: () -> Cardapio,
        aoBaixarCardapio: suspend (Cardapio) -> Unit
    ) {
        escopo.launch(Dispatchers.Default) {
            var ultimaRecepcao = 0L
            var ultimoCardapio = 0L
            var espera = INTERVALO_MS
            while (isActive) {
                val tudoEnviado = enviarPendentes()
                espera = if (!tudoEnviado) {
                    (espera * 2).coerceAtMost(ESPERA_MAXIMA_MS)
                } else try {
                    if (relogio() - ultimaRecepcao >= INTERVALO_RECEBER_MS) {
                        receber()
                        ultimaRecepcao = relogio()
                    }
                    if (relogio() - ultimoCardapio >= INTERVALO_CARDAPIO_MS) {
                        baixarCardapio(cardapioAtual())?.let { aoBaixarCardapio(it) }
                        ultimoCardapio = relogio()
                    }
                    INTERVALO_MS
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    registrarErro(e)
                    (espera * 2).coerceAtMost(ESPERA_MAXIMA_MS)
                }
                delay(espera)
            }
        }
    }

    private fun registrarErro(e: Exception) {
        _estado.update {
            it.copy(online = e is ErroServidor && e.status > 0, ultimoErro = e.message ?: e.javaClass.simpleName)
        }
    }

    // ================================================================ envio

    /** Envia a fila em ordem. Devolve true se esvaziou; false se parou num erro. */
    suspend fun enviarPendentes(): Boolean {
        while (true) {
            val op = dao.proximaOperacao() ?: return true
            try {
                enviar(op)
                dao.removerOperacao(op.id)
                _estado.update { it.copy(online = true, ultimoErro = null) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                dao.registrarFalhaOperacao(op.id, e.message ?: e.javaClass.simpleName, relogio())
                registrarErro(e)
                return false
            }
        }
    }

    private suspend fun enviar(op: OperacaoSync) {
        var registro = json.parseToJsonElement(op.payload).jsonObject
        val codigoPonto = registro.texto(Mapeamento.CAMPO_CODIGO_PONTO)
        if (codigoPonto != null) {
            carregarPontos()
            val idPonto = pontoIdPorCodigo[codigoPonto]
                ?: throw ErroServidor("Ponto de produção '$codigoPonto' não existe no servidor", 422, temporario = false)
            registro = JsonObject(
                registro.filterKeys { it != Mapeamento.CAMPO_CODIGO_PONTO } +
                    ("production_point_id" to JsonPrimitive(idPonto))
            )
        }
        when (op.tipo) {
            TipoOperacao.INSERIR -> cliente.inserir(op.tabela, registro)
            TipoOperacao.ATUALIZAR -> cliente.atualizar(op.tabela, op.registroUuid, registro)
            else -> throw ErroServidor("Tipo de operação desconhecido: ${op.tipo}", 422, temporario = false)
        }
    }

    private suspend fun carregarPontos() {
        if (pontoIdPorCodigo.isNotEmpty()) return
        val pontos = cliente.buscar(Mapeamento.PONTOS, listOf("select" to "id,code"))
        pontoIdPorCodigo = pontos.associate { it.textoObrigatorio("code") to it.textoObrigatorio("id") }
        pontoCodigoPorId = pontoIdPorCodigo.entries.associate { (codigo, id) -> id to codigo }
    }

    // ============================================================ recepção

    /**
     * Traz do servidor: o caixa aberto, as comandas vivas, tudo que mudou
     * desde a última vez e o estado atual das comandas que este aparelho
     * ainda considera vivas (pra saber se outro terminal fechou ou recebeu).
     */
    suspend fun receber() {
        if (dao.operacoesPendentesAgora() > 0) return
        carregarPontos()

        // ---- busca tudo primeiro (rede), grava depois (numa transação só)
        val sessaoLocalAberta = dao.sessaoAbertaAgora()?.uuid
        val cursorSessoes = dao.lerValor(CURSOR_SESSOES)
        val condicoesSessoes = mutableListOf("status.eq.aberta")
        cursorSessoes?.let { condicoesSessoes += "updated_at.gte.$it" }
        sessaoLocalAberta?.let { condicoesSessoes += "id.eq.$it" }
        val sessoes = cliente.buscar(
            Mapeamento.SESSOES,
            listOf("select" to "*", "or" to "(${condicoesSessoes.joinToString(",")})")
        )
        val movimentos = emLotes(Mapeamento.MOVIMENTOS, "session_id", sessoes.map { it.textoObrigatorio("id") })

        val comandasLocaisVivas = dao.comandasVivasAgora().map { it.uuid }
        val cursorComandas = dao.lerValor(CURSOR_COMANDAS)
        val condicoesComandas = mutableListOf("status.in.(aberta,fechada)")
        cursorComandas?.let { condicoesComandas += "updated_at.gte.$it" }
        val comandasPorFiltro = cliente.buscar(
            Mapeamento.COMANDAS,
            listOf("select" to "*", "or" to "(${condicoesComandas.joinToString(",")})")
        )
        val jaVieram = comandasPorFiltro.map { it.textoObrigatorio("id") }.toSet()
        val comandasConferidas = emLotes(Mapeamento.COMANDAS, "id", comandasLocaisVivas.filter { it !in jaVieram })
        val comandas = comandasPorFiltro + comandasConferidas

        val idsComandas = comandas.map { it.textoObrigatorio("id") }
        val pedidos = emLotes(Mapeamento.PEDIDOS, "card_id", idsComandas)
        val itens = emLotes(Mapeamento.ITENS, "card_id", idsComandas)
        val pagamentos = emLotes(Mapeamento.PAGAMENTOS, "card_id", idsComandas)

        val sessoesTrazidas = sessoes.map { it.textoObrigatorio("id") }.toSet()
        val sessoesCitadas = pagamentos.map { it.textoObrigatorio("session_id") }.distinct()
            .filter { it !in sessoesTrazidas && dao.sessaoPorUuid(it) == null }
        val sessoesExtras = emLotes(Mapeamento.SESSOES, "id", sessoesCitadas)

        banco.withTransaction {
            (sessoes + sessoesExtras).forEach { mesclarSessao(it) }
            movimentos.forEach { mesclarMovimento(it) }
            comandas.forEach { mesclarComanda(it) }
            pedidos.forEach { mesclarPedido(it) }
            itens.forEach { mesclarItem(it) }
            pagamentos.forEach { mesclarPagamento(it) }
            maisRecente(sessoes)?.let { dao.gravarValor(ChaveValor(CURSOR_SESSOES, it)) }
            maisRecente(comandasPorFiltro)?.let { dao.gravarValor(ChaveValor(CURSOR_COMANDAS, it)) }
        }
        _estado.update { it.copy(online = true, ultimoErro = null, ultimaSincronizacaoEm = relogio()) }
    }

    private suspend fun emLotes(tabela: String, coluna: String, ids: List<String>): List<JsonObject> =
        ids.distinct().chunked(TAMANHO_LOTE).flatMap { lote ->
            cliente.buscar(tabela, listOf("select" to "*", coluna to "in.(${lote.joinToString(",")})"))
        }

    private fun maisRecente(lista: List<JsonObject>): String? =
        lista.mapNotNull { it.texto("updated_at") }.maxByOrNull { DataIso.paraMillis(it) }

    /** Registro com envio pendente neste aparelho não é sobrescrito pelo servidor. */
    private suspend fun temEnvioPendente(uuid: String) = dao.operacoesDoRegistro(uuid) > 0

    private suspend fun mesclarSessao(j: JsonObject) {
        val uuid = j.textoObrigatorio("id")
        val local = dao.sessaoPorUuid(uuid)
        if (local != null && temEnvioPendente(uuid)) return
        val servidor = Mapeamento.paraSessao(j, local?.id ?: 0)
        if (local == null) dao.inserirSessao(servidor) else if (local != servidor) dao.atualizarSessao(servidor)
    }

    private suspend fun mesclarMovimento(j: JsonObject) {
        if (dao.movimentoPorUuid(j.textoObrigatorio("id")) != null) return
        val sessao = dao.sessaoPorUuid(j.textoObrigatorio("session_id")) ?: return
        dao.inserirMovimento(Mapeamento.paraMovimento(j, 0, sessao.id))
    }

    private suspend fun mesclarComanda(j: JsonObject) {
        val uuid = j.textoObrigatorio("id")
        val local = dao.comandaPorUuid(uuid)
        if (local != null && temEnvioPendente(uuid)) return
        val servidor = Mapeamento.paraComanda(j, local?.id ?: 0)
        if (local == null) dao.inserirComanda(servidor) else if (local != servidor) dao.atualizarComanda(servidor)
    }

    private suspend fun mesclarPedido(j: JsonObject) {
        if (dao.pedidoPorUuid(j.textoObrigatorio("id")) != null) return
        val comanda = dao.comandaPorUuid(j.textoObrigatorio("card_id")) ?: return
        // pedido de outro terminal entra só na conta: quem imprimiu foi quem lançou
        dao.inserirPedido(Mapeamento.paraPedido(j, 0, comanda.id))
    }

    private suspend fun mesclarItem(j: JsonObject) {
        val uuid = j.textoObrigatorio("id")
        val local = dao.itemPorUuid(uuid)
        if (local != null) {
            if (temEnvioPendente(uuid)) return
            val atualizado = local.copy(
                status = j.textoObrigatorio("status"),
                canceladoPor = j.texto("cancelled_by_name"),
                canceladoMotivo = j.texto("cancelled_reason"),
                canceladoEm = j.data("cancelled_at")
            )
            if (atualizado != local) dao.atualizarItem(atualizado)
            return
        }
        val pedido = dao.pedidoPorUuid(j.textoObrigatorio("order_id")) ?: return
        val comanda = dao.comandaPorUuid(j.textoObrigatorio("card_id")) ?: return
        val idPonto = j.texto("production_point_id")
        val codigo = idPonto?.let { pontoCodigoPorId[it] } ?: idPonto ?: ""
        dao.inserirItem(Mapeamento.paraItem(j, 0, pedido.id, comanda.id, codigo))
    }

    private suspend fun mesclarPagamento(j: JsonObject) {
        if (dao.pagamentoPorUuid(j.textoObrigatorio("id")) != null) return
        val comanda = dao.comandaPorUuid(j.textoObrigatorio("card_id")) ?: return
        val sessao = dao.sessaoPorUuid(j.textoObrigatorio("session_id")) ?: return
        dao.inserirPagamento(Mapeamento.paraPagamento(j, 0, comanda.id, sessao.id))
    }

    // ============================================================ cardápio

    /**
     * Baixa o cardápio do servidor no formato que o app já usa.
     * Nunca troca o cardápio por um vazio: se vier incompleto, devolve null.
     */
    suspend fun baixarCardapio(base: Cardapio): Cardapio? {
        val pontos = cliente.buscar(
            Mapeamento.PONTOS,
            listOf("select" to "id,code,name,printer_ip,printer_port", "is_active" to "eq.true")
        )
        val categorias = cliente.buscar(
            Mapeamento.CATEGORIAS,
            listOf("select" to "id,slug,name,sort_order", "is_active" to "eq.true", "order" to "sort_order")
        )
        val itens = cliente.buscar(
            Mapeamento.CARDAPIO,
            listOf(
                "select" to "id,category_id,name,short_code,price_cents,production_point_id,sort_order",
                "is_active" to "eq.true",
                "order" to "sort_order"
            )
        )
        if (pontos.isEmpty() || categorias.isEmpty() || itens.isEmpty()) return null

        val slugPorId = categorias.associate { it.textoObrigatorio("id") to it.textoObrigatorio("slug") }
        val codigoPorId = pontos.associate { it.textoObrigatorio("id") to it.textoObrigatorio("code") }

        return base.copy(
            aviso = "Cardápio baixado do servidor do PDV",
            pontosProducao = pontos.map {
                PontoProducao(
                    id = it.textoObrigatorio("code"),
                    nome = it.textoObrigatorio("name"),
                    ip = it.textoObrigatorio("printer_ip").substringBefore('/'),
                    porta = it.inteiro("printer_port")?.toInt() ?: 9100,
                    ipConfirmado = true
                )
            },
            categorias = categorias.map {
                Categoria(
                    slug = it.textoObrigatorio("slug"),
                    nome = it.textoObrigatorio("name"),
                    ordem = it.inteiro("sort_order")?.toInt() ?: 0
                )
            },
            itens = itens.mapNotNull { i ->
                val slug = slugPorId[i.textoObrigatorio("category_id")] ?: return@mapNotNull null
                val codigoPonto = codigoPorId[i.textoObrigatorio("production_point_id")] ?: return@mapNotNull null
                ItemCardapio(
                    id = i.textoObrigatorio("id"),
                    categoria = slug,
                    nome = i.textoObrigatorio("name"),
                    preco = (i.inteiro("price_cents") ?: 0L) / 100.0,
                    ponto = codigoPonto,
                    pontoConfirmado = true,
                    codigo = i.texto("short_code") ?: "",
                    ordem = i.inteiro("sort_order")?.toInt() ?: 0
                )
            }
        )
    }
}
