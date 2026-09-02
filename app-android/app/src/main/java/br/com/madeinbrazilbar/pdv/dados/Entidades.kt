package br.com.madeinbrazilbar.pdv.dados

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

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
}

@Entity(tableName = "comandas", indices = [Index("numero"), Index("status")])
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
    val ultimaAtividadeEm: Long? = null
)

@Entity(tableName = "pedidos", indices = [Index("comandaId")])
data class Pedido(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val comandaId: Long,
    val mesa: String? = null,
    val criadoPor: String,
    val criadoEm: Long,
    val statusImpressao: String = StatusImpressao.PENDENTE,
    val erroImpressao: String? = null
)

@Entity(tableName = "itens", indices = [Index("comandaId"), Index("pedidoId")])
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
    val canceladoEm: Long? = null
) {
    val totalCentavos: Long get() = precoUnitCentavos * quantidade
}

object TipoImpressao {
    const val PEDIDO = "pedido"
    const val CONFERENCIA = "conferencia"
    const val MENSAGEM = "mensagem"
    const val REIMPRESSAO = "reimpressao"
    const val TESTE = "teste"
}

/**
 * Fila de impressao. A especificacao e explicita: nenhuma impressao acontece
 * fora daqui, e a fila tem retry e log.
 *
 * Existe por um motivo pratico descoberto em teste: imprimir de forma sincrona
 * travava a tela por ~15s quando as termicas estavam fora do ar - inviavel no
 * meio do almoco. Agora o lancamento grava, enfileira e devolve na hora; a
 * fila tenta imprimir por conta propria.
 */
@Entity(tableName = "impressoes", indices = [Index("status")])
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
    val impressoEm: Long? = null
) {
    // ByteArray em data class precisa de equals/hashCode proprios
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TrabalhoImpressao) return false
        return id == other.id
    }
    override fun hashCode(): Int = id.hashCode()
}
