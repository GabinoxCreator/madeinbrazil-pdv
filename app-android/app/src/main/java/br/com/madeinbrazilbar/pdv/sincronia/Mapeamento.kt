package br.com.madeinbrazilbar.pdv.sincronia

import br.com.madeinbrazilbar.pdv.dados.Comanda
import br.com.madeinbrazilbar.pdv.dados.ItemLancado
import br.com.madeinbrazilbar.pdv.dados.MovimentoCaixa
import br.com.madeinbrazilbar.pdv.dados.Pagamento
import br.com.madeinbrazilbar.pdv.dados.Pedido
import br.com.madeinbrazilbar.pdv.dados.SessaoCaixa
import br.com.madeinbrazilbar.pdv.dados.StatusImpressao
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Datas no formato do servidor (ISO 8601, UTC).
 * Feito à mão de propósito: o java.time só existe a partir do Android 8 e o
 * terminal da Cielo exige suporte desde o Android 7.
 */
object DataIso {
    private val formato = object : ThreadLocal<SimpleDateFormat>() {
        override fun initialValue() =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
    }

    private val padrao =
        Regex("""^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}(?::?\d{2})?)?$""")

    fun deMillis(millis: Long): String = formato.get()!!.format(Date(millis))

    fun paraMillis(texto: String): Long {
        val m = padrao.matchEntire(texto.trim())
            ?: throw IllegalArgumentException("Data em formato inesperado: $texto")
        val g = m.groupValues
        val calendario = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(g[1].toInt(), g[2].toInt() - 1, g[3].toInt(), g[4].toInt(), g[5].toInt(), g[6].toInt())
        }
        val milesimos = g[7].takeIf { it.isNotEmpty() }?.padEnd(3, '0')?.take(3)?.toLong() ?: 0L
        val fuso = g[8]
        val deslocamentoMin = if (fuso.isEmpty() || fuso == "Z") 0 else {
            val sinal = if (fuso[0] == '-') -1 else 1
            val digitos = fuso.substring(1).replace(":", "")
            val horas = digitos.take(2).toInt()
            val minutos = if (digitos.length >= 4) digitos.substring(2, 4).toInt() else 0
            sinal * (horas * 60 + minutos)
        }
        return calendario.timeInMillis + milesimos - deslocamentoMin * 60_000L
    }
}

// ---------------------------------------------------------------- JSON

internal fun JsonObject.texto(chave: String): String? = (this[chave] as? JsonPrimitive)?.contentOrNull

internal fun JsonObject.textoObrigatorio(chave: String): String =
    texto(chave) ?: throw IllegalStateException("Campo '$chave' ausente na resposta do servidor")

internal fun JsonObject.inteiro(chave: String): Long? =
    texto(chave)?.let { it.toLongOrNull() ?: it.toDouble().toLong() }

internal fun JsonObject.decimal(chave: String): Double? = texto(chave)?.toDouble()

internal fun JsonObject.logico(chave: String): Boolean? = texto(chave)?.toBooleanStrictOrNull()

internal fun JsonObject.data(chave: String): Long? = texto(chave)?.let(DataIso::paraMillis)

/**
 * Tradução entre o banco do aparelho e o banco do servidor.
 * Único lugar que conhece o nome das colunas do servidor.
 */
object Mapeamento {

    const val COMANDAS = "pdv_cards"
    const val PEDIDOS = "pdv_card_orders"
    const val ITENS = "pdv_card_items"
    const val SESSOES = "pdv_cash_sessions"
    const val MOVIMENTOS = "pdv_cash_movements"
    const val PAGAMENTOS = "pdv_payments"
    const val PONTOS = "pdv_production_points"
    const val CATEGORIAS = "pdv_menu_categories"
    const val CARDAPIO = "pdv_menu_items"
    const val EQUIPE = "pdv_collaborators"

    /**
     * No aparelho o ponto de produção é um código ("cozinha"); no servidor é
     * um id. O item guarda o código na fila e o motor troca pelo id na hora
     * de enviar.
     */
    const val CAMPO_CODIGO_PONTO = "point_code"

    private val formatoUuid =
        Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    fun ehUuid(texto: String): Boolean = formatoUuid.matches(texto)

    private fun iso(millis: Long?): String? = millis?.let(DataIso::deMillis)

    // ============================================== aparelho -> servidor

    fun comanda(c: Comanda): JsonObject = buildJsonObject {
        put("id", c.uuid)
        put("card_number", c.numero)
        put("table_number", c.mesa)
        put("status", c.status)
        put("customer_name", c.cliente)
        put("people_count", c.pessoas)
        put("is_control_card", c.controle)
        put("service_fee_pct", c.taxaServicoPct)
        put("discount_cents", c.descontoCentavos)
        put("opened_by_name", c.abertaPor)
        put("opened_at", iso(c.abertaEm))
        put("first_order_at", iso(c.primeiroPedidoEm))
        put("closed_at", iso(c.fechadaEm))
        put("last_activity_by_name", c.ultimaAtividadePor)
        put("last_activity_at", iso(c.ultimaAtividadeEm))
    }

    /*
     * Atualizações mandam SÓ os campos que aquela ação mexeu. Assim, se dois
     * terminais mexem na mesma comanda (um dá desconto, outro fecha), um não
     * apaga o que o outro fez.
     */

    fun atividade(c: Comanda, primeiroPedido: Boolean = false): JsonObject = buildJsonObject {
        put("last_activity_by_name", c.ultimaAtividadePor)
        put("last_activity_at", iso(c.ultimaAtividadeEm))
        if (primeiroPedido) put("first_order_at", iso(c.primeiroPedidoEm))
    }

    fun situacao(c: Comanda, recebidaEm: Long? = null): JsonObject = buildJsonObject {
        put("status", c.status)
        put("closed_at", iso(c.fechadaEm))
        if (recebidaEm != null) put("received_at", iso(recebidaEm))
        put("last_activity_by_name", c.ultimaAtividadePor)
        put("last_activity_at", iso(c.ultimaAtividadeEm))
    }

    /** Só as colunas que o terminal pode alterar ao cancelar (mesmas da pdv_cancelar_comanda). */
    fun cancelamentoDeComanda(c: Comanda, motivo: String): JsonObject = buildJsonObject {
        put("status", c.status)
        put("closed_at", iso(c.fechadaEm))
        put("cancelled_reason", motivo)
        put("last_activity_by_name", c.ultimaAtividadePor)
        put("last_activity_at", iso(c.ultimaAtividadeEm))
    }

    fun ajusteDeConta(c: Comanda): JsonObject = buildJsonObject {
        put("people_count", c.pessoas)
        put("service_fee_pct", c.taxaServicoPct)
        put("discount_cents", c.descontoCentavos)
    }

    fun pedido(p: Pedido, comandaUuid: String): JsonObject = buildJsonObject {
        put("id", p.uuid)
        put("card_id", comandaUuid)
        put("created_by_name", p.criadoPor)
        put("table_number", p.mesa)
        put("print_status", p.statusImpressao)
        put("created_at", iso(p.criadoEm))
    }

    /** Só a situação de impressão: o resto do pedido não muda depois de lançado. */
    fun impressaoDoPedido(p: Pedido): JsonObject = buildJsonObject {
        put("print_status", p.statusImpressao)
    }

    fun item(i: ItemLancado, pedidoUuid: String, comandaUuid: String, lancadoEm: Long): JsonObject =
        buildJsonObject {
            put("id", i.uuid)
            put("order_id", pedidoUuid)
            put("card_id", comandaUuid)
            // item do cardápio só vai se veio do servidor (uuid); o nome e o preço
            // já estão congelados no próprio item
            put("menu_item_id", i.itemCardapioId.takeIf { ehUuid(it) })
            put("item_name", i.nome)
            put("quantity", i.quantidade)
            put("unit_price_cents", i.precoUnitCentavos)
            put(CAMPO_CODIGO_PONTO, i.pontoId)
            put("notes", i.observacao)
            put("status", i.status)
            put("cancelled_by_name", i.canceladoPor)
            put("cancelled_reason", i.canceladoMotivo)
            put("cancelled_at", iso(i.canceladoEm))
            put("created_at", iso(lancadoEm))
        }

    fun cancelamento(i: ItemLancado): JsonObject = buildJsonObject {
        put("status", i.status)
        put("cancelled_by_name", i.canceladoPor)
        put("cancelled_reason", i.canceladoMotivo)
        put("cancelled_at", iso(i.canceladoEm))
    }

    fun sessao(s: SessaoCaixa): JsonObject = buildJsonObject {
        put("id", s.uuid)
        put("opened_by_name", s.abertaPor)
        put("opened_at", iso(s.abertaEm))
        put("opening_float_cents", s.fundoTrocoCentavos)
        put("status", s.status)
        put("closed_by_name", s.fechadaPor)
        put("closed_at", iso(s.fechadaEm))
        put("counted_cents", s.contadoCentavos)
        put("notes", s.observacao)
    }

    fun fechamentoDeSessao(s: SessaoCaixa, esperadoCentavos: Long): JsonObject = buildJsonObject {
        put("status", s.status)
        put("closed_by_name", s.fechadaPor)
        put("closed_at", iso(s.fechadaEm))
        put("counted_cents", s.contadoCentavos)
        put("expected_cents", esperadoCentavos)
        put("notes", s.observacao)
    }

    fun movimento(m: MovimentoCaixa, sessaoUuid: String): JsonObject = buildJsonObject {
        put("id", m.uuid)
        put("session_id", sessaoUuid)
        put("type", m.tipo)
        put("amount_cents", m.valorCentavos)
        put("reason", m.motivo)
        put("created_by_name", m.criadoPor)
        put("created_at", iso(m.criadoEm))
    }

    fun pagamento(p: Pagamento, comandaUuid: String, sessaoUuid: String): JsonObject = buildJsonObject {
        put("id", p.uuid)
        put("card_id", comandaUuid)
        put("session_id", sessaoUuid)
        put("method", p.metodo)
        put("amount_cents", p.valorCentavos)
        put("change_cents", p.trocoCentavos)
        put("received_by_name", p.recebidoPor)
        put("received_at", iso(p.recebidoEm))
        put("cielo_nsu", p.cieloNsu)
        put("cielo_authorization", p.cieloAutorizacao)
        put("cielo_transaction_id", p.cieloTransacaoId)
    }

    // ============================================== servidor -> aparelho

    fun paraComanda(j: JsonObject, idLocal: Long): Comanda = Comanda(
        id = idLocal,
        numero = j.inteiro("card_number")!!.toInt(),
        mesa = j.texto("table_number"),
        status = j.textoObrigatorio("status"),
        cliente = j.texto("customer_name"),
        pessoas = j.inteiro("people_count")?.toInt() ?: 1,
        controle = j.logico("is_control_card") ?: false,
        taxaServicoPct = j.decimal("service_fee_pct") ?: 0.0,
        descontoCentavos = j.inteiro("discount_cents") ?: 0L,
        abertaPor = j.texto("opened_by_name") ?: "?",
        abertaEm = j.data("opened_at") ?: 0L,
        primeiroPedidoEm = j.data("first_order_at"),
        fechadaEm = j.data("closed_at"),
        ultimaAtividadePor = j.texto("last_activity_by_name"),
        ultimaAtividadeEm = j.data("last_activity_at"),
        uuid = j.textoObrigatorio("id")
    )

    fun paraPedido(j: JsonObject, idLocal: Long, comandaIdLocal: Long): Pedido = Pedido(
        id = idLocal,
        comandaId = comandaIdLocal,
        mesa = j.texto("table_number"),
        criadoPor = j.texto("created_by_name") ?: "?",
        criadoEm = j.data("created_at") ?: 0L,
        statusImpressao = j.texto("print_status") ?: StatusImpressao.PENDENTE,
        uuid = j.textoObrigatorio("id")
    )

    fun paraItem(
        j: JsonObject,
        idLocal: Long,
        pedidoIdLocal: Long,
        comandaIdLocal: Long,
        codigoPonto: String
    ): ItemLancado = ItemLancado(
        id = idLocal,
        pedidoId = pedidoIdLocal,
        comandaId = comandaIdLocal,
        itemCardapioId = j.texto("menu_item_id") ?: "",
        nome = j.textoObrigatorio("item_name"),
        quantidade = j.inteiro("quantity")!!.toInt(),
        precoUnitCentavos = j.inteiro("unit_price_cents")!!,
        pontoId = codigoPonto,
        observacao = j.texto("notes"),
        status = j.textoObrigatorio("status"),
        canceladoPor = j.texto("cancelled_by_name"),
        canceladoMotivo = j.texto("cancelled_reason"),
        canceladoEm = j.data("cancelled_at"),
        uuid = j.textoObrigatorio("id")
    )

    fun paraSessao(j: JsonObject, idLocal: Long): SessaoCaixa = SessaoCaixa(
        id = idLocal,
        abertaPor = j.texto("opened_by_name") ?: "?",
        abertaEm = j.data("opened_at") ?: 0L,
        fundoTrocoCentavos = j.inteiro("opening_float_cents") ?: 0L,
        fechadaPor = j.texto("closed_by_name"),
        fechadaEm = j.data("closed_at"),
        contadoCentavos = j.inteiro("counted_cents"),
        status = j.textoObrigatorio("status"),
        observacao = j.texto("notes"),
        uuid = j.textoObrigatorio("id")
    )

    fun paraMovimento(j: JsonObject, idLocal: Long, sessaoIdLocal: Long): MovimentoCaixa = MovimentoCaixa(
        id = idLocal,
        sessaoId = sessaoIdLocal,
        tipo = j.textoObrigatorio("type"),
        valorCentavos = j.inteiro("amount_cents")!!,
        motivo = j.texto("reason") ?: "",
        criadoPor = j.texto("created_by_name") ?: "?",
        criadoEm = j.data("created_at") ?: 0L,
        uuid = j.textoObrigatorio("id")
    )

    fun paraPagamento(j: JsonObject, idLocal: Long, comandaIdLocal: Long, sessaoIdLocal: Long): Pagamento =
        Pagamento(
            id = idLocal,
            comandaId = comandaIdLocal,
            sessaoId = sessaoIdLocal,
            metodo = j.textoObrigatorio("method"),
            valorCentavos = j.inteiro("amount_cents")!!,
            trocoCentavos = j.inteiro("change_cents") ?: 0L,
            recebidoPor = j.texto("received_by_name") ?: "?",
            recebidoEm = j.data("received_at") ?: 0L,
            cieloNsu = j.texto("cielo_nsu"),
            cieloAutorizacao = j.texto("cielo_authorization"),
            cieloTransacaoId = j.texto("cielo_transaction_id"),
            uuid = j.textoObrigatorio("id")
        )
}
