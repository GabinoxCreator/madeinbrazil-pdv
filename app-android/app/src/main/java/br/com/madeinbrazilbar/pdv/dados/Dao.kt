package br.com.madeinbrazilbar.pdv.dados

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface PdvDao {

    // ---------------- comandas ----------------

    @Query("SELECT * FROM comandas WHERE status IN ('aberta','fechada') ORDER BY numero")
    fun comandasVivas(): Flow<List<Comanda>>

    @Query("SELECT * FROM comandas WHERE status IN ('aberta','fechada') ORDER BY numero")
    suspend fun comandasVivasAgora(): List<Comanda>

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

    @Query("DELETE FROM comandas WHERE id = :id")
    suspend fun apagarComanda(id: Long)

    /*
     * Usados pra juntar duas comandas que são a MESMA comanda física (mesmo
     * número aberto em dois terminais sem rede): tudo que estava na cópia
     * passa pra comanda que já existe no servidor.
     */

    @Query("UPDATE pedidos SET comandaId = :para WHERE comandaId = :de")
    suspend fun moverPedidosDeComanda(de: Long, para: Long)

    @Query("UPDATE itens SET comandaId = :para WHERE comandaId = :de")
    suspend fun moverItensDeComanda(de: Long, para: Long)

    @Query("UPDATE pagamentos SET comandaId = :para WHERE comandaId = :de")
    suspend fun moverPagamentosDeComanda(de: Long, para: Long)

    @Query("UPDATE impressoes SET comandaId = :para WHERE comandaId = :de")
    suspend fun moverImpressoesDeComanda(de: Long, para: Long)

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

    // ---------------- caixa ----------------

    @Query("SELECT * FROM sessoes_caixa WHERE status = 'aberta' LIMIT 1")
    fun sessaoAberta(): Flow<SessaoCaixa?>

    @Query("SELECT * FROM sessoes_caixa WHERE status = 'aberta' LIMIT 1")
    suspend fun sessaoAbertaAgora(): SessaoCaixa?

    @Query("SELECT * FROM sessoes_caixa ORDER BY abertaEm DESC LIMIT 30")
    fun historicoSessoes(): Flow<List<SessaoCaixa>>

    @Query("SELECT * FROM sessoes_caixa ORDER BY abertaEm DESC LIMIT 30")
    suspend fun historicoSessoesAgora(): List<SessaoCaixa>

    @Insert
    suspend fun inserirSessao(s: SessaoCaixa): Long

    @Update
    suspend fun atualizarSessao(s: SessaoCaixa)

    @Insert
    suspend fun inserirMovimento(m: MovimentoCaixa): Long

    @Query("SELECT * FROM movimentos_caixa WHERE sessaoId = :sessaoId ORDER BY criadoEm")
    fun movimentosDaSessao(sessaoId: Long): Flow<List<MovimentoCaixa>>

    @Query("SELECT * FROM movimentos_caixa WHERE sessaoId = :sessaoId ORDER BY criadoEm")
    suspend fun movimentosDaSessaoAgora(sessaoId: Long): List<MovimentoCaixa>

    @Insert
    suspend fun inserirPagamento(p: Pagamento): Long

    @Query("SELECT * FROM pagamentos WHERE sessaoId = :sessaoId ORDER BY recebidoEm")
    suspend fun pagamentosDaSessao(sessaoId: Long): List<Pagamento>

    @Query("SELECT * FROM pagamentos WHERE comandaId = :comandaId ORDER BY recebidoEm")
    fun pagamentosDaComanda(comandaId: Long): Flow<List<Pagamento>>

    @Query("SELECT * FROM pagamentos WHERE comandaId = :comandaId ORDER BY recebidoEm")
    suspend fun pagamentosDaComandaAgora(comandaId: Long): List<Pagamento>

    @Query("SELECT COALESCE(SUM(valorCentavos),0) FROM pagamentos WHERE comandaId = :comandaId")
    suspend fun totalPagoDaComanda(comandaId: Long): Long

    // ---------------- busca pelo id do servidor (uuid) ----------------

    @Query("SELECT * FROM comandas WHERE uuid = :uuid")
    suspend fun comandaPorUuid(uuid: String): Comanda?

    @Query("SELECT * FROM pedidos WHERE uuid = :uuid")
    suspend fun pedidoPorUuid(uuid: String): Pedido?

    @Query("SELECT * FROM itens WHERE uuid = :uuid")
    suspend fun itemPorUuid(uuid: String): ItemLancado?

    @Query("SELECT * FROM itens WHERE id = :id")
    suspend fun itemAgora(id: Long): ItemLancado?

    @Insert
    suspend fun inserirItem(i: ItemLancado): Long

    @Update
    suspend fun atualizarItem(i: ItemLancado)

    @Query("SELECT * FROM sessoes_caixa WHERE uuid = :uuid")
    suspend fun sessaoPorUuid(uuid: String): SessaoCaixa?

    @Query("SELECT * FROM movimentos_caixa WHERE uuid = :uuid")
    suspend fun movimentoPorUuid(uuid: String): MovimentoCaixa?

    @Query("SELECT * FROM pagamentos WHERE uuid = :uuid")
    suspend fun pagamentoPorUuid(uuid: String): Pagamento?

    // ---------------- fila de envio pro servidor ----------------

    @Insert
    suspend fun inserirOperacao(op: OperacaoSync): Long

    @Query("SELECT * FROM sync_operacoes ORDER BY id LIMIT 1")
    suspend fun proximaOperacao(): OperacaoSync?

    @Query("SELECT * FROM sync_operacoes ORDER BY id")
    suspend fun todasOperacoes(): List<OperacaoSync>

    @Query("DELETE FROM sync_operacoes WHERE id = :id")
    suspend fun removerOperacao(id: Long)

    @Query("""UPDATE sync_operacoes SET tentativas = tentativas + 1, ultimoErro = :erro,
              ultimaTentativaEm = :quando WHERE id = :id""")
    suspend fun registrarFalhaOperacao(id: Long, erro: String, quando: Long)

    @Query("SELECT COUNT(*) FROM sync_operacoes")
    fun operacoesPendentes(): Flow<Int>

    @Query("SELECT COUNT(*) FROM sync_operacoes")
    suspend fun operacoesPendentesAgora(): Int

    @Query("SELECT COUNT(*) FROM sync_operacoes WHERE registroUuid = :uuid")
    suspend fun operacoesDoRegistro(uuid: String): Int

    /**
     * Troca um id do servidor por outro em toda a fila: no registro alvo e
     * dentro do JSON (ex.: card_id do pedido). Trocar o texto é seguro porque
     * o id é um uuid aleatório - não aparece por acaso em outro campo.
     */
    @Query("""UPDATE sync_operacoes
              SET registroUuid = CASE WHEN registroUuid = :antigo THEN :novo ELSE registroUuid END,
                  payload = REPLACE(payload, :antigo, :novo)
              WHERE registroUuid = :antigo OR INSTR(payload, :antigo) > 0""")
    suspend fun trocarUuidNasOperacoes(antigo: String, novo: String)

    @Query("SELECT valor FROM chave_valor WHERE chave = :chave")
    suspend fun lerValor(chave: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun gravarValor(cv: ChaveValor)

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

    @Query("SELECT status FROM impressoes WHERE pedidoId = :pedidoId")
    suspend fun statusDosCuponsDoPedido(pedidoId: Long): List<String>

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
