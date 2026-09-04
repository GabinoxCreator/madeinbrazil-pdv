package br.com.madeinbrazilbar.pdv.impressao

import br.com.madeinbrazilbar.pdv.dados.Comanda
import br.com.madeinbrazilbar.pdv.dados.Configuracao
import br.com.madeinbrazilbar.pdv.dados.Conta
import br.com.madeinbrazilbar.pdv.dados.Dinheiro
import br.com.madeinbrazilbar.pdv.dados.Fechamento
import br.com.madeinbrazilbar.pdv.dados.ItemLancado
import br.com.madeinbrazilbar.pdv.dados.MetodoPagamento
import br.com.madeinbrazilbar.pdv.dados.Pagamento
import br.com.madeinbrazilbar.pdv.dados.SaldoComanda
import br.com.madeinbrazilbar.pdv.dados.SessaoCaixa
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

    /**
     * Cupom de fechamento de caixa: a conferencia que o operador confere
     * contra a gaveta e contra o extrato da maquininha.
     */
    fun fechamentoCaixa(
        sessao: SessaoCaixa,
        f: Fechamento,
        operador: String,
        quando: Long
    ): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .dobrado(true).negrito(true)
        .linha(Configuracao.CABECALHO_CUPOM)
        .dobrado(false).negrito(false)
        .linha("FECHAMENTO DE CAIXA")
        .separador('=')
        .aEsquerda()
        .apply {
            colunas("Abertura", horario.format(Date(sessao.abertaEm)))
            colunas("Aberto por", sessao.abertaPor)
            colunas("Fechamento", horario.format(Date(quando)))
            colunas("Fechado por", operador)
            separador()

            negrito(true).linha("RECEBIDO POR FORMA").negrito(false)
            for (metodo in MetodoPagamento.TODOS) {
                val v = f.porMetodo[metodo] ?: 0L
                if (v > 0) colunas("  " + MetodoPagamento.rotulo(metodo), Dinheiro.formatar(v))
            }
            separador()
            colunas("Total recebido", Dinheiro.formatar(f.totalRecebidoCentavos))
            colunas("Comandas recebidas", f.comandasRecebidas.toString())
            separador()

            negrito(true).linha("DINHEIRO NA GAVETA").negrito(false)
            colunas("  Fundo de troco", Dinheiro.formatar(f.fundoTrocoCentavos))
            if (f.suprimentosCentavos > 0)
                colunas("  Suprimentos", Dinheiro.formatar(f.suprimentosCentavos))
            if (f.sangriasCentavos > 0)
                colunas("  Sangrias", "-" + Dinheiro.formatar(f.sangriasCentavos))
            colunas("  Recebido em dinheiro", Dinheiro.formatar(f.dinheiroRecebidoCentavos))
            separador()
            negrito(true)
            colunas("ESPERADO", Dinheiro.formatar(f.esperadoEmDinheiroCentavos))
            negrito(false)
            f.contadoCentavos?.let { colunas("CONTADO", Dinheiro.formatar(it)) }
            f.diferencaCentavos?.let { d ->
                separador('=')
                negrito(true)
                val rotulo = when {
                    d == 0L -> "SEM DIFERENCA"
                    d > 0 -> "SOBRA"
                    else -> "FALTA"
                }
                colunas(rotulo, Dinheiro.formatar(if (d < 0) -d else d))
                negrito(false)
            }
            sessao.observacao?.takeIf { it.isNotBlank() }?.let {
                separador()
                paragrafo("Obs: $it")
            }
            linha()
            linha("Conferido por: ____________________")
            linha()
            centralizado()
            linha(Configuracao.RODAPE_CUPOM)
        }
        .avancar(3)
        .cortar()

    /** Comprovante de recebimento entregue ao cliente. */
    fun comprovanteRecebimento(
        comanda: Comanda,
        pagamento: Pagamento,
        saldo: SaldoComanda,
        quando: Long
    ): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .negrito(true).linha(Configuracao.CABECALHO_CUPOM).negrito(false)
        .linha("COMPROVANTE DE PAGAMENTO")
        .separador('=')
        .aEsquerda()
        .apply {
            colunas("Comanda", comanda.numero.toString())
            comanda.mesa?.let { colunas("Mesa", it) }
            colunas("Forma", MetodoPagamento.rotulo(pagamento.metodo))
            colunas("Hora", horario.format(Date(quando)))
            separador()
            negrito(true)
            colunas("VALOR PAGO", Dinheiro.formatar(pagamento.valorCentavos))
            negrito(false)
            if (pagamento.trocoCentavos > 0)
                colunas("Troco", Dinheiro.formatar(pagamento.trocoCentavos))
            if (!saldo.quitada)
                colunas("Falta", Dinheiro.formatar(saldo.faltaCentavos))
            separador()
            colunas("Recebido por", pagamento.recebidoPor)
            linha()
            centralizado()
            linha(Configuracao.RODAPE_CUPOM)
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
