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
 * ATENÇÃO: `fallbackToDestructiveMigration` apaga o banco local quando a
 * versão muda. Serve enquanto só existe dado de teste; antes de operar de
 * verdade, trocar por migrações escritas à mão.
 */
@Database(
    entities = [
        Comanda::class, Pedido::class, ItemLancado::class, TrabalhoImpressao::class,
        SessaoCaixa::class, MovimentoCaixa::class, Pagamento::class,
        OperacaoSync::class, ChaveValor::class
    ],
    version = 4,
    exportSchema = false
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
                ).fallbackToDestructiveMigration().build().also { instancia = it }
            }
    }
}
