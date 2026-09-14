package br.com.madeinbrazilbar.pdv.dados

import br.com.madeinbrazilbar.pdv.sincronia.Mapeamento
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Regras do caixa.
 *
 * Guarda central da especificacao: **nenhum pagamento acontece sem sessao de
 * caixa aberta**. Dinheiro recebido fora de sessao e divergencia garantida no
 * fechamento, e foi listado como risco no §9 da spec. O banco do servidor
 * repete essa trava.
 */
class RepositorioCaixa(
    private val dao: PdvDao,
    private val sincronia: Sincronia? = null
) {

    fun sessaoAberta(): Flow<SessaoCaixa?> = dao.sessaoAberta()
    fun historicoSessoes(): Flow<List<SessaoCaixa>> = dao.historicoSessoes()
    fun movimentos(sessaoId: Long): Flow<List<MovimentoCaixa>> = dao.movimentosDaSessao(sessaoId)
    fun pagamentosDaComanda(comandaId: Long): Flow<List<Pagamento>> = dao.pagamentosDaComanda(comandaId)

    /** Gravação local + registro de envio: ou as duas coisas, ou nenhuma. */
    private suspend fun <T> transacao(bloco: suspend () -> T): T {
        val s = sincronia ?: return bloco()
        return s.emTransacao(bloco)
    }

    // ------------------------------------------------------------- abrir

    suspend fun abrirCaixa(fundoTrocoCentavos: Long, operador: String): ResultadoOperacao {
        dao.sessaoAbertaAgora()?.let {
            return ResultadoOperacao.Erro("Já existe um caixa aberto (por ${it.abertaPor})")
        }
        if (fundoTrocoCentavos < 0) return ResultadoOperacao.Erro("Fundo de troco não pode ser negativo")
        val sessao = SessaoCaixa(
            abertaPor = operador,
            abertaEm = System.currentTimeMillis(),
            fundoTrocoCentavos = fundoTrocoCentavos
        )
        transacao {
            dao.inserirSessao(sessao)
            sincronia?.inserir(Mapeamento.SESSOES, sessao.uuid, Mapeamento.sessao(sessao))
        }
        return ResultadoOperacao.Ok("Caixa aberto com ${Dinheiro.comSimbolo(fundoTrocoCentavos)} de troco")
    }

    // -------------------------------------------------- sangria/suprimento

    suspend fun registrarMovimento(
        tipo: String,
        valorCentavos: Long,
        motivo: String,
        operador: String
    ): ResultadoOperacao {
        val sessao = dao.sessaoAbertaAgora()
            ?: return ResultadoOperacao.Erro("Não há caixa aberto")
        if (valorCentavos <= 0) return ResultadoOperacao.Erro("Informe um valor maior que zero")
        if (motivo.isBlank()) return ResultadoOperacao.Erro("Informe o motivo")

        if (tipo == TipoMovimento.SANGRIA) {
            // nao deixa tirar mais dinheiro do que ha na gaveta
            val f = fechamentoDe(sessao)
            if (valorCentavos > f.esperadoEmDinheiroCentavos) {
                return ResultadoOperacao.Erro(
                    "A gaveta tem ${Dinheiro.comSimbolo(f.esperadoEmDinheiroCentavos)}; " +
                        "não dá para sangrar ${Dinheiro.comSimbolo(valorCentavos)}"
                )
            }
        }

        val movimento = MovimentoCaixa(
            sessaoId = sessao.id, tipo = tipo, valorCentavos = valorCentavos,
            motivo = motivo, criadoPor = operador, criadoEm = System.currentTimeMillis()
        )
        transacao {
            dao.inserirMovimento(movimento)
            sincronia?.inserir(Mapeamento.MOVIMENTOS, movimento.uuid, Mapeamento.movimento(movimento, sessao.uuid))
        }
        val rotulo = if (tipo == TipoMovimento.SANGRIA) "Sangria" else "Suprimento"
        return ResultadoOperacao.Ok("$rotulo de ${Dinheiro.comSimbolo(valorCentavos)} registrado")
    }

    // ---------------------------------------------------------- receber

    suspend fun saldo(comandaId: Long): SaldoComanda? {
        val comanda = dao.comandaAgora(comandaId) ?: return null
        val itens = dao.itensDaComandaAgora(comandaId)
        val conta = Conta.calcular(itens, comanda.taxaServicoPct, comanda.descontoCentavos, comanda.pessoas)
        return SaldoComanda(conta.totalCentavos, dao.totalPagoDaComanda(comandaId))
    }

    /**
     * Registra um recebimento. Aceita parcial: se sobrar saldo, a comanda
     * continua fechada aguardando o resto; ao quitar, vira 'recebida'.
     *
     * @param valorCentavos quanto abate da conta (e quanto entra na gaveta)
     * @param recebidoCentavos quanto o cliente entregou em dinheiro (para o troco)
     */
    suspend fun receber(
        comandaId: Long,
        metodo: String,
        valorCentavos: Long,
        recebidoCentavos: Long?,
        operador: String
    ): ResultadoOperacao {
        val sessao = dao.sessaoAbertaAgora()
            ?: return ResultadoOperacao.Erro("Não há caixa aberto — abra o caixa antes de receber")

        val comanda = dao.comandaAgora(comandaId)
            ?: return ResultadoOperacao.Erro("Comanda não encontrada")
        if (comanda.status == StatusComanda.CANCELADA) {
            return ResultadoOperacao.Erro("Comanda cancelada não recebe pagamento")
        }
        if (metodo !in MetodoPagamento.TODOS) {
            return ResultadoOperacao.Erro("Forma de pagamento inválida: $metodo")
        }
        if (valorCentavos <= 0) return ResultadoOperacao.Erro("Informe um valor maior que zero")

        val saldo = saldo(comandaId)
            ?: return ResultadoOperacao.Erro("Não consegui calcular a conta")
        if (valorCentavos > saldo.faltaCentavos) {
            return ResultadoOperacao.Erro(
                "Falta apenas ${Dinheiro.comSimbolo(saldo.faltaCentavos)} nesta comanda"
            )
        }

        var troco = 0L
        if (metodo == MetodoPagamento.DINHEIRO && recebidoCentavos != null) {
            if (recebidoCentavos < valorCentavos) {
                return ResultadoOperacao.Erro(
                    "O cliente entregou ${Dinheiro.comSimbolo(recebidoCentavos)}, " +
                        "menos que os ${Dinheiro.comSimbolo(valorCentavos)} a receber"
                )
            }
            troco = recebidoCentavos - valorCentavos
        }

        val agora = System.currentTimeMillis()
        val pagamento = Pagamento(
            comandaId = comandaId, sessaoId = sessao.id, metodo = metodo,
            valorCentavos = valorCentavos, trocoCentavos = troco,
            recebidoPor = operador, recebidoEm = agora
        )
        val novoSaldo = saldo.copy(pagoCentavos = saldo.pagoCentavos + valorCentavos)
        val comandaAtualizada = if (novoSaldo.quitada) {
            comanda.copy(
                status = StatusComanda.RECEBIDA,
                fechadaEm = comanda.fechadaEm ?: agora,
                ultimaAtividadePor = operador,
                ultimaAtividadeEm = agora
            )
        } else {
            comanda.copy(ultimaAtividadePor = operador, ultimaAtividadeEm = agora)
        }

        transacao {
            dao.inserirPagamento(pagamento)
            dao.atualizarComanda(comandaAtualizada)
            sincronia?.let { s ->
                s.inserir(Mapeamento.PAGAMENTOS, pagamento.uuid, Mapeamento.pagamento(pagamento, comanda.uuid, sessao.uuid))
                val campos = if (novoSaldo.quitada) {
                    Mapeamento.situacao(comandaAtualizada, recebidaEm = agora)
                } else {
                    // pagamento parcial: só avisa os outros terminais que a comanda mudou
                    Mapeamento.atividade(comandaAtualizada)
                }
                s.atualizar(Mapeamento.COMANDAS, comanda.uuid, campos)
            }
        }

        val fim = if (troco > 0) " · troco ${Dinheiro.comSimbolo(troco)}" else ""
        return if (novoSaldo.quitada) {
            ResultadoOperacao.Ok("Comanda ${comanda.numero} quitada$fim")
        } else {
            ResultadoOperacao.Ok(
                "Recebido ${Dinheiro.comSimbolo(valorCentavos)}$fim · " +
                    "falta ${Dinheiro.comSimbolo(novoSaldo.faltaCentavos)}"
            )
        }
    }

    // --------------------------------------------------------- fechamento

    private suspend fun fechamentoDe(sessao: SessaoCaixa, contado: Long? = null): Fechamento =
        Fechamento.calcular(
            sessao,
            dao.movimentosDaSessaoAgora(sessao.id),
            dao.pagamentosDaSessao(sessao.id),
            contado ?: sessao.contadoCentavos
        )

    suspend fun apuracao(contadoCentavos: Long? = null): Fechamento? {
        val sessao = dao.sessaoAbertaAgora() ?: return null
        return fechamentoDe(sessao, contadoCentavos)
    }

    suspend fun fecharCaixa(contadoCentavos: Long, operador: String, observacao: String?): ResultadoOperacao {
        val sessao = dao.sessaoAbertaAgora()
            ?: return ResultadoOperacao.Erro("Não há caixa aberto")

        // Comanda de CONTROLE (banda, almoco da equipe) fica aberta de proposito
        // e nao pode travar o fechamento - senao o caixa nunca fecharia.
        val pendentes = dao.comandasVivasAgora().filterNot { it.controle }
        if (pendentes.isNotEmpty()) {
            val numeros = pendentes.take(5).joinToString(", ") { it.numero.toString() }
            val resto = if (pendentes.size > 5) " e mais ${pendentes.size - 5}" else ""
            return ResultadoOperacao.Erro(
                "Ainda há ${pendentes.size} comanda(s) sem receber: $numeros$resto"
            )
        }

        val f = fechamentoDe(sessao, contadoCentavos)
        val fechada = sessao.copy(
            status = StatusSessao.FECHADA,
            fechadaPor = operador,
            fechadaEm = System.currentTimeMillis(),
            contadoCentavos = contadoCentavos,
            observacao = observacao
        )
        transacao {
            dao.atualizarSessao(fechada)
            sincronia?.atualizar(
                Mapeamento.SESSOES, fechada.uuid,
                Mapeamento.fechamentoDeSessao(fechada, f.esperadoEmDinheiroCentavos)
            )
        }
        val d = f.diferencaCentavos ?: 0L
        val veredito = when {
            d == 0L -> "caixa bateu certinho"
            d > 0 -> "sobrando ${Dinheiro.comSimbolo(d)}"
            else -> "faltando ${Dinheiro.comSimbolo(-d)}"
        }
        return ResultadoOperacao.Ok("Caixa fechado — $veredito")
    }
}
