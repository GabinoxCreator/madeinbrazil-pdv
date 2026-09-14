package br.com.madeinbrazilbar.pdv.impressao

import br.com.madeinbrazilbar.pdv.dados.Cardapio
import br.com.madeinbrazilbar.pdv.dados.PdvDao
import br.com.madeinbrazilbar.pdv.dados.StatusImpressao
import br.com.madeinbrazilbar.pdv.dados.TipoImpressao
import br.com.madeinbrazilbar.pdv.dados.TrabalhoImpressao
import br.com.madeinbrazilbar.pdv.sincronia.ClienteServidor
import br.com.madeinbrazilbar.pdv.sincronia.texto
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * Avisa o servidor do resultado de um cupom do delivery (dlv_concluir_impressao).
 *
 * Quem chama é a FilaImpressao (quando o cupom sai ou esgota as tentativas) e
 * a estação (reenvio do que não chegou). Os dois caminhos podem cruzar: a
 * trava e a releitura da linha garantem um aviso só por resultado.
 */
class ConclusaoDelivery(
    private val dao: PdvDao,
    /** Cliente logado do motor; null enquanto o terminal não conectou. */
    private val cliente: () -> ClienteServidor?
) {
    private val trava = Mutex()

    /** Devolve true se o servidor ficou sabendo (agora ou antes). */
    suspend fun concluirSeFaltar(idLocal: Long): Boolean = trava.withLock {
        val t = dao.impressaoAgora(idLocal) ?: return@withLock false
        val trabalhoId = t.trabalhoDeliveryId ?: return@withLock false
        if (t.concluidoNoServidor) return@withLock true
        if (t.status != StatusImpressao.ENVIADO && t.status != StatusImpressao.FALHA) return@withLock false
        val c = cliente() ?: return@withLock false
        val ok = t.status == StatusImpressao.ENVIADO
        try {
            c.rpc(FUNCAO_CONCLUIR, argumentos(trabalhoId, ok, if (ok) null else t.ultimoErro ?: "falha na impressão"))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // sem rede: fica pro reenvio da estação, a fila não espera
            return@withLock false
        }
        dao.marcarConcluidoNoServidor(t.id)
        true
    }

    suspend fun reenviarPendentes() {
        val pendentes = try { dao.impressoesDeliverySemConclusao() } catch (e: Exception) { emptyList() }
        for (t in pendentes) {
            if (!concluirSeFaltar(t.id)) return   // servidor fora: tenta tudo na próxima rodada
        }
    }

    companion object {
        const val FUNCAO_RESERVAR = "dlv_reservar_impressoes"
        const val FUNCAO_CONCLUIR = "dlv_concluir_impressao"

        fun argumentos(trabalhoId: String, ok: Boolean, erro: String?): JsonObject = buildJsonObject {
            put("p_trabalho", trabalhoId)
            put("p_ok", ok)
            put("p_erro", erro?.let { JsonPrimitive(it) } ?: JsonNull)
        }
    }
}

/** Situação da estação, pra mostrar na tela do terminal. */
data class EstadoEstacao(
    val ultimaReservaEm: Long? = null,
    val ultimoErro: String? = null,
    val cuponsRecebidos: Int = 0
)

/**
 * Estação de impressão do delivery: puxa a fila do servidor e entrega cada
 * cupom pra FilaImpressao deste aparelho, que imprime como qualquer outro.
 *
 * A reserva no servidor é o sinal de vida da estação (o painel acusa "fora do
 * ar" depois de 90 s sem chamada), por isso a rodada roda a cada 5 s mesmo
 * sem trabalho.
 *
 * RISCO CONHECIDO: o laço vive no ViewModel. Se o app sair da tela por muito
 * tempo ou o Android matar o processo, a estação para e o painel acusa. Um
 * serviço em primeiro plano resolve, e fica para depois.
 */
class EstacaoDelivery(
    private val dao: PdvDao,
    private val cliente: ClienteServidor,
    private val conclusao: ConclusaoDelivery,
    /** O código do ponto no servidor é o id do ponto no cardápio do aparelho. */
    private val cardapioAtual: () -> Cardapio,
    private val relogio: () -> Long = System::currentTimeMillis,
    private val intervaloMs: Long = INTERVALO_MS
) {
    private val _estado = MutableStateFlow(EstadoEstacao())
    val estado: StateFlow<EstadoEstacao> = _estado.asStateFlow()

    companion object {
        const val INTERVALO_MS = 5_000L
        const val LIMITE_POR_RESERVA = 10
    }

    fun iniciar(escopo: CoroutineScope, ligada: () -> Boolean) {
        escopo.launch(Dispatchers.Default) {
            while (isActive) {
                if (ligada()) {
                    try {
                        rodada()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        _estado.value = _estado.value.copy(ultimoErro = e.message ?: e.javaClass.simpleName)
                    }
                }
                delay(intervaloMs)
            }
        }
    }

    /** Uma volta: reenvia o que o servidor não soube, reserva e enfileira. Devolve quantos cupons entraram. */
    suspend fun rodada(): Int {
        conclusao.reenviarPendentes()

        val resposta = try {
            cliente.rpc(ConclusaoDelivery.FUNCAO_RESERVAR, buildJsonObject { put("p_limite", LIMITE_POR_RESERVA) })
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _estado.value = _estado.value.copy(ultimoErro = e.message ?: e.javaClass.simpleName)
            return 0
        }

        var enfileirados = 0
        for (elemento in (resposta as? JsonArray).orEmpty()) {
            val j = elemento as? JsonObject ?: continue
            if (receber(j)) enfileirados++
        }
        _estado.value = _estado.value.copy(
            ultimaReservaEm = relogio(),
            ultimoErro = null,
            cuponsRecebidos = _estado.value.cuponsRecebidos + enfileirados
        )
        return enfileirados
    }

    /** Devolve true se virou cupom novo na fila. */
    private suspend fun receber(j: JsonObject): Boolean {
        val trabalhoId = j.texto("trabalho_id") ?: return false

        val existente = dao.impressaoDoDelivery(trabalhoId)
        if (existente != null) {
            when {
                // ainda na fila deste aparelho: o resultado sai de lá
                existente.status == StatusImpressao.PENDENTE -> Unit
                // o aviso não chegou (a reserva venceu antes): só reenvia
                !existente.concluidoNoServidor -> conclusao.concluirSeFaltar(existente.id)
                // o servidor já tinha o resultado e mandou de novo: é ele pedindo outra
                // tentativa (depois de falha) ou reimpressão. A mesma linha volta pra fila.
                else -> dao.reenfileirarDelivery(existente.id)
            }
            return false
        }

        val trabalho = try {
            TrabalhoDelivery.ler(j)
        } catch (e: Exception) {
            recusar(trabalhoId, "trabalho ilegível no aparelho: ${e.message}")
            return false
        }

        val ponto = cardapioAtual().ponto(trabalho.pontoCodigo)
        if (ponto == null) {
            recusar(trabalhoId, "ponto ${trabalho.pontoCodigo} desconhecido no aparelho")
            return false
        }
        val nomePonto = trabalho.pontoNome?.takeIf { it.isNotBlank() } ?: ponto.nome

        val (cupom, rotulo) = when (trabalho.tipo) {
            TipoTrabalhoDelivery.PRODUCAO -> Cupons.deliveryProducao(trabalho, nomePonto) to "Produção"
            TipoTrabalhoDelivery.VIA_ENTREGA -> Cupons.deliveryViaEntrega(trabalho) to "Via de entrega"
            TipoTrabalhoDelivery.CANCELAMENTO -> Cupons.deliveryCancelamento(trabalho, nomePonto) to "Cancelamento"
            else -> {
                recusar(trabalhoId, "tipo ${trabalho.tipo} desconhecido no aparelho")
                return false
            }
        }

        // IP e porta vêm só do cardápio do aparelho (pontoId = código): uma fonte só
        dao.enfileirar(
            TrabalhoImpressao(
                pontoId = trabalho.pontoCodigo,
                tipo = TipoImpressao.DELIVERY,
                conteudo = cupom.bytes(),
                previa = cupom.textoDaPrevia(),
                descricao = "Delivery #${trabalho.pedido.numero} · $rotulo · $nomePonto",
                criadoEm = relogio(),
                trabalhoDeliveryId = trabalhoId
            )
        )
        return true
    }

    /** Trabalho que este aparelho não consegue imprimir: devolve como falha. */
    private suspend fun recusar(trabalhoId: String, motivo: String) {
        try {
            cliente.rpc(ConclusaoDelivery.FUNCAO_CONCLUIR, ConclusaoDelivery.argumentos(trabalhoId, false, motivo))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // sem rede: a reserva vence em 2 min e o trabalho volta na próxima reserva
        }
    }
}
