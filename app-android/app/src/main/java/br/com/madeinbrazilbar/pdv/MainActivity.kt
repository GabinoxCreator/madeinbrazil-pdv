package br.com.madeinbrazilbar.pdv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import br.com.madeinbrazilbar.pdv.impressao.Cupons
import br.com.madeinbrazilbar.pdv.impressao.Impressora
import kotlinx.coroutines.launch

private val AZUL_MARCA = Color(0xFF001CEE)
private val AMARELO_MARCA = Color(0xFFF5E400)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = AZUL_MARCA)) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    TelaDiagnostico()
                }
            }
        }
    }
}

@Composable
private fun TelaDiagnostico() {
    val escopo = rememberCoroutineScope()

    var ip by remember { mutableStateOf("192.168.0.70") }
    var ocupado by remember { mutableStateOf(false) }
    val registro = remember { mutableStateListOf<String>() }

    fun log(linha: String) {
        registro.add(0, linha)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Cabecalho()

        Text(
            "Antes de qualquer coisa, a impressão precisa funcionar. " +
                "Conecte este aparelho no Wi-Fi do bar e teste as térmicas.",
            style = MaterialTheme.typography.bodyMedium
        )

        OutlinedTextField(
            value = ip,
            onValueChange = { ip = it.trim() },
            label = { Text("IP da impressora") },
            singleLine = true,
            enabled = !ocupado,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth()
        )

        Button(
            onClick = {
                ocupado = true
                val nome = Rede.pontosConhecidos[ip] ?: "Desconhecido"
                log("Enviando cupom de teste para $ip ($nome)…")
                escopo.launch {
                    when (val r = Impressora.imprimir(ip, Cupons.teste(nome, ip))) {
                        is Impressora.Resultado.Ok ->
                            log("OK — enviado. Confira se saiu na térmica.")
                        is Impressora.Resultado.Falha ->
                            log("FALHOU — ${r.motivo}")
                    }
                    ocupado = false
                }
            },
            enabled = !ocupado && ip.isNotBlank(),
            modifier = Modifier.fillMaxWidth().height(52.dp)
        ) { Text("Imprimir cupom de teste") }

        OutlinedButton(
            onClick = {
                ocupado = true
                log("Procurando impressoras na rede…")
                escopo.launch {
                    val faixa = Rede.faixaLocal()
                    if (faixa == null) {
                        log("Sem rede local. Este aparelho está no Wi-Fi?")
                    } else {
                        log("Rede deste aparelho: $faixa.x")
                        if (faixa != "192.168.0") {
                            log("Atenção: a especificação mapeou as térmicas em 192.168.0.x")
                        }
                        val achadas = Rede.procurarImpressoras(faixa)
                        if (achadas.isEmpty()) {
                            log("Nenhuma impressora respondeu em $faixa.x")
                        } else {
                            log("${achadas.size} impressora(s) encontrada(s):")
                            achadas.forEach { encontrado ->
                                log("   $encontrado  ${Rede.pontosConhecidos[encontrado] ?: "(fora do mapa)"}")
                            }
                            ip = achadas.first()
                        }
                    }
                    ocupado = false
                }
            },
            enabled = !ocupado,
            modifier = Modifier.fillMaxWidth().height(52.dp)
        ) { Text("Procurar impressoras na rede") }

        if (ocupado) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }

        if (registro.isNotEmpty()) {
            HorizontalDivider()
            Text("Registro", style = MaterialTheme.typography.titleSmall)
            registro.forEach { linha ->
                Text(
                    linha,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }
    }
}

@Composable
private fun Cabecalho() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(AZUL_MARCA)
            .padding(vertical = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            "MADE IN BRAZIL",
            color = AMARELO_MARCA,
            fontWeight = FontWeight.Bold,
            fontSize = 22.sp
        )
        Text("PDV · diagnóstico de impressão", color = Color.White, fontSize = 13.sp)
    }
}
