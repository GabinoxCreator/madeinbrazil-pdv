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

    // ------------------------------------------------------------- delivery

    private fun horaDoPedido(p: PedidoDelivery) = p.criadoEm?.let { horario.format(Date(it)) } ?: "-"

    private fun modo(p: PedidoDelivery) = if (p.entrega) "ENTREGA" else "RETIRADA"

    private fun rotuloPagamento(forma: String?) = when (forma) {
        "pix_online" -> "Pix online"
        "pix_entrega" -> "Pix na entrega"
        "dinheiro" -> "Dinheiro"
        "credito" -> "Crédito"
        "debito" -> "Débito"
        null -> "-"
        else -> forma
    }

    /** Complementos indentados embaixo do item, e a observação do item. */
    private fun EscPos.detalhesDoItem(item: ItemDelivery) {
        for (o in item.opcoes) {
            val qtd = if (o.quantidade > 1) "${o.quantidade}x " else ""
            val grupo = o.grupo?.takeIf { it.isNotBlank() }?.let { "$it: " } ?: ""
            paragrafo("+ $grupo$qtd${o.nome}", recuo = "   ")
        }
        item.observacao?.takeIf { it.isNotBlank() }?.let { paragrafo("obs: $it", recuo = "   ") }
    }

    /**
     * Produção do delivery: só os itens deste ponto. Sem preço, como o
     * pedido de produção do salão.
     */
    fun deliveryProducao(t: TrabalhoDelivery, pontoNome: String): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .dobrado(true).negrito(true)
        .linha("DELIVERY #${t.pedido.numero}")
        .linha(modo(t.pedido))
        .dobrado(false).negrito(false)
        .linha(pontoNome.uppercase())
        .separador('=')
        .aEsquerda()
        .apply {
            colunas("Hora", horaDoPedido(t.pedido))
            separador()
            for (item in t.itens) {
                negrito(true)
                colunas("${item.quantidade}x ${item.nome}", "")
                negrito(false)
                detalhesDoItem(item)
            }
            separador()
            t.pedido.observacao?.takeIf { it.isNotBlank() }?.let {
                negrito(true).linha("OBS DO PEDIDO").negrito(false)
                paragrafo(it)
                separador()
            }
        }
        .avancar(3)
        .cortar()

    /** Via de entrega: o pedido inteiro, para o caixa e o motoboy. */
    fun deliveryViaEntrega(t: TrabalhoDelivery): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .negrito(true).linha(Configuracao.CABECALHO_CUPOM).negrito(false)
        .dobrado(true).negrito(true)
        .linha("DELIVERY #${t.pedido.numero}")
        .linha(modo(t.pedido))
        .dobrado(false).negrito(false)
        .separador('=')
        .aEsquerda()
        .apply {
            val p = t.pedido
            colunas("Hora", horaDoPedido(p))
            p.cliente?.takeIf { it.isNotBlank() }?.let { colunas("Cliente", it) }
            p.telefone?.takeIf { it.isNotBlank() }?.let { colunas("Telefone", it) }

            p.endereco?.let { e ->
                separador()
                negrito(true).linha("ENDEREÇO").negrito(false)
                val ruaNumero = listOfNotNull(e.rua?.takeIf { it.isNotBlank() }, e.numero?.takeIf { it.isNotBlank() })
                    .joinToString(", ")
                paragrafo(listOf(ruaNumero, e.bairro.orEmpty()).filter { it.isNotBlank() }.joinToString(" - "))
                e.complemento?.takeIf { it.isNotBlank() }?.let { paragrafo("Compl.: $it") }
                e.referencia?.takeIf { it.isNotBlank() }?.let { paragrafo("Ref.: $it") }
                e.distanciaKm?.let {
                    colunas("Distância", String.format(Locale("pt", "BR"), "%.1f km", it))
                }
            }

            separador()
            for (item in t.itens) {
                colunas("${item.quantidade}x ${item.nome}", item.totalCentavos?.let { Dinheiro.formatar(it) } ?: "")
                detalhesDoItem(item)
            }
            separador()
            colunas("Subtotal", Dinheiro.formatar(p.subtotalCentavos))
            if (p.taxaEntregaCentavos > 0 || p.entrega) {
                colunas("Taxa de entrega", Dinheiro.formatar(p.taxaEntregaCentavos))
            }
            if (p.descontoCentavos > 0) {
                colunas("Desconto", "-" + Dinheiro.formatar(p.descontoCentavos))
            }
            separador('=')
            negrito(true)
            dobrado(true)
            colunas("TOTAL", Dinheiro.formatar(p.totalCentavos))
            dobrado(false)
            negrito(false)

            colunas("Pagamento", rotuloPagamento(p.pagamento))
            if (p.pago) {
                centralizado().dobrado(true).negrito(true).linha("PAGO").dobrado(false).negrito(false).aEsquerda()
            }
            p.trocoParaCentavos?.takeIf { it > 0 }?.let {
                centralizado().dobrado(true).negrito(true)
                linha("TROCO PARA ${Dinheiro.comSimbolo(it)}")
                dobrado(false).negrito(false).aEsquerda()
            }

            p.observacao?.takeIf { it.isNotBlank() }?.let {
                separador()
                negrito(true).linha("OBS DO PEDIDO").negrito(false)
                paragrafo(it)
            }
            p.motoboy?.takeIf { it.isNotBlank() }?.let {
                separador()
                colunas("Motoboy", it)
            }

            p.endereco?.mapaUrl?.takeIf { it.isNotBlank() }?.let { url ->
                separador()
                linha("Mapa:")
                // link sem espaço: quebra em pedaços da largura da bobina
                url.chunked(EscPos.COLUNAS).forEach { linha(it) }
                if (url.length <= 300 && url.all { it.code < 128 }) {
                    centralizado()
                    qrCode(url)
                    aEsquerda()
                }
            }

            linha()
            centralizado()
            linha(Configuracao.RODAPE_CUPOM)
        }
        .avancar(3)
        .cortar()

    /** Aviso para quem já recebeu a produção de um pedido que foi cancelado. */
    fun deliveryCancelamento(t: TrabalhoDelivery, pontoNome: String): EscPos = EscPos()
        .inicializar()
        .centralizado()
        .dobrado(true).negrito(true)
        .linha("PEDIDO #${t.pedido.numero}")
        .linha("CANCELADO")
        .dobrado(false).negrito(false)
        .linha("DELIVERY · ${pontoNome.uppercase()}")
        .separador('=')
        .aEsquerda()
        .apply {
            colunas("Hora do pedido", horaDoPedido(t.pedido))
            separador()
            negrito(true).linha("MOTIVO").negrito(false)
            paragrafo(t.pedido.motivoCancelamento?.takeIf { it.isNotBlank() } ?: "não informado")
            if (t.itens.isNotEmpty()) {
                separador()
                negrito(true).linha("NÃO PRODUZIR").negrito(false)
                for (item in t.itens) linha("${item.quantidade}x ${item.nome}")
            }
            separador()
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
