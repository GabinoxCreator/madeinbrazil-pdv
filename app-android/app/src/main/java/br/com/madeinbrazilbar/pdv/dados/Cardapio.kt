package br.com.madeinbrazilbar.pdv.dados

import android.content.Context
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class PontoProducao(
    val id: String,
    val nome: String,
    val ip: String,
    val porta: Int = 9100,
    val ipConfirmado: Boolean = true
)

@Serializable
data class Categoria(val slug: String, val nome: String, val ordem: Int)

@Serializable
data class ItemCardapio(
    val id: String,
    val categoria: String,
    val nome: String,
    val preco: Double,
    val ponto: String,
    val pontoConfirmado: Boolean,
    val codigo: String,
    val ordem: Int
) {
    val precoCentavos: Long get() = Dinheiro.deReais(preco)
}

@Serializable
data class Colaborador(val id: String, val nome: String, val funcao: String)

@Serializable
data class Cardapio(
    @SerialName("_aviso") val aviso: String = "",
    val pontosProducao: List<PontoProducao>,
    val categorias: List<Categoria>,
    val itens: List<ItemCardapio>,
    val colaboradores: List<Colaborador>
) {
    fun ponto(id: String): PontoProducao? = pontosProducao.firstOrNull { it.id == id }
    fun item(id: String): ItemCardapio? = itens.firstOrNull { it.id == id }
    fun itensDe(categoria: String): List<ItemCardapio> =
        itens.filter { it.categoria == categoria }.sortedBy { it.ordem }

    /** Busca por nome ou por codigo curto - o garcom digita qualquer um dos dois. */
    fun buscar(termo: String): List<ItemCardapio> {
        val t = termo.trim().lowercase()
        if (t.isEmpty()) return emptyList()
        return itens.filter { it.codigo == t || it.nome.lowercase().contains(t) }
    }

    /** Itens cujo ponto de producao ainda nao foi confirmado com a operacao. */
    val itensAConfirmar: Int get() = itens.count { !it.pontoConfirmado }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun carregar(context: Context): Cardapio {
            val texto = context.assets.open("cardapio.json")
                .bufferedReader(Charsets.UTF_8).use { it.readText() }
            return json.decodeFromString(serializer(), texto)
        }
    }
}
