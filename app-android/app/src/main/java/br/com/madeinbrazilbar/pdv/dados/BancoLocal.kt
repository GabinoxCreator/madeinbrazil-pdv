package br.com.madeinbrazilbar.pdv.dados

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

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
    version = 5,
    exportSchema = true
)
abstract class BancoLocal : RoomDatabase() {

    abstract fun dao(): PdvDao

    companion object {
        @Volatile private var instancia: BancoLocal? = null

        /** v5: cupom ligado ao trabalho da fila do delivery no servidor. */
        val MIGRACAO_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE impressoes ADD COLUMN trabalhoDeliveryId TEXT")
                db.execSQL("ALTER TABLE impressoes ADD COLUMN concluidoNoServidor INTEGER NOT NULL DEFAULT 0")
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_impressoes_trabalhoDeliveryId ON impressoes (trabalhoDeliveryId)"
                )
            }
        }

        /** Mesma configuração do app de verdade, usada também no teste de migração. */
        fun configurar(construtor: RoomDatabase.Builder<BancoLocal>): RoomDatabase.Builder<BancoLocal> =
            construtor.addMigrations(MIGRACAO_4_5).fallbackToDestructiveMigrationFrom(1, 2, 3)

        fun obter(context: Context): BancoLocal =
            instancia ?: synchronized(this) {
                instancia ?: configurar(
                    Room.databaseBuilder(context.applicationContext, BancoLocal::class.java, "pdv.db")
                ).build().also { instancia = it }
            }
    }
}
