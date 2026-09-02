package br.com.madeinbrazilbar.pdv.impressao

import br.com.madeinbrazilbar.pdv.dados.Comanda
import br.com.madeinbrazilbar.pdv.dados.Configuracao
import br.com.madeinbrazilbar.pdv.dados.Conta
import br.com.madeinbrazilbar.pdv.dados.Dinheiro
import br.com.madeinbrazilbar.pdv.dados.ItemLancado
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Modelos de cupom. Cada funcao devolve um EscPos montado - de onde saem
 * tanto os bytes para a termica quanto a previa em texto para a tela.
 */
object Cupons {

    private val horario = SimpleDateFormat("dd/MM/yyyy HH:mm", Locale("pt", "BR"))

    /**
     * Pedido de producao: o que a cozinha ou o bar recebe.
     * Sem preco de proposito - quem produz nao precisa de valor, e valor no
     * papel da producao so gera confusao no balcao.
     */
    fun pedidoProducao(
        pontoNome: String,
        comanda: Comanda,
        itens: List<ItemLancado>,
        operador: String,
        quando: Long
    ): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .dobrado(true).negrito(true)
        .linha(pontoNome.uppercase())
        .dobrado(false).negrito(false)
        .separador('=')
        .aEsquerda()
        .apply {
            dobrado(true).negrito(true)
            linha("COMANDA ${comanda.numero}")
            dobrado(false).negrito(false)
            comanda.mesa?.let { colunas("Mesa", it) }
            colunas("Atendente", operador)
            colunas("Hora", horario.format(Date(quando)))
            separador()
            for (item in itens) {
                negrito(true)
                colunas("${item.quantidade}x ${item.nome}", "")
                negrito(false)
                item.observacao?.takeIf { it.isNotBlank() }?.let {
                    paragrafo("obs: $it", recuo = "   ")
                }
            }
            separador()
        }
        .avancar(3)
        .cortar()

    /**
     * Conferencia da conta: o que o cliente le antes de pagar.
     * Nao e documento fiscal - o modulo fiscal esta fora desta versao.
     */
    fun conferenciaConta(
        comanda: Comanda,
        itens: List<ItemLancado>,
        conta: Conta,
        quando: Long
    ): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .dobrado(true).negrito(true)
        .linha(Configuracao.CABECALHO_CUPOM)
        .dobrado(false).negrito(false)
        .linha("CONFERÊNCIA DE CONSUMO")
        .separador('=')
        .aEsquerda()
        .apply {
            colunas("Comanda", comanda.numero.toString())
            comanda.mesa?.let { colunas("Mesa", it) }
            colunas("Pessoas", conta.pessoas.toString())
            colunas("Hora", horario.format(Date(quando)))
            separador()

            for (item in itens) {
                colunas(
                    "${item.quantidade}x ${item.nome}",
                    Dinheiro.formatar(item.totalCentavos)
                )
                if (item.quantidade > 1) {
                    linha("     ${Dinheiro.formatar(item.precoUnitCentavos)} cada")
                }
            }

            separador()
            colunas("Subtotal", Dinheiro.formatar(conta.subtotalCentavos))
            if (conta.servicoCentavos > 0) {
                colunas(
                    "Serviço (${conta.taxaServicoPct.toInt()}%)",
                    Dinheiro.formatar(conta.servicoCentavos)
                )
            }
            if (conta.descontoCentavos > 0) {
                colunas("Desconto", "-" + Dinheiro.formatar(conta.descontoCentavos))
            }
            separador('=')
            negrito(true)
            dobrado(true)
            colunas("TOTAL", Dinheiro.formatar(conta.totalCentavos))
            dobrado(false)
            negrito(false)
            if (conta.pessoas > 1) {
                colunas("Por pessoa (${conta.pessoas})", Dinheiro.formatar(conta.porPessoaCentavos))
            }
            linha()
            centralizado()
            negrito(true)
            linha(Configuracao.RODAPE_CUPOM)
            negrito(false)
        }
        .avancar(3)
        .cortar()

    /** Mensagem avulsa para um ponto de producao. */
    fun mensagem(pontoNome: String, texto: String, de: String, quando: Long): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .negrito(true).linha("RECADO").negrito(false)
        .linha(pontoNome)
        .separador('=')
        .aEsquerda()
        .paragrafo(texto)
        .separador()
        .colunas("De", de)
        .colunas("Hora", horario.format(Date(quando)))
        .avancar(3)
        .cortar()

    /** Cupom de diagnostico. O bloco de acentuacao e o ponto do teste. */
    fun teste(pontoDeProducao: String, ip: String): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .dobrado(true).negrito(true)
        .linha("MADE IN BRAZIL")
        .dobrado(false).negrito(false)
        .linha("TESTE DE IMPRESSÃO")
        .separador('=')
        .aEsquerda()
        .colunas("Ponto", pontoDeProducao)
        .colunas("Impressora", "$ip:${Impressora.PORTA_PADRAO}")
        .separador()
        .negrito(true).linha("TESTE DE ACENTUAÇÃO").negrito(false)
        .linha("Ação, coração, pão, açúcar")
        .linha("Feijoada · Filé · Tilápia")
        .linha("Strogonoff · Parmegiana")
        .linha("Guarnição · Porção · Limão")
        .separador()
        .linha("Se os acentos acima saíram certos,")
        .linha("a impressão do PDV está funcionando.")
        .linha()
        .negrito(true)
        .colunas("TOTAL", "R$ 26,90")
        .negrito(false)
        .linha()
        .centralizado()
        .linha(Configuracao.RODAPE_CUPOM)
        .avancar(3)
        .cortar()
}
