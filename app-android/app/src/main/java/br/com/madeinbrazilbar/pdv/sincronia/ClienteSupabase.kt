package br.com.madeinbrazilbar.pdv.sincronia

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * Conversa com o servidor do PDV (Supabase do projeto Lovable próprio).
 *
 * Entra com a conta do terminal (e-mail e senha) e usa o token nas chamadas.
 * Se o token vencer, entra de novo sozinho e repete a chamada uma vez.
 */
class ClienteSupabase(
    private val url: String,
    private val chavePublica: String,
    private val email: String,
    private val senha: String,
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build()
) : ClienteServidor {

    private val json = Json { ignoreUnknownKeys = true }
    private val tipoJson = "application/json; charset=utf-8".toMediaType()
    private val trava = Mutex()
    @Volatile private var token: String? = null

    // ------------------------------------------------------------ login

    private suspend fun obterToken(renovar: Boolean): String = trava.withLock {
        val atual = token
        if (!renovar && atual != null) atual else entrar().also { token = it }
    }

    private fun entrar(): String {
        val corpo = buildJsonObject {
            put("email", email)
            put("password", senha)
        }.toString()
        val requisicao = Request.Builder()
            .url("$url/auth/v1/token?grant_type=password")
            .header("apikey", chavePublica)
            .post(corpo.toRequestBody(tipoJson))
            .build()
        val (codigo, texto) = executar(requisicao)
        if (codigo !in 200..299) {
            throw ErroServidor(
                "Login do terminal recusado (HTTP $codigo): ${mensagem(texto)}",
                codigo, temporario = codigo >= 500
            )
        }
        return json.parseToJsonElement(texto).jsonObject.texto("access_token")
            ?: throw ErroServidor("O servidor não devolveu o token de acesso", codigo, true)
    }

    /**
     * Entra de novo AGORA, ignorando o token guardado. Serve pra conferir
     * e-mail e senha digitados na tela do terminal antes de gravá-los.
     * Qualquer falha sai como ErroServidor, com a mensagem pra mostrar.
     */
    suspend fun renovarLogin() {
        withContext(Dispatchers.IO) {
            try {
                obterToken(renovar = true)
            } catch (e: ErroServidor) {
                throw e
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw ErroServidor("Resposta inesperada do servidor no login: ${e.message}", 0, true)
            }
        }
    }

    // ---------------------------------------------------------- chamadas

    private fun executar(requisicao: Request): Pair<Int, String> = try {
        http.newCall(requisicao).execute().use { r -> r.code to (r.body?.string() ?: "") }
    } catch (e: IOException) {
        throw ErroServidor("Sem conexão com o servidor: ${e.message}", 0, true)
    }

    private suspend fun tentar(
        montar: (Request.Builder) -> Request.Builder,
        renovarToken: Boolean
    ): Pair<Int, String> {
        val tk = obterToken(renovarToken)
        val base = Request.Builder()
            .header("apikey", chavePublica)
            .header("Authorization", "Bearer $tk")
        return executar(montar(base).build())
    }

    private suspend fun chamar(montar: (Request.Builder) -> Request.Builder): String =
        withContext(Dispatchers.IO) {
            val primeira = tentar(montar, renovarToken = false)
            val (codigo, texto) = if (primeira.first == 401) tentar(montar, renovarToken = true) else primeira
            if (codigo !in 200..299) {
                throw ErroServidor(
                    "HTTP $codigo · ${mensagem(texto)}",
                    codigo,
                    temporario = codigo >= 500 || codigo == 401 || codigo == 408 || codigo == 429
                )
            }
            texto
        }

    private fun mensagem(texto: String): String = try {
        val j = json.parseToJsonElement(texto).jsonObject
        listOfNotNull(j.texto("code"), j.texto("message") ?: j.texto("msg") ?: j.texto("error_description"), j.texto("details"))
            .joinToString(" · ")
            .ifBlank { texto.take(200) }
    } catch (e: Exception) {
        texto.take(200)
    }

    // ------------------------------------------------------- operações

    override suspend fun inserir(tabela: String, registro: JsonObject) {
        chamar {
            it.url("$url/rest/v1/$tabela?on_conflict=id")
                .header("Prefer", "resolution=ignore-duplicates,return=minimal")
                .post(JsonArray(listOf(registro)).toString().toRequestBody(tipoJson))
        }
    }

    override suspend fun atualizar(tabela: String, id: String, campos: JsonObject) {
        val texto = chamar {
            it.url("$url/rest/v1/$tabela?id=eq.$id")
                .header("Prefer", "return=representation")
                .patch(campos.toString().toRequestBody(tipoJson))
        }
        if (json.parseToJsonElement(texto).jsonArray.isEmpty()) {
            throw ErroServidor("O registro $id ainda não existe no servidor ($tabela)", 404, temporario = true)
        }
    }

    override suspend fun buscar(tabela: String, filtros: List<Pair<String, String>>): List<JsonObject> {
        val consulta = filtros.joinToString("&") { (chave, valor) -> chave + "=" + URLEncoder.encode(valor, "UTF-8") }
        val texto = chamar { it.url("$url/rest/v1/$tabela?$consulta").get() }
        return json.parseToJsonElement(texto).jsonArray.map { it.jsonObject }
    }
}
