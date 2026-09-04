package br.com.madeinbrazilbar.pdv.dados

/**
 * Parametros da operacao. A especificacao e explicita: nada de numero magico
 * espalhado pelo codigo. Hoje moram aqui; quando o banco do PDV existir,
 * viram linhas de pdv_settings e este objeto passa a ser so o valor padrao.
 */
object Configuracao {

    /** Percentual de servico. Confirmado com a operacao (Aurimar, 03/09/2026). */
    const val TAXA_SERVICO_PCT: Double = 10.0

    /**
     * Faixa aceita de numero de comanda.
     *
     * Valor informado pela operacao (Aurimar, 03/09/2026): de 0 a 100.
     *
     * ATENCAO - CONFLITO CONHECIDO: o levantamento de campo de 31/08/2026
     * registrou comandas com numeros 124, 1959, 2000 e 2001 em uso no TOTVS.
     * Com o teto em 100, essas comandas seriam RECUSADAS na abertura.
     * Se aparecer recusa em servico, subir o teto aqui resolve na hora.
     * [A CONFIRMAR] se aqueles numeros altos eram comanda mesmo ou outro
     * identificador do sistema antigo.
     */
    const val COMANDA_NUMERO_MIN: Int = 0
    const val COMANDA_NUMERO_MAX: Int = 100

    const val CABECALHO_CUPOM: String = "MADE IN BRAZIL BAR"
    const val RODAPE_CUPOM: String = "NÃO É DOCUMENTO FISCAL"

    const val IMPRESSAO_TENTATIVAS: Int = 3
}
