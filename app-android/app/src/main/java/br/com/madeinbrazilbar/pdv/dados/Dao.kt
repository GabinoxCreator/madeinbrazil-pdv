package br.com.madeinbrazilbar.pdv.dados

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface PdvDao {

    // ---------------- comandas ----------------

    @Query("SELECT * FROM comandas WHERE status IN ('aberta','fechada') ORDER BY numero")
    fun comandasVivas(): Flow<List<Comanda>>

    @Query("SELECT * FROM comandas WHERE id = :id")
    fun comanda(id: Long): Flow<Comanda?>

    @Query("SELECT * FROM comandas WHERE id = :id")
    suspend fun comandaAgora(id: Long): Comanda?

    @Query("SELECT * FROM comandas WHERE numero = :numero AND status IN ('aberta','fechada') LIMIT 1")
    suspend fun comandaVivaComNumero(numero: Int): Comanda?

    @Insert
    suspend fun inserirComanda(c: Comanda): Long

    @Update
    suspend fun atualizarComanda(c: Comanda)

    // ---------------- pedidos e itens ----------------

    @Insert
    suspend fun inserirPedido(p: Pedido): Long

    @Update
    suspend fun atualizarPedido(p: Pedido)

    @Query("SELECT * FROM pedidos WHERE id = :id")
    suspend fun pedido(id: Long): Pedido?

    @Query("SELECT * FROM pedidos WHERE comandaId = :comandaId ORDER BY criadoEm DESC")
    fun pedidosDaComanda(comandaId: Long): Flow<List<Pedido>>

    @Insert
    suspend fun inserirItens(itens: List<ItemLancado>)

    @Query("SELECT * FROM itens WHERE comandaId = :comandaId AND status = 'ativo' ORDER BY id")
    fun itensDaComanda(comandaId: Long): Flow<List<ItemLancado>>

    @Query("SELECT * FROM itens WHERE comandaId = :comandaId AND status = 'ativo' ORDER BY id")
    suspend fun itensDaComandaAgora(comandaId: Long): List<ItemLancado>

    @Query("SELECT * FROM itens WHERE pedidoId = :pedidoId AND status = 'ativo' ORDER BY id")
    suspend fun itensDoPedido(pedidoId: Long): List<ItemLancado>

    @Query("""UPDATE itens SET status = 'cancelado', canceladoPor = :por,
              canceladoMotivo = :motivo, canceladoEm = :quando WHERE id = :itemId""")
    suspend fun cancelarItem(itemId: Long, por: String, motivo: String, quando: Long)

    // ---------------- fila de impressao ----------------

    @Insert
    suspend fun enfileirar(trabalho: TrabalhoImpressao): Long

    @Query("SELECT * FROM impressoes WHERE status = 'pendente' ORDER BY criadoEm LIMIT 20")
    suspend fun impressoesPendentes(): List<TrabalhoImpressao>

    @Query("SELECT * FROM impressoes ORDER BY criadoEm DESC LIMIT 60")
    fun historicoImpressao(): Flow<List<TrabalhoImpressao>>

    @Query("SELECT COUNT(*) FROM impressoes WHERE status IN ('pendente','falha')")
    fun impressoesEmAberto(): Flow<Int>

    @Query("""UPDATE impressoes SET status = :status, tentativas = :tentativas,
              ultimoErro = :erro, impressoEm = :impressoEm WHERE id = :id""")
    suspend fun atualizarImpressao(
        id: Long, status: String, tentativas: Int, erro: String?, impressoEm: Long?
    )

    @Query("UPDATE impressoes SET status = 'pendente', ultimoErro = NULL WHERE id = :id")
    suspend fun reenfileirar(id: Long)

    /**
     * Lanca o pedido inteiro numa transacao: ou o pedido e todos os itens
     * entram, ou nada entra. Meio pedido no banco e comanda errada na conta.
     */
    @Transaction
    suspend fun lancarPedido(pedido: Pedido, montarItens: (Long) -> List<ItemLancado>): Long {
        val pedidoId = inserirPedido(pedido)
        inserirItens(montarItens(pedidoId))
        val comanda = comandaAgora(pedido.comandaId)
        if (comanda != null) {
            atualizarComanda(
                comanda.copy(
                    primeiroPedidoEm = comanda.primeiroPedidoEm ?: pedido.criadoEm,
                    ultimaAtividadePor = pedido.criadoPor,
                    ultimaAtividadeEm = pedido.criadoEm
                )
            )
        }
        return pedidoId
    }
}
