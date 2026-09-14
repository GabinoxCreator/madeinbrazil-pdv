package br.com.madeinbrazilbar.pdv.impressao

import br.com.madeinbrazilbar.pdv.dados.Cardapio
import br.com.madeinbrazilbar.pdv.dados.Configuracao
import br.com.madeinbrazilbar.pdv.dados.PdvDao
import br.com.madeinbrazilbar.pdv.dados.PontoProducao
import br.com.madeinbrazilbar.pdv.dados.StatusImpressao
import br.com.madeinbrazilbar.pdv.sincronia.Mapeamento
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Motor de impressao. Roda sozinho, drena a fila e tenta de novo o que falhou.
 *
 * Regra: NADA imprime fora daqui. O lancamento so enfileira e volta na hora -
 * a tela nunca espera impressora. Isso veio de um teste real em que o app
 * ficava ~15s congelado quando as termicas estavam fora do ar.
 */
class FilaImpressao(
    private val dao: PdvDao,
    /** Lê o cardápio ATUAL a cada cupom: IP de térmica que mudou no servidor vale na hora. */
    private val cardapioAtual: () -> Cardapio,
    private val escopo: CoroutineScope,
    /** Quando existe, a situação de impressão de cada pedido sobe pro servidor. */
    private val sincronia: Sincronia? = null,
    /**
     * Quem manda os bytes pra térmica. Trocável só pra testar a fila sem
     * impressora de verdade na rede.
     */
    private val imprimir: suspend (PontoProducao, ByteArray) -> Impressora.Resultado =
        { ponto, bytes -> Impressora.imprimir(ponto.ip, bytes, ponto.porta) }
) {

    /** Cardápio fixo (quem não precisa acompanhar o servidor). */
    constructor(dao: PdvDao, cardapio: Cardapio, escopo: CoroutineScope, sincronia: Sincronia? = null) :
        this(dao, { cardapio }, escopo, sincronia)

    private companion object {
        const val INTERVALO_OCIOSO_MS = 3_000L
        const val INTERVALO_TRABALHANDO_MS = 400L
    }

    fun iniciar() {
        escopo.launch {
            while (isActive) {
                delay(if (processarPendentes()) INTERVALO_TRABALHANDO_MS else INTERVALO_OCIOSO_MS)
            }
        }
    }

    /** Uma rodada da fila. Devolve true se havia o que imprimir. */
    suspend fun processarPendentes(): Boolean {
        val pendentes = try {
            dao.impressoesPendentes()
        } catch (e: Exception) {
            emptyList()
        }
        if (pendentes.isEmpty()) return false
        pendentes.forEach { processar(it) }
        // cupom de pedido: vê se o pedido inteiro já tem resposta
        pendentes.mapNotNull { it.pedidoId }.distinct().forEach { atualizarImpressaoDoPedido(it) }
        return true
    }

    /**
     * Recalcula a situação de impressão do pedido a partir de TODOS os cupons
     * dele e, se mudou, grava no aparelho e manda pro servidor só o
     * print_status - é assim que o servidor fica sabendo de pedido que não
     * saiu na cozinha.
     *
     * Pedido que veio de outro terminal não tem cupom neste aparelho: fica
     * como veio, com a situação que o terminal que imprimiu mandou.
     */
    suspend fun atualizarImpressaoDoPedido(pedidoId: Long) {
        val novo = StatusImpressao.doPedido(dao.statusDosCuponsDoPedido(pedidoId)) ?: return
        val pedido = dao.pedido(pedidoId) ?: return
        if (pedido.statusImpressao == novo) return
        val atualizado = pedido.copy(statusImpressao = novo)
        val s = sincronia
        if (s == null) {
            dao.atualizarPedido(atualizado)
            return
        }
        // gravação local + registro de envio: ou as duas coisas, ou nenhuma
        s.emTransacao {
            dao.atualizarPedido(atualizado)
            s.atualizar(Mapeamento.PEDIDOS, atualizado.uuid, Mapeamento.impressaoDoPedido(atualizado))
        }
    }

    private suspend fun processar(t: br.com.madeinbrazilbar.pdv.dados.TrabalhoImpressao) {
        val ponto = cardapioAtual().ponto(t.pontoId)
        val tentativas = t.tentativas + 1

        if (ponto == null) {
            dao.atualizarImpressao(
                t.id, StatusImpressao.FALHA, tentativas,
                "Ponto de produção desconhecido: ${t.pontoId}", null
            )
            return
        }

        when (val r = imprimir(ponto, t.conteudo)) {
            is Impressora.Resultado.Ok ->
                dao.atualizarImpressao(
                    t.id, StatusImpressao.ENVIADO, tentativas, null, System.currentTimeMillis()
                )

            is Impressora.Resultado.Falha -> {
                // esgotou as tentativas: para de tentar e fica visivel para reimpressao manual
                val status = if (tentativas >= Configuracao.IMPRESSAO_TENTATIVAS)
                    StatusImpressao.FALHA else StatusImpressao.PENDENTE
                dao.atualizarImpressao(t.id, status, tentativas, r.motivo, null)
            }
        }
    }
}
