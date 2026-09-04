package br.com.madeinbrazilbar.pdv.dados

/**
 * Apuracao do caixa. Ponto UNICO da conferencia de fechamento.
 *
 * Regra do dinheiro na gaveta:
 *   esperado = fundo de troco + suprimentos - sangrias + recebimentos em dinheiro
 *
 * O troco NAO entra na conta: `valorCentavos` do pagamento ja e o que fica na
 * gaveta. Cliente paga conta de 50 com nota de 100 -> valor 50, troco 50,
 * gaveta cresce 50. Somar o troco inflaria o esperado e criaria diferenca
 * falsa todo dia.
 */
data class Fechamento(
    val fundoTrocoCentavos: Long,
    val suprimentosCentavos: Long,
    val sangriasCentavos: Long,
    val dinheiroRecebidoCentavos: Long,
    /** Quanto DEVE ter na gaveta. */
    val esperadoEmDinheiroCentavos: Long,
    val contadoCentavos: Long?,
    /** contado - esperado. Negativo = falta dinheiro. Nulo enquanto nao contou. */
    val diferencaCentavos: Long?,
    /** Recebido por forma de pagamento, para conferir com a maquininha. */
    val porMetodo: Map<String, Long>,
    val totalRecebidoCentavos: Long,
    val comandasRecebidas: Int
) {
    companion object {
        fun calcular(
            sessao: SessaoCaixa,
            movimentos: List<MovimentoCaixa>,
            pagamentos: List<Pagamento>,
            contadoCentavos: Long? = sessao.contadoCentavos
        ): Fechamento {
            val suprimentos = movimentos
                .filter { it.tipo == TipoMovimento.SUPRIMENTO }.sumOf { it.valorCentavos }
            val sangrias = movimentos
                .filter { it.tipo == TipoMovimento.SANGRIA }.sumOf { it.valorCentavos }

            val porMetodo = pagamentos
                .groupBy { it.metodo }
                .mapValues { (_, ps) -> ps.sumOf { it.valorCentavos } }

            val dinheiro = porMetodo[MetodoPagamento.DINHEIRO] ?: 0L
            val esperado = sessao.fundoTrocoCentavos + suprimentos - sangrias + dinheiro

            return Fechamento(
                fundoTrocoCentavos = sessao.fundoTrocoCentavos,
                suprimentosCentavos = suprimentos,
                sangriasCentavos = sangrias,
                dinheiroRecebidoCentavos = dinheiro,
                esperadoEmDinheiroCentavos = esperado,
                contadoCentavos = contadoCentavos,
                diferencaCentavos = contadoCentavos?.let { it - esperado },
                porMetodo = porMetodo,
                totalRecebidoCentavos = pagamentos.sumOf { it.valorCentavos },
                comandasRecebidas = pagamentos.map { it.comandaId }.distinct().size
            )
        }
    }
}

/** Situacao de pagamento de uma comanda. */
data class SaldoComanda(
    val totalCentavos: Long,
    val pagoCentavos: Long
) {
    val faltaCentavos: Long get() = (totalCentavos - pagoCentavos).coerceAtLeast(0)
    val quitada: Boolean get() = pagoCentavos >= totalCentavos && totalCentavos > 0
}
