package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.madeinbrazilbar.pdv.Rede
import br.com.madeinbrazilbar.pdv.impressao.Cupons
import br.com.madeinbrazilbar.pdv.impressao.Impressora
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TelaDiagnostico(vm: PdvViewModel, aoVoltar: () -> Unit) {
    val escopo = rememberCoroutineScope()
    var ip by remember { mutableStateOf(vm.cardapio.pontosProducao.first().ip) }
    var ocupado by remember { mutableStateOf(false) }
    val registro = remember { mutableStateListOf<String>() }
    fun log(l: String) = registro.add(0, l)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Impressoras") },
                navigationIcon = { TextButton(onClick = aoVoltar) { Text("Voltar") } },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = AzulMarca,
                    titleContentColor = androidx.compose.ui.graphics.Color.White,
                    navigationIconContentColor = AmareloMarca
                )
            )
        }
    ) { padding ->
        Column(
            Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                "Conecte este aparelho no Wi-Fi do bar e teste as térmicas.",
                style = MaterialTheme.typography.bodyMedium
            )

            vm.cardapio.pontosProducao.forEach { p ->
                Card(Modifier.fillMaxWidth()) {
                    Row(
                        Modifier.padding(12.dp).fillMaxWidth(),
                        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(p.nome, fontSize = 15.sp)
                            Text(
                                "${p.ip}:${p.porta}" + if (!p.ipConfirmado) "  · IP a confirmar" else "",
                                fontSize = 12.sp,
                                color = if (p.ipConfirmado) MaterialTheme.colorScheme.onSurfaceVariant
                                else VermelhoAlerta
                            )
                        }
                        TextButton(onClick = { ip = p.ip }) { Text("Usar") }
                    }
                }
            }

            OutlinedTextField(
                value = ip, onValueChange = { ip = it.trim() },
                label = { Text("IP da impressora") }, singleLine = true, enabled = !ocupado,
                modifier = Modifier.fillMaxWidth()
            )

            Button(
                onClick = {
                    ocupado = true
                    val nome = vm.cardapio.pontosProducao.firstOrNull { it.ip == ip }?.nome ?: "Desconhecido"
                    log("Enviando cupom de teste para $ip ($nome)…")
                    escopo.launch {
                        when (val r = Impressora.imprimir(ip, Cupons.teste(nome, ip).bytes())) {
                            is Impressora.Resultado.Ok -> log("OK — enviado. Confira se saiu na térmica.")
                            is Impressora.Resultado.Falha -> log("FALHOU — ${r.motivo}")
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
                        if (faixa == null) log("Sem rede local. Este aparelho está no Wi-Fi?")
                        else {
                            log("Rede deste aparelho: $faixa.x")
                            val esperada = vm.cardapio.pontosProducao.first().ip.substringBeforeLast('.')
                            if (faixa != esperada)
                                log("Atenção: as térmicas estão mapeadas em $esperada.x")
                            val achadas = Rede.procurarImpressoras(faixa)
                            if (achadas.isEmpty()) log("Nenhuma impressora respondeu em $faixa.x")
                            else {
                                log("${achadas.size} impressora(s) encontrada(s):")
                                achadas.forEach { a ->
                                    val nome = vm.cardapio.pontosProducao.firstOrNull { it.ip == a }?.nome
                                    log("   $a  ${nome ?: "(fora do mapa)"}")
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

            if (ocupado) LinearProgressIndicator(Modifier.fillMaxWidth())

            if (registro.isNotEmpty()) {
                HorizontalDivider()
                Text("Registro", style = MaterialTheme.typography.titleSmall)
                registro.forEach {
                    Text(it, fontFamily = FontFamily.Monospace, fontSize = 12.sp, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}
