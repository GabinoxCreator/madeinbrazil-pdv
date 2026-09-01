package br.com.madeinbrazilbar.pdv.impressao

/**
 * Modelos de cupom. Por enquanto so o de teste - os de pedido de producao e
 * conferencia de conta entram quando o fluxo de comanda existir.
 */
object Cupons {

    /**
     * Cupom de diagnostico. O bloco de acentuacao e o ponto do teste:
     * se sair legivel, o PC860 esta certo e o cardapio vai imprimir direito.
     */
    fun teste(pontoDeProducao: String, ip: String): ByteArray = EscPos()
        .inicializar()
        .centralizado()
        .dobrado(true).negrito(true)
        .linha("MADE IN BRAZIL")
        .dobrado(false).negrito(false)
        .linha("TESTE DE IMPRESSAO")
        .separador('=')
        .aEsquerda()
        .colunas("Ponto", pontoDeProducao)
        .colunas("Impressora", "$ip:${Impressora.PORTA_PADRAO}")
        .separador()
        .negrito(true).linha("TESTE DE ACENTUACAO").negrito(false)
        .linha("Ação, coração, pão, açúcar")
        .linha("Feijoada · Filé · Tilápia")
        .linha("Strogonoff · Parmegiana")
        .linha("Guarnição · Porção · Limão")
        .separador()
        .linha("Se os acentos acima sairam certos,")
        .linha("a impressao do PDV esta funcionando.")
        .linha()
        .negrito(true)
        .colunas("TOTAL", "R$ 26,90")
        .negrito(false)
        .linha()
        .centralizado()
        .linha("NAO E DOCUMENTO FISCAL")
        .avancar(3)
        .cortar()
        .bytes()
}
