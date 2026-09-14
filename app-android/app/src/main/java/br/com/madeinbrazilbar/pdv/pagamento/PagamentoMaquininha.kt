package br.com.madeinbrazilbar.pdv.pagamento

import br.com.madeinbrazilbar.pdv.dados.ChaveValor
import br.com.madeinbrazilbar.pdv.dados.DadosCielo
import br.com.madeinbrazilbar.pdv.dados.Dinheiro
import br.com.madeinbrazilbar.pdv.dados.MetodoPagamento
import br.com.madeinbrazilbar.pdv.dados.PdvDao
import br.com.madeinbrazilbar.pdv.dados.RepositorioCaixa
import br.com.madeinbrazilbar.pdv.dados.ResultadoOperacao
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * Cobrança que foi mandada pra maquininha e ainda não teve resposta.
 * Fica gravada no aparelho ANTES de abrir a Cielo: se o app morrer no meio,
 * ninguém esquece que o cliente pode ter pago.
 */
@Serializable
data class PagamentoPendente(
    /** Vai como `reference` pra Cielo e vira o uuid do pagamento. */
    val referencia: String,
    val comandaId: Long,
    val comandaNumero: Int,
    val sessaoId: Long,
    val metodo: String,
    val valorCentavos: Long,
    val operador: String,
    val criadoEm: Long,
    /** Por que ficou sem confirmação (retorno ilegível, erro ao registrar...). */
    val problema: String? = null
)

/**
 * Fluxo de cobrança na maquininha: guarda o pendente, lê a resposta e
 * registra o pagamento pelo MESMO caminho do recebimento manual
 * (RepositorioCaixa.receber: mesma transação, mesmas regras, mesma fila).
 *
 * Só existe um pendente por aparelho: a maquininha cobra um de cada vez.
 */
class PagamentoMaquininha(
    private val dao: PdvDao,
    private val caixa: RepositorioCaixa,
    private val relogio: () -> Long = System::currentTimeMillis
) {
    /** Um retorno por vez: dois retornos iguais ao mesmo tempo não registram em dobro. */
    private val trava = Mutex()
    private val json = Json { ignoreUnknownKeys = true }

    sealed class Preparo {
        data class Pronto(val uri: String, val pendente: PagamentoPendente) : Preparo()
        data class Erro(val mensagem: String) : Preparo()
    }

    private fun ler(texto: String): PagamentoPendente? =
        try { json.decodeFromString(PagamentoPendente.serializer(), texto) } catch (e: Exception) { null }

    private suspend fun gravar(p: PagamentoPendente) =
        dao.gravarValor(ChaveValor(CHAVE, json.encodeToString(PagamentoPendente.serializer(), p)))

    fun pendenteAoVivo(): Flow<PagamentoPendente?> = dao.valorAoVivo(CHAVE).map { it?.let(::ler) }

    suspend fun pendente(): PagamentoPendente? = dao.lerValor(CHAVE)?.let(::ler)

    /** Ao abrir o app: pendente que já virou pagamento (app morreu no meio) some sozinho. */
    suspend fun arrumarAoAbrir() = trava.withLock {
        val p = pendente() ?: return@withLock
        if (dao.pagamentoPorUuid(p.referencia) != null) dao.apagarValor(CHAVE)
    }

    /**
     * Confere as regras do caixa, grava o pendente e devolve a URI pra abrir
     * a Cielo. Nada é gravado se alguma regra falhar.
     */
    suspend fun preparar(
        comandaId: Long,
        metodo: String,
        valorCentavos: Long,
        operador: String,
        credenciais: CredenciaisCielo
    ): Preparo {
        return trava.withLock {
            pendente()?.let {
                return Preparo.Erro(
                    "Há um pagamento de ${Dinheiro.comSimbolo(it.valorCentavos)} na maquininha sem confirmação " +
                        "(comanda ${it.comandaNumero}). Resolva antes de cobrar outro."
                )
            }
            if (!credenciais.preenchidas) return Preparo.Erro("A maquininha não está configurada neste app")
            if (CieloSmart.codigoPagamento(metodo) == null) {
                return Preparo.Erro("${MetodoPagamento.rotulo(metodo)} não é cobrado na maquininha")
            }
            val conferencia = caixa.conferirRecebimento(comandaId, metodo, valorCentavos)
            if (conferencia is ResultadoOperacao.Erro) return Preparo.Erro(conferencia.mensagem)

            val sessao = dao.sessaoAbertaAgora() ?: return Preparo.Erro("Não há caixa aberto")
            val comanda = dao.comandaAgora(comandaId) ?: return Preparo.Erro("Comanda não encontrada")
            val pendente = PagamentoPendente(
                referencia = UUID.randomUUID().toString(),
                comandaId = comandaId,
                comandaNumero = comanda.numero,
                sessaoId = sessao.id,
                metodo = metodo,
                valorCentavos = valorCentavos,
                operador = operador,
                criadoEm = relogio()
            )
            val uri = CieloSmart.montarUri(pendente.referencia, comanda.numero, valorCentavos, metodo, credenciais)
            gravar(pendente)
            Preparo.Pronto(uri, pendente)
        }
    }

    /** Trata a resposta da Cielo. */
    suspend fun processarRetorno(resultado: ResultadoCielo): ResultadoOperacao {
        return trava.withLock {
            val p = pendente()
            when (resultado) {
                is ResultadoCielo.Aprovado -> {
                    // retorno repetido: já registrado, não registra de novo
                    if (dao.pagamentoPorUuid(resultado.referencia) != null) {
                        if (p?.referencia == resultado.referencia) dao.apagarValor(CHAVE)
                        return ResultadoOperacao.Ok("Pagamento na maquininha já estava registrado")
                    }
                    if (p == null || p.referencia != resultado.referencia) {
                        return ResultadoOperacao.Erro(
                            "A maquininha aprovou um pagamento que não bate com nenhuma cobrança pendente. " +
                                "Confira o comprovante."
                        )
                    }
                    // registra o valor que a maquininha de fato aprovou
                    val valor = resultado.valorCentavos?.takeIf { it > 0 } ?: p.valorCentavos
                    val r = caixa.receber(
                        comandaId = p.comandaId,
                        metodo = p.metodo,
                        valorCentavos = valor,
                        recebidoCentavos = null,
                        operador = p.operador,
                        uuid = p.referencia,
                        cielo = DadosCielo(
                            transacaoId = resultado.idPagamento,
                            nsu = resultado.nsu,
                            autorizacao = resultado.autorizacao
                        ),
                        naMesmaTransacao = { dao.apagarValor(CHAVE) }
                    )
                    if (r is ResultadoOperacao.Erro) {
                        // o cliente pagou, mas a regra do caixa barrou: fica o aviso na tela
                        gravar(p.copy(problema = "Aprovado na maquininha, mas não registrou: ${r.mensagem}"))
                        return ResultadoOperacao.Erro("Pagamento aprovado na maquininha, mas não registrado: ${r.mensagem}")
                    }
                    r
                }
                is ResultadoCielo.Recusado -> {
                    if (p != null) dao.apagarValor(CHAVE)
                    ResultadoOperacao.Erro("Maquininha: ${resultado.motivo}")
                }
                is ResultadoCielo.Invalido -> {
                    if (p != null) gravar(p.copy(problema = "A resposta da maquininha não pôde ser lida"))
                    ResultadoOperacao.Erro("Pagamento na maquininha sem confirmação: confira o comprovante")
                }
            }
        }
    }

    /**
     * Plano B do pendente sem confirmação: o operador conferiu no comprovante
     * ou no extrato da maquininha que foi pago. Sem os códigos da Cielo, que
     * não chegaram.
     */
    suspend fun registrarComoPago(): ResultadoOperacao {
        return trava.withLock {
            val p = pendente() ?: return ResultadoOperacao.Erro("Não há pagamento pendente na maquininha")
            if (dao.pagamentoPorUuid(p.referencia) != null) {
                dao.apagarValor(CHAVE)
                return ResultadoOperacao.Ok("Pagamento na maquininha já estava registrado")
            }
            caixa.receber(
                comandaId = p.comandaId,
                metodo = p.metodo,
                valorCentavos = p.valorCentavos,
                recebidoCentavos = null,
                operador = p.operador,
                uuid = p.referencia,
                naMesmaTransacao = { dao.apagarValor(CHAVE) }
            )
        }
    }

    /** O operador conferiu que NÃO foi pago (ou vai cobrar de novo). */
    suspend fun descartar(): ResultadoOperacao {
        return trava.withLock {
            if (pendente() == null) return ResultadoOperacao.Erro("Não há pagamento pendente na maquininha")
            dao.apagarValor(CHAVE)
            ResultadoOperacao.Ok("Pagamento na maquininha descartado")
        }
    }

    companion object {
        const val CHAVE = "cielo_pagamento_pendente"
    }
}
