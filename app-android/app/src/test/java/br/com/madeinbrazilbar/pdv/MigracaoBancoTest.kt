package br.com.madeinbrazilbar.pdv

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.core.app.ApplicationProvider
import br.com.madeinbrazilbar.pdv.dados.BancoLocal
import br.com.madeinbrazilbar.pdv.dados.StatusImpressao
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * Atualização do app com o banco da versão 4 no aparelho: a migração tem de
 * manter a fila de impressão e a fila de envio. O banco v4 é montado a partir
 * do esquema guardado em app/schemas (o mesmo que o app antigo criava) e
 * aberto com a configuração de verdade do BancoLocal - se a migração deixar o
 * esquema diferente do que o Room espera, ele recusa abrir e o teste falha.
 */
@RunWith(RobolectricTestRunner::class)
class MigracaoBancoTest {

    private val contexto: Context = ApplicationProvider.getApplicationContext()
    private val nome = "migracao-teste.db"

    @After
    fun limpar() {
        contexto.deleteDatabase(nome)
    }

    private fun esquema(versao: Int): File {
        val caminho = "schemas/br.com.madeinbrazilbar.pdv.dados.BancoLocal/$versao.json"
        return listOf(File(caminho), File("app/$caminho")).first { it.exists() }
    }

    /** Cria o banco exatamente como a versão 4 do app deixava. */
    private fun criarBancoV4(dados: (androidx.sqlite.db.SupportSQLiteDatabase) -> Unit) {
        val banco = Json.parseToJsonElement(esquema(4).readText()).jsonObject["database"]!!.jsonObject
        val ajudante = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(contexto)
                .name(nome)
                .callback(object : SupportSQLiteOpenHelper.Callback(4) {
                    override fun onCreate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                        for (entidade in banco["entities"]!!.jsonArray.map { it.jsonObject }) {
                            val tabela = entidade["tableName"]!!.jsonPrimitive.content
                            db.execSQL(entidade["createSql"]!!.jsonPrimitive.content.replace("\${TABLE_NAME}", tabela))
                            entidade["indices"]?.jsonArray?.forEach { indice ->
                                db.execSQL(
                                    indice.jsonObject["createSql"]!!.jsonPrimitive.content.replace("\${TABLE_NAME}", tabela)
                                )
                            }
                        }
                        banco["setupQueries"]!!.jsonArray.forEach { db.execSQL(it.jsonPrimitive.content) }
                    }

                    override fun onUpgrade(db: androidx.sqlite.db.SupportSQLiteDatabase, antiga: Int, nova: Int) = Unit
                })
                .build()
        )
        ajudante.writableDatabase.use { dados(it) }
        ajudante.close()
    }

    @Test
    fun `migracao 4 para 5 preserva a fila de impressao e a fila de envio`() = runBlocking {
        contexto.deleteDatabase(nome)
        criarBancoV4 { db ->
            db.execSQL(
                """INSERT INTO impressoes (id, pontoId, tipo, conteudo, previa, status, tentativas,
                   ultimoErro, comandaId, pedidoId, descricao, criadoEm, impressoEm)
                   VALUES (7, 'cozinha', 'pedido', X'1B40414243', 'ABC', 'falha', 3,
                   'sem resposta', 1, 2, 'Comanda 15 · Cozinha', 1000, NULL)"""
            )
            db.execSQL(
                """INSERT INTO sync_operacoes (id, tabela, tipo, registroUuid, payload, criadaEm, tentativas)
                   VALUES (1, 'pdv_cards', 'inserir', 'u-1', '{"id":"u-1"}', 1000, 0)"""
            )
        }

        val banco = BancoLocal.configurar(Room.databaseBuilder(contexto, BancoLocal::class.java, nome))
            .allowMainThreadQueries().build()
        try {
            val dao = banco.dao()
            val t = dao.historicoImpressao().first().single()
            assertEquals(7L, t.id)
            assertEquals(StatusImpressao.FALHA, t.status)
            assertEquals(3, t.tentativas)
            assertEquals("sem resposta", t.ultimoErro)
            assertEquals(2L, t.pedidoId)
            assertArrayEquals(byteArrayOf(0x1B, 0x40, 0x41, 0x42, 0x43), t.conteudo)
            assertNull("cupom antigo é do PDV, não do delivery", t.trabalhoDeliveryId)
            assertFalse(t.concluidoNoServidor)
            assertEquals(1, dao.operacoesPendentesAgora())

            // as colunas novas funcionam depois de migrar
            assertTrue(dao.impressoesDeliverySemConclusao().isEmpty())
        } finally {
            banco.close()
        }
    }

    @Test
    fun `esquema da versao 5 esta guardado`() {
        val v5 = Json.parseToJsonElement(esquema(5).readText()).jsonObject["database"]!!.jsonObject
        assertEquals(5, v5["version"]!!.jsonPrimitive.content.toInt())
        val impressoes = v5["entities"]!!.jsonArray.map { it.jsonObject }
            .single { it["tableName"]!!.jsonPrimitive.content == "impressoes" }
        val sql = impressoes["createSql"]!!.jsonPrimitive.content
        assertTrue(sql.contains("`trabalhoDeliveryId` TEXT"))
        assertTrue(sql.contains("`concluidoNoServidor` INTEGER NOT NULL DEFAULT 0"))
    }
}
