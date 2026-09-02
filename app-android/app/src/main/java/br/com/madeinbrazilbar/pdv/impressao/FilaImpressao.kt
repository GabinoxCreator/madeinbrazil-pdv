package br.com.madeinbrazilbar.pdv.impressao

import br.com.madeinbrazilbar.pdv.dados.Cardapio
import br.com.madeinbrazilbar.pdv.dados.Configuracao
import br.com.madeinbrazilbar.pdv.dados.PdvDao
import br.com.madeinbrazilbar.pdv.dados.StatusImpressao
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
    private val cardapio: Cardapio,
    private val escopo: CoroutineScope
) {

    private companion object {
        const val INTERVALO_OCIOSO_MS = 3_000L
        const val INTERVALO_TRABALHANDO_MS = 400L
    }

    fun iniciar() {
        escopo.launch {
            while (isActive) {
                val pendentes = try {
                    dao.impressoesPendentes()
                } catch (e: Exception) {
                    emptyList()
                }
                if (pendentes.isEmpty()) {
                    delay(INTERVALO_OCIOSO_MS)
                } else {
                    pendentes.forEach { processar(it) }
                    delay(INTERVALO_TRABALHANDO_MS)
                }
            }
        }
    }

    private suspend fun processar(t: br.com.madeinbrazilbar.pdv.dados.TrabalhoImpressao) {
        val ponto = cardapio.ponto(t.pontoId)
        val tentativas = t.tentativas + 1

        if (ponto == null) {
            dao.atualizarImpressao(
                t.id, StatusImpressao.FALHA, tentativas,
                "Ponto de produção desconhecido: ${t.pontoId}", null
            )
            return
        }

        when (val r = Impressora.imprimir(ponto.ip, t.conteudo, ponto.porta)) {
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
