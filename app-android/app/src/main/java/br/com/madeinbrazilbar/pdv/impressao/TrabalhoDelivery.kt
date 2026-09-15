package br.com.madeinbrazilbar.pdv.impressao

import br.com.madeinbrazilbar.pdv.sincronia.DataIso
import br.com.madeinbrazilbar.pdv.sincronia.decimal
import br.com.madeinbrazilbar.pdv.sincronia.inteiro
import br.com.madeinbrazilbar.pdv.sincronia.logico
import br.com.madeinbrazilbar.pdv.sincronia.texto
import br.com.madeinbrazilbar.pdv.sincronia.textoObrigatorio
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

object TipoTrabalhoDelivery {
    const val PRODUCAO = "producao"
    const val VIA_ENTREGA = "via_entrega"
    const val CANCELAMENTO = "cancelamento"
}

/**
 * Um trabalho da fila de impressão do delivery, como vem de
 * dlv_reservar_impressoes. Lido à mão (como o Mapeamento) pra aceitar número
 * que chega como texto e campo que não vem.
 */
data class TrabalhoDelivery(
    val trabalhoId: String,
    val tipo: String,
    val pontoCodigo: String,
    val pontoNome: String?,
    val pedido: PedidoDelivery,
    val itens: List<ItemDelivery>
) {
    companion object {
        fun ler(j: JsonObject): TrabalhoDelivery {
            val ponto = j["ponto"] as? JsonObject
                ?: throw IllegalStateException("Campo 'ponto' ausente no trabalho do delivery")
            val pedido = j["pedido"] as? JsonObject
                ?: throw IllegalStateException("Campo 'pedido' ausente no trabalho do delivery")
            return TrabalhoDelivery(
                trabalhoId = j.textoObrigatorio("trabalho_id"),
                tipo = j.textoObrigatorio("tipo"),
                pontoCodigo = ponto.textoObrigatorio("codigo"),
                pontoNome = ponto.texto("nome"),
                pedido = PedidoDelivery.ler(pedido),
                itens = (j["itens"] as? JsonArray).orEmpty().map { ItemDelivery.ler(it.jsonObject) }
            )
        }
    }
}

data class EnderecoDelivery(
    val rua: String?,
    val numero: String?,
    val bairro: String?,
    val complemento: String?,
    val referencia: String?,
    val distanciaKm: Double?,
    val mapaUrl: String?
)

data class PedidoDelivery(
    val numero: String,
    val modo: String,
    val criadoEm: Long?,
    val cliente: String?,
    val telefone: String?,
    val endereco: EnderecoDelivery?,
    val pagamento: String?,
    val pago: Boolean,
    /** Pagamento "online" (Mercado Pago): 'pix' ou 'credit_card'. Null nos outros. */
    val tipoPagamentoOnline: String?,
    val trocoParaCentavos: Long?,
    val subtotalCentavos: Long,
    val taxaEntregaCentavos: Long,
    val descontoCentavos: Long,
    val totalCentavos: Long,
    val observacao: String?,
    val motivoCancelamento: String?,
    val motoboy: String?
) {
    val entrega: Boolean get() = modo == "entrega"

    companion object {
        fun ler(j: JsonObject) = PedidoDelivery(
            numero = j.textoObrigatorio("numero"),
            modo = j.texto("modo") ?: "",
            // hora que não dá pra ler não pode impedir o cupom de sair
            criadoEm = j.texto("criado_em")?.let { runCatching { DataIso.paraMillis(it) }.getOrNull() },
            cliente = j.texto("cliente"),
            telefone = j.texto("telefone"),
            endereco = (j["endereco"] as? JsonObject)?.let { e ->
                EnderecoDelivery(
                    rua = e.texto("rua"),
                    numero = e.texto("numero"),
                    bairro = e.texto("bairro"),
                    complemento = e.texto("complemento"),
                    referencia = e.texto("referencia"),
                    distanciaKm = e.decimal("distancia_km"),
                    mapaUrl = e.texto("mapa_url")
                )
            },
            pagamento = j.texto("pagamento"),
            pago = j.logico("pago") ?: false,
            tipoPagamentoOnline = j.texto("mp_payment_type"),
            trocoParaCentavos = j.inteiro("troco_para_cents"),
            subtotalCentavos = j.inteiro("subtotal_cents") ?: 0,
            taxaEntregaCentavos = j.inteiro("taxa_entrega_cents") ?: 0,
            descontoCentavos = j.inteiro("desconto_cents") ?: 0,
            totalCentavos = j.inteiro("total_cents") ?: 0,
            observacao = j.texto("observacao"),
            motivoCancelamento = j.texto("motivo_cancelamento"),
            motoboy = j.texto("motoboy")
        )
    }
}

data class OpcaoDelivery(val grupo: String?, val nome: String, val quantidade: Int)

data class ItemDelivery(
    val nome: String,
    val quantidade: Int,
    val observacao: String?,
    /** Só vem na via de entrega. */
    val totalCentavos: Long?,
    val opcoes: List<OpcaoDelivery>
) {
    companion object {
        fun ler(j: JsonObject) = ItemDelivery(
            nome = j.textoObrigatorio("nome"),
            quantidade = (j.inteiro("quantidade") ?: 1).toInt(),
            observacao = j.texto("observacao"),
            totalCentavos = j.inteiro("total_cents"),
            opcoes = (j["opcoes"] as? JsonArray).orEmpty().map {
                val o = it.jsonObject
                OpcaoDelivery(o.texto("grupo"), o.textoObrigatorio("nome"), (o.inteiro("quantidade") ?: 1).toInt())
            }
        )
    }
}
