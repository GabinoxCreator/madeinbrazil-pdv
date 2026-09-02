package br.com.madeinbrazilbar.pdv

import br.com.madeinbrazilbar.pdv.impressao.Impressora
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Descoberta das termicas na rede local.
 *
 * A especificacao mapeou as impressoras em 192.168.0.x, mas isso nao esta
 * confirmado - por isso a faixa e descoberta a partir do IP do proprio
 * aparelho, e nao chumbada no codigo.
 */
object Rede {

    /** Ex: "192.168.0.70" -> "192.168.0". Nulo se nao houver rede local. */
    suspend fun faixaLocal(): String? = withContext(Dispatchers.IO) {
        try {
            NetworkInterface.getNetworkInterfaces().toList()
                .asSequence()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList().asSequence() }
                .filterIsInstance<Inet4Address>()
                .filter { !it.isLoopbackAddress && it.isSiteLocalAddress }
                .map { it.hostAddress ?: "" }
                .firstOrNull { it.count { c -> c == '.' } == 3 }
                ?.substringBeforeLast('.')
        } catch (e: Exception) {
            null
        }
    }

    /** Varre faixa.1 ate faixa.254 procurando quem atende na porta 9100. */
    suspend fun procurarImpressoras(faixa: String): List<String> = coroutineScope {
        (1..254)
            .map { fim ->
                val ip = "$faixa.$fim"
                async(Dispatchers.IO) { if (Impressora.responde(ip)) ip else null }
            }
            .awaitAll()
            .filterNotNull()
    }

    /** O que a especificacao levantou em campo em 31/08/2026. */
    val pontosConhecidos = mapOf(
        "192.168.0.70" to "Caixa",
        "192.168.0.71" to "Cozinha (IP não confirmado)",
        "192.168.0.72" to "Bar de drink",
        "192.168.0.73" to "Bar de cerveja"
    )
}
