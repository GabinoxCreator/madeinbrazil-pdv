package br.com.madeinbrazilbar.pdv

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/** Trabalhos no formato de dlv_reservar_impressoes, pra montar os testes. */
object ExemplosDelivery {

    const val CRIADO_EM = "2026-09-14T22:30:00Z"
    const val MAPA = "https://www.google.com/maps/dir/?api=1&destination=-23.5505199,-46.6333094&travelmode=driving"

    fun trabalho(
        id: String,
        tipo: String = "producao",
        ponto: String = "cozinha",
        modo: String = "entrega",
        pagamento: String = "dinheiro",
        pago: Boolean = false,
        trocoPara: Long? = 10_000,
        comEndereco: Boolean = true,
        motivo: String? = null
    ): JsonObject = buildJsonObject {
        put("trabalho_id", id)
        put("tipo", tipo)
        putJsonObject("ponto") {
            put("codigo", ponto); put("nome", "Cozinha"); put("ip", "10.9.9.9"); put("porta", 9100)
        }
        putJsonObject("pedido") {
            put("numero", 42)
            put("modo", modo)
            put("status", "confirmado")
            put("criado_em", CRIADO_EM)
            put("cliente", "Maria Souza")
            put("telefone", "11 99999-0000")
            if (comEndereco) putJsonObject("endereco") {
                put("rua", "Rua das Flores"); put("numero", "100"); put("bairro", "Centro")
                put("complemento", "apto 12"); put("referencia", "perto da praça")
                put("distancia_km", 3.24); put("mapa_url", MAPA)
            } else put("endereco", JsonNull)
            put("pagamento", pagamento)
            put("pago", pago)
            if (trocoPara != null) put("troco_para_cents", trocoPara) else put("troco_para_cents", JsonNull)
            put("subtotal_cents", 8_980)
            put("taxa_entrega_cents", 700)
            put("desconto_cents", 500)
            put("total_cents", 9_180)
            put("observacao", "sem cebola")
            if (motivo != null) put("motivo_cancelamento", motivo) else put("motivo_cancelamento", JsonNull)
            put("motoboy", "Zé da Moto")
        }
        putJsonArray("itens") {
            addJsonObject {
                put("nome", "Feijoada"); put("quantidade", 2); put("observacao", "bem quente")
                put("total_cents", 7_980)
                putJsonArray("opcoes") {
                    addJsonObject { put("grupo", "Acompanhamento"); put("nome", "Farofa"); put("quantidade", 1) }
                    addJsonObject { put("grupo", "Adicional"); put("nome", "Torresmo"); put("quantidade", 2) }
                }
            }
            addJsonObject {
                put("nome", "Porção de limão"); put("quantidade", 1); put("observacao", JsonNull)
                put("total_cents", 1_000)
                putJsonArray("opcoes") {}
            }
        }
    }
}
