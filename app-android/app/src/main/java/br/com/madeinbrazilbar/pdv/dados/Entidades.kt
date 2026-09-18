package br.com.madeinbrazilbar.pdv.dados

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.UUID

/*
 * Cada registro que vai pro servidor tem, além do id local (Long), um `uuid`
 * gerado NO APARELHO no momento em que nasce. É esse uuid que identifica o
 * registro no servidor: o garçom lança offline, e quando a rede volta o
 * registro sobe sem colidir com o de outro terminal - e subir duas vezes o
 * mesmo registro não duplica nada.
 */
private fun novoUuid(): String = UUID.randomUUID().toString()

object StatusComanda {
    const val ABERTA = "aberta"
    const val FECHADA = "fechada"
    const val RECEBIDA = "recebida"
    const val CANCELADA = "cancelada"

    /** Status em que o numero da comanda ainda esta ocupado. */
    val VIVOS = listOf(ABERTA, FECHADA)
}

object StatusItem {
    const val ATIVO = "ativo"
    const val CANCELADO = "cancelado"
}

object StatusImpressao {
    const val PENDENTE = "pendente"
    const val ENVIADO = "enviado"
    const val FALHA = "falha"
    /** Só vale pro pedido: um ponto de produção imprimiu e outro não. */
    const val PARCIAL = "parcial"

    /**
     * Situação de impressão do PEDIDO a partir dos cupons dele (um por ponto
     * de produção). Enquanto algum cupom ainda está na fila, devolve null:
     * não dá pra dizer nada ainda, e avisar "falha" agora seria alarme falso
     * de um cupom que pode sair na próxima tentativa.
     */
    fun doPedido(statusDosCupons: List<String>): String? = when {
        statusDosCupons.isEmpty() -> null
        statusDosCupons.any { it == PENDENTE } -> null
        statusDosCupons.all { it == ENVIADO } -> ENVIADO
        statusDosCupons.all { it == FALHA } -> FALHA
        else -> PARCIAL
    }
}

@Entity(
    tableName = "comandas",
    indices = [Index("numero"), Index("status"), Index(value = ["uuid"], unique = true)]
)
data class Comanda(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val numero: Int,
    val mesa: String? = null,
    val status: String = StatusComanda.ABERTA,
    val cliente: String? = null,
    val pessoas: Int = 1,
    /** Comanda de controle (banda, almoco da equipe) fica aberta de proposito. */
    val controle: Boolean = false,
    val taxaServicoPct: Double,
    val descontoCentavos: Long = 0,
    val abertaPor: String,
    val abertaEm: Long,
    val primeiroPedidoEm: Long? = null,
    val fechadaEm: Long? = null,
    val ultimaAtividadePor: String? = null,
    val ultimaAtividadeEm: Long? = null,
    val uuid: String = novoUuid()
)

@Entity(
    tableName = "pedidos",
    indices = [Index("comandaId"), Index(value = ["uuid"], unique = true)]
)
data class Pedido(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val comandaId: Long,
    val mesa: String? = null,
    val criadoPor: String,
    val criadoEm: Long,
    val statusImpressao: String = StatusImpressao.PENDENTE,
    val erroImpressao: String? = null,
    val uuid: String = novoUuid()
)

@Entity(
    tableName = "itens",
    indices = [Index("comandaId"), Index("pedidoId"), Index(value = ["uuid"], unique = true)]
)
data class ItemLancado(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val pedidoId: Long,
    /** Redundante de proposito: em transferencia a comanda muda, o pedido nao. */
    val comandaId: Long,
    val itemCardapioId: String,
    /** Nome e preco CONGELADOS no lancamento: mudanca no cardapio nao reescreve comanda antiga. */
    val nome: String,
    val quantidade: Int,
    val precoUnitCentavos: Long,
    val pontoId: String,
    val observacao: String? = null,
    val status: String = StatusItem.ATIVO,
    val canceladoPor: String? = null,
    val canceladoMotivo: String? = null,
    val canceladoEm: Long? = null,
    val uuid: String = novoUuid()
) {
    val totalCentavos: Long get() = precoUnitCentavos * quantidade
}

object TipoImpressao {
    const val PEDIDO = "pedido"
    const val CONFERENCIA = "conferencia"
    const val MENSAGEM = "mensagem"
    const val REIMPRESSAO = "reimpressao"
    const val TESTE = "teste"
    /** Cupom da fila do delivery no servidor. Sem pedidoId: não mexe no print_status do PDV. */
    const val DELIVERY = "delivery"

    /** Cupom da comanda lançada no navegador (painel/garçom), vindo da fila do servidor. */
    const val GARCOM = "garcom"
}

/**
 * Fila de impressao. A especificacao e explicita: nenhuma impressao acontece
 * fora daqui, e a fila tem retry e log.
 *
 * Existe por um motivo pratico descoberto em teste: imprimir de forma sincrona
 * travava a tela por ~15s quando as termicas estavam fora do ar - inviavel no
 * meio do almoco. Agora o lancamento grava, enfileira e devolve na hora; a
 * fila tenta imprimir por conta propria.
 *
 * Fica só no aparelho: não vai pro servidor. Quem imprime é o terminal.
 */
@Entity(tableName = "impressoes", indices = [Index("status"), Index("trabalhoDeliveryId")])
data class TrabalhoImpressao(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val pontoId: String,
    val tipo: String,
    /** Bytes ESC/POS ja montados. */
    val conteudo: ByteArray,
    /** O mesmo cupom em texto, para o log e para conferir sem gastar bobina. */
    val previa: String,
    val status: String = StatusImpressao.PENDENTE,
    val tentativas: Int = 0,
    val ultimoErro: String? = null,
    val comandaId: Long? = null,
    val pedidoId: Long? = null,
    val descricao: String,
    val criadoEm: Long,
    val impressoEm: Long? = null,
    /** Id do trabalho na fila do delivery do servidor. Null: cupom do próprio PDV. */
    val trabalhoDeliveryId: String? = null,
    /** O servidor já recebeu o resultado (dlv_concluir_impressao) deste cupom. */
    @ColumnInfo(defaultValue = "0")
    val concluidoNoServidor: Boolean = false
) {
    // ByteArray em data class precisa de equals/hashCode proprios
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TrabalhoImpressao) return false
        return id == other.id
    }
    override fun hashCode(): Int = id.hashCode()
}

// ===================================================================
// CAIXA
// ===================================================================

object StatusSessao {
    const val ABERTA = "aberta"
    const val FECHADA = "fechada"
}

object TipoMovimento {
    const val SANGRIA = "sangria"        // tira dinheiro da gaveta
    const val SUPRIMENTO = "suprimento"  // poe dinheiro na gaveta
}

object MetodoPagamento {
    const val DINHEIRO = "dinheiro"
    const val PIX = "pix"
    const val CREDITO = "credito"
    const val DEBITO = "debito"
    const val VOUCHER = "voucher"

    val TODOS = listOf(DINHEIRO, PIX, CREDITO, DEBITO, VOUCHER)

    fun rotulo(m: String) = when (m) {
        DINHEIRO -> "Dinheiro"
        PIX -> "Pix"
        CREDITO -> "Crédito"
        DEBITO -> "Débito"
        VOUCHER -> "Voucher"
        else -> m
    }
}

@Entity(
    tableName = "sessoes_caixa",
    indices = [Index("status"), Index(value = ["uuid"], unique = true)]
)
data class SessaoCaixa(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val abertaPor: String,
    val abertaEm: Long,
    /** Fundo de troco colocado na gaveta na abertura. */
    val fundoTrocoCentavos: Long,
    val fechadaPor: String? = null,
    val fechadaEm: Long? = null,
    /** Dinheiro efetivamente contado na gaveta no fechamento. */
    val contadoCentavos: Long? = null,
    val status: String = StatusSessao.ABERTA,
    val observacao: String? = null,
    val uuid: String = novoUuid()
)

@Entity(
    tableName = "movimentos_caixa",
    indices = [Index("sessaoId"), Index(value = ["uuid"], unique = true)]
)
data class MovimentoCaixa(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val sessaoId: Long,
    val tipo: String,
    val valorCentavos: Long,
    val motivo: String,
    val criadoPor: String,
    val criadoEm: Long,
    val uuid: String = novoUuid()
)

/**
 * Recebimento. Suporta pagamento parcial e varios pagamentos na mesma conta.
 *
 * `valorCentavos` e o quanto foi ABATIDO DA CONTA - e tambem o quanto entra
 * na gaveta. O troco e so a mecanica fisica: cliente da 100 numa conta de 50
 * -> valor=50, troco=50, e a gaveta cresce 50. Somar troco aqui inflaria o
 * fechamento.
 */
@Entity(
    tableName = "pagamentos",
    indices = [Index("comandaId"), Index("sessaoId"), Index(value = ["uuid"], unique = true)]
)
data class Pagamento(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val comandaId: Long,
    val sessaoId: Long,
    val metodo: String,
    val valorCentavos: Long,
    val trocoCentavos: Long = 0,
    val recebidoPor: String,
    val recebidoEm: Long,
    // preenchidos pela resposta da maquininha Cielo Smart (pagamento/CieloSmart.kt)
    val cieloNsu: String? = null,
    val cieloAutorizacao: String? = null,
    val cieloTransacaoId: String? = null,
    /** Reservado para o modulo fiscal, fora do escopo desta versao. */
    val referenciaFiscal: String? = null,
    val uuid: String = novoUuid()
)

// ===================================================================
// SINCRONIZAÇÃO
// ===================================================================

object TipoOperacao {
    const val INSERIR = "inserir"
    const val ATUALIZAR = "atualizar"
}

/**
 * Fila de envio pro servidor. Toda gravação que precisa subir entra aqui NA
 * MESMA TRANSAÇÃO da gravação local: ou as duas coisas acontecem, ou nenhuma.
 * O motor manda em ordem de chegada e só apaga depois que o servidor aceitou.
 * Se uma operação falha, ele para ali e tenta de novo depois - nunca pula.
 */
@Entity(tableName = "sync_operacoes", indices = [Index("registroUuid")])
data class OperacaoSync(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val tabela: String,
    val tipo: String,
    val registroUuid: String,
    /** JSON do que vai pro servidor. */
    val payload: String,
    val criadaEm: Long,
    val tentativas: Int = 0,
    val ultimoErro: String? = null,
    val ultimaTentativaEm: Long? = null
)

/** Pequenos valores de controle (ex.: até onde já recebi do servidor). */
@Entity(tableName = "chave_valor")
data class ChaveValor(
    @PrimaryKey val chave: String,
    val valor: String
)
