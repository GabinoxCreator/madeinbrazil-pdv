package br.com.madeinbrazilbar.pdv.dados

import br.com.madeinbrazilbar.pdv.impressao.Cupons
import kotlinx.coroutines.flow.Flow

/** Um item escolhido no cardapio, antes de virar lancamento. */
data class ItemEscolhido(
    val item: ItemCardapio,
    val quantidade: Int,
    val observacao: String? = null
)

sealed class ResultadoOperacao {
    data class Ok(val mensagem: String) : ResultadoOperacao()
    data class Erro(val mensagem: String) : ResultadoOperacao()
}

/**
 * Regras da operacao de comanda.
 *
 * Enquanto nao existe servidor, as guardas de negocio vivem aqui. Quando as
 * Edge Functions do PDV existirem, esta classe passa a chamar o servidor e
 * as guardas passam a ser validadas dos dois lados.
 */
class Repositorio(
    private val dao: PdvDao,
    val cardapio: Cardapio
) {

    fun comandasVivas(): Flow<List<Comanda>> = dao.comandasVivas()
    fun comanda(id: Long): Flow<Comanda?> = dao.comanda(id)
    fun itensDaComanda(id: Long): Flow<List<ItemLancado>> = dao.itensDaComanda(id)

    // ---------------------------------------------------------------- abrir

    suspend fun abrirComanda(
        numero: Int,
        mesa: String?,
        pessoas: Int,
        cliente: String?,
        controle: Boolean,
        operador: String
    ): ResultadoOperacao {
        if (numero < Configuracao.COMANDA_NUMERO_MIN || numero > Configuracao.COMANDA_NUMERO_MAX) {
            return ResultadoOperacao.Erro(
                "Comanda $numero está fora da faixa configurada " +
                    "(${Configuracao.COMANDA_NUMERO_MIN} a ${Configuracao.COMANDA_NUMERO_MAX}). " +
                    "Se esse número existe de verdade, avise — a faixa é configurável."
            )
        }
        dao.comandaVivaComNumero(numero)?.let {
            return ResultadoOperacao.Erro("A comanda $numero já está aberta")
        }
        val agora = System.currentTimeMillis()
        dao.inserirComanda(
            Comanda(
                numero = numero,
                mesa = mesa?.takeIf { it.isNotBlank() },
                pessoas = pessoas.coerceAtLeast(1),
                cliente = cliente?.takeIf { it.isNotBlank() },
                controle = controle,
                taxaServicoPct = if (controle) 0.0 else Configuracao.TAXA_SERVICO_PCT,
                abertaPor = operador,
                abertaEm = agora,
                ultimaAtividadePor = operador,
                ultimaAtividadeEm = agora
            )
        )
        return ResultadoOperacao.Ok("Comanda $numero aberta")
    }

    // -------------------------------------------------------------- lancar

    /**
     * Lanca os itens e manda imprimir em cada ponto de producao envolvido.
     *
     * O lancamento e gravado ANTES de imprimir, de proposito: se a impressora
     * estiver offline, o consumo ja esta na conta e o cupom pode ser
     * reimpresso. O contrario - imprimir e falhar ao gravar - deixaria comida
     * saindo sem estar na conta de ninguem.
     */
    suspend fun lancarPedido(
        comandaId: Long,
        escolhidos: List<ItemEscolhido>,
        operador: String
    ): ResultadoOperacao {
        if (escolhidos.isEmpty()) return ResultadoOperacao.Erro("Nenhum item escolhido")

        val comanda = dao.comandaAgora(comandaId)
            ?: return ResultadoOperacao.Erro("Comanda não encontrada")
        if (comanda.status != StatusComanda.ABERTA) {
            return ResultadoOperacao.Erro("Comanda ${comanda.numero} está ${comanda.status}, não aceita lançamento")
        }

        val agora = System.currentTimeMillis()
        val pedidoId = dao.lancarPedido(
            Pedido(comandaId = comandaId, mesa = comanda.mesa, criadoPor = operador, criadoEm = agora)
        ) { novoId ->
            escolhidos.map { e ->
                ItemLancado(
                    pedidoId = novoId,
                    comandaId = comandaId,
                    itemCardapioId = e.item.id,
                    nome = e.item.nome,
                    quantidade = e.quantidade,
                    precoUnitCentavos = e.item.precoCentavos,
                    pontoId = e.item.ponto,
                    observacao = e.observacao
                )
            }
        }

        enfileirarPedido(pedidoId, comanda, operador, agora)
        return ResultadoOperacao.Ok("Pedido enviado para produção")
    }

    /**
     * Agrupa os itens por ponto de producao e enfileira um cupom para cada.
     * Nao espera a impressora: quem imprime e a FilaImpressao, em segundo plano.
     */
    private suspend fun enfileirarPedido(
        pedidoId: Long,
        comanda: Comanda,
        operador: String,
        quando: Long
    ) {
        val itens = dao.itensDoPedido(pedidoId)
        for ((pontoId, doPonto) in itens.groupBy { it.pontoId }) {
            val nomePonto = cardapio.ponto(pontoId)?.nome ?: pontoId
            val cupom = Cupons.pedidoProducao(nomePonto, comanda, doPonto, operador, quando)
            dao.enfileirar(
                TrabalhoImpressao(
                    pontoId = pontoId,
                    tipo = TipoImpressao.PEDIDO,
                    conteudo = cupom.bytes(),
                    previa = cupom.textoDaPrevia(),
                    comandaId = comanda.id,
                    pedidoId = pedidoId,
                    descricao = "Comanda ${comanda.numero} · $nomePonto · ${doPonto.sumOf { it.quantidade }} item(ns)",
                    criadoEm = quando
                )
            )
        }
    }

    fun historicoImpressao(): Flow<List<TrabalhoImpressao>> = dao.historicoImpressao()
    fun impressoesEmAberto(): Flow<Int> = dao.impressoesEmAberto()
    suspend fun reimprimir(id: Long): ResultadoOperacao {
        dao.reenfileirar(id)
        return ResultadoOperacao.Ok("Reenviado para a fila")
    }

    // ------------------------------------------------------------ cancelar

    suspend fun cancelarItem(itemId: Long, motivo: String, operador: String): ResultadoOperacao {
        if (motivo.isBlank()) return ResultadoOperacao.Erro("Informe o motivo do cancelamento")
        dao.cancelarItem(itemId, operador, motivo, System.currentTimeMillis())
        return ResultadoOperacao.Ok("Item cancelado")
    }

    // --------------------------------------------------------------- conta

    suspend fun conta(comandaId: Long): Conta? {
        val comanda = dao.comandaAgora(comandaId) ?: return null
        val itens = dao.itensDaComandaAgora(comandaId)
        return Conta.calcular(itens, comanda.taxaServicoPct, comanda.descontoCentavos, comanda.pessoas)
    }

    suspend fun ajustarConta(
        comandaId: Long,
        pessoas: Int,
        cobrarServico: Boolean,
        descontoCentavos: Long
    ): ResultadoOperacao {
        val comanda = dao.comandaAgora(comandaId)
            ?: return ResultadoOperacao.Erro("Comanda não encontrada")
        dao.atualizarComanda(
            comanda.copy(
                pessoas = pessoas.coerceAtLeast(1),
                taxaServicoPct = if (cobrarServico) Configuracao.TAXA_SERVICO_PCT else 0.0,
                descontoCentavos = descontoCentavos.coerceAtLeast(0)
            )
        )
        return ResultadoOperacao.Ok("Conta atualizada")
    }

    suspend fun fecharComanda(comandaId: Long, operador: String): ResultadoOperacao {
        val comanda = dao.comandaAgora(comandaId)
            ?: return ResultadoOperacao.Erro("Comanda não encontrada")
        if (comanda.status != StatusComanda.ABERTA) {
            return ResultadoOperacao.Erro("Comanda ${comanda.numero} já está ${comanda.status}")
        }
        val agora = System.currentTimeMillis()
        dao.atualizarComanda(
            comanda.copy(
                status = StatusComanda.FECHADA,
                fechadaEm = agora,
                ultimaAtividadePor = operador,
                ultimaAtividadeEm = agora
            )
        )
        return ResultadoOperacao.Ok("Comanda ${comanda.numero} fechada")
    }

    suspend fun reabrirComanda(comandaId: Long, operador: String): ResultadoOperacao {
        val comanda = dao.comandaAgora(comandaId)
            ?: return ResultadoOperacao.Erro("Comanda não encontrada")
        if (comanda.status != StatusComanda.FECHADA) {
            return ResultadoOperacao.Erro("Só dá para reabrir comanda fechada")
        }
        dao.atualizarComanda(
            comanda.copy(
                status = StatusComanda.ABERTA,
                fechadaEm = null,
                ultimaAtividadePor = operador,
                ultimaAtividadeEm = System.currentTimeMillis()
            )
        )
        return ResultadoOperacao.Ok("Comanda ${comanda.numero} reaberta")
    }

    // ---------------------------------------------------------- conferencia

    /** Monta o cupom de conferencia. Devolve o texto da previa e os bytes. */
    suspend fun montarConferencia(comandaId: Long): Pair<String, ByteArray>? {
        val comanda = dao.comandaAgora(comandaId) ?: return null
        val itens = dao.itensDaComandaAgora(comandaId)
        val conta = Conta.calcular(itens, comanda.taxaServicoPct, comanda.descontoCentavos, comanda.pessoas)
        val cupom = Cupons.conferenciaConta(comanda, itens, conta, System.currentTimeMillis())
        return cupom.textoDaPrevia() to cupom.bytes()
    }

    suspend fun imprimirConferencia(comandaId: Long): ResultadoOperacao {
        val comanda = dao.comandaAgora(comandaId)
            ?: return ResultadoOperacao.Erro("Comanda não encontrada")
        val itens = dao.itensDaComandaAgora(comandaId)
        val conta = Conta.calcular(itens, comanda.taxaServicoPct, comanda.descontoCentavos, comanda.pessoas)
        val agora = System.currentTimeMillis()
        val cupom = Cupons.conferenciaConta(comanda, itens, conta, agora)
        dao.enfileirar(
            TrabalhoImpressao(
                pontoId = "caixa",
                tipo = TipoImpressao.CONFERENCIA,
                conteudo = cupom.bytes(),
                previa = cupom.textoDaPrevia(),
                comandaId = comanda.id,
                descricao = "Conferência · comanda ${comanda.numero}",
                criadoEm = agora
            )
        )
        return ResultadoOperacao.Ok("Conferência enviada para o caixa")
    }
}
