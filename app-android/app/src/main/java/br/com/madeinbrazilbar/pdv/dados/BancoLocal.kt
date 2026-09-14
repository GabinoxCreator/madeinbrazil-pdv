package br.com.madeinbrazilbar.pdv.dados

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

/**
 * Banco local do aparelho. O app e offline-first por exigencia da operacao:
 * se a internet do bar cair no meio do almoco, o lancamento continua.
 * O que precisa subir pro servidor fica na fila `sync_operacoes`.
 *
 * ATENÇÃO: só as versões 1, 2 e 3 (da época em que só havia dado de teste)
 * são apagadas ao atualizar o app. Da versão 4 em diante, mudar o esquema
 * EXIGE uma migração escrita à mão: sem ela o app para com erro ao abrir, em
 * vez de apagar em silêncio vendas e fila de envio que ainda não subiram.
 * O esquema de cada versão fica guardado em app/schemas pra escrever e
 * conferir essas migrações.
 */
@Database(
    entities = [
        Comanda::class, Pedido::class, ItemLancado::class, TrabalhoImpressao::class,
        SessaoCaixa::class, MovimentoCaixa::class, Pagamento::class,
        OperacaoSync::class, ChaveValor::class
    ],
    version = 4,
    exportSchema = true
)
abstract class BancoLocal : RoomDatabase() {

    abstract fun dao(): PdvDao

    companion object {
        @Volatile private var instancia: BancoLocal? = null

        fun obter(context: Context): BancoLocal =
            instancia ?: synchronized(this) {
                instancia ?: Room.databaseBuilder(
                    context.applicationContext,
                    BancoLocal::class.java,
                    "pdv.db"
                ).fallbackToDestructiveMigrationFrom(1, 2, 3).build().also { instancia = it }
            }
    }
}
