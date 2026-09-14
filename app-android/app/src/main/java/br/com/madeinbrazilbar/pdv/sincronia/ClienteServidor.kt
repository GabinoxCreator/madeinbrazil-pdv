package br.com.madeinbrazilbar.pdv.sincronia

import kotlinx.serialization.json.JsonObject

/**
 * Erro vindo do servidor (ou da falta dele).
 *
 * @param status código HTTP; 0 quando nem chegou no servidor (sem rede).
 * @param temporario se tentar de novo mais tarde pode resolver sozinho.
 */
class ErroServidor(
    mensagem: String,
    val status: Int = 0,
    val temporario: Boolean = true
) : Exception(mensagem)

/**
 * O que o motor de sincronização precisa do servidor. Existe como interface
 * pra poder testar o motor com um servidor falso, sem internet.
 */
interface ClienteServidor {

    /** Cria o registro. Se já existir (mesmo id), não faz nada - enviar duas vezes não duplica. */
    suspend fun inserir(tabela: String, registro: JsonObject)

    /** Altera só os campos informados do registro com esse id. */
    suspend fun atualizar(tabela: String, id: String, campos: JsonObject)

    /** Consulta com filtros no formato do servidor (ex.: "status" to "eq.aberta"). */
    suspend fun buscar(tabela: String, filtros: List<Pair<String, String>>): List<JsonObject>
}
