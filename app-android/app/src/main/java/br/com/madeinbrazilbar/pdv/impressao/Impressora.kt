package br.com.madeinbrazilbar.pdv.impressao

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Cliente TCP das termicas. ESC/POS cru na porta 9100 (padrao RAW/JetDirect).
 */
object Impressora {

    const val PORTA_PADRAO = 9100

    private const val TIMEOUT_CONEXAO_MS = 2000
    private const val TIMEOUT_ESCRITA_MS = 5000

    sealed class Resultado {
        object Ok : Resultado()
        data class Falha(val motivo: String) : Resultado()
    }

    /** Envia o buffer ESC/POS. Nunca lanca excecao: devolve o motivo da falha. */
    suspend fun imprimir(
        ip: String,
        dados: ByteArray,
        porta: Int = PORTA_PADRAO
    ): Resultado = withContext(Dispatchers.IO) {
        try {
            Socket().use { socket ->
                socket.soTimeout = TIMEOUT_ESCRITA_MS
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(ip, porta), TIMEOUT_CONEXAO_MS)
                socket.getOutputStream().apply {
                    write(dados)
                    flush()
                }
            }
            Resultado.Ok
        } catch (e: IOException) {
            Resultado.Falha(e.message ?: e.javaClass.simpleName)
        } catch (e: IllegalArgumentException) {
            Resultado.Falha("IP invalido: $ip")
        }
    }

    /** Confere se ha algo escutando em ip:porta. Usado na varredura da rede. */
    suspend fun responde(
        ip: String,
        porta: Int = PORTA_PADRAO,
        timeoutMs: Int = 400
    ): Boolean = withContext(Dispatchers.IO) {
        try {
            Socket().use { it.connect(InetSocketAddress(ip, porta), timeoutMs) }
            true
        } catch (e: IOException) {
            false
        }
    }
}
