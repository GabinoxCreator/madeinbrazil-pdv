package br.com.madeinbrazilbar.pdv.sincronia

import androidx.room.withTransaction
import br.com.madeinbrazilbar.pdv.dados.BancoLocal
import br.com.madeinbrazilbar.pdv.dados.OperacaoSync
import br.com.madeinbrazilbar.pdv.dados.TipoOperacao
import kotlinx.serialization.json.JsonObject

/**
 * Porta de entrada da fila de envio. Os repositórios gravam no aparelho e
 * registram aqui o que precisa subir - tudo dentro de `emTransacao`, pra que
 * a gravação local e o pedido de envio nunca fiquem pela metade.
 */
class Sincronia(
    private val banco: BancoLocal,
    private val relogio: () -> Long = System::currentTimeMillis
) {
    private val dao = banco.dao()

    suspend fun <T> emTransacao(bloco: suspend () -> T): T = banco.withTransaction { bloco() }

    suspend fun inserir(tabela: String, uuid: String, registro: JsonObject) {
        dao.inserirOperacao(
            OperacaoSync(
                tabela = tabela, tipo = TipoOperacao.INSERIR, registroUuid = uuid,
                payload = registro.toString(), criadaEm = relogio()
            )
        )
    }

    suspend fun atualizar(tabela: String, uuid: String, campos: JsonObject) {
        dao.inserirOperacao(
            OperacaoSync(
                tabela = tabela, tipo = TipoOperacao.ATUALIZAR, registroUuid = uuid,
                payload = campos.toString(), criadaEm = relogio()
            )
        )
    }
}
