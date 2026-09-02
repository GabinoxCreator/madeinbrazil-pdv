package br.com.madeinbrazilbar.pdv.dados

/**
 * Parametros da operacao. A especificacao e explicita: nada de numero magico
 * espalhado pelo codigo. Hoje moram aqui; quando o banco do PDV existir,
 * viram linhas de pdv_settings e este objeto passa a ser so o valor padrao.
 */
object Configuracao {

    /** Percentual de servico observado no cupom da operacao atual. */
    const val TAXA_SERVICO_PCT: Double = 10.0

    /**
     * Faixa aceita de numero de comanda. Larga de proposito: a operacao usa
     * numeros de faixas diferentes ao mesmo tempo (70, 124, 1959, 2000, 2001).
     * Apertar so depois de confirmar a faixa real com a operacao.
     */
    const val COMANDA_NUMERO_MIN: Int = 1
    const val COMANDA_NUMERO_MAX: Int = 9999

    const val CABECALHO_CUPOM: String = "MADE IN BRAZIL BAR"
    const val RODAPE_CUPOM: String = "NÃO É DOCUMENTO FISCAL"

    const val IMPRESSAO_TENTATIVAS: Int = 3
}
