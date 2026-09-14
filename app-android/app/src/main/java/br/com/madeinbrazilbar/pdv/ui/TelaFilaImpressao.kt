package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.madeinbrazilbar.pdv.dados.StatusImpressao
import br.com.madeinbrazilbar.pdv.dados.TrabalhoImpressao
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val hora = SimpleDateFormat("HH:mm:ss", Locale("pt", "BR"))

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TelaFilaImpressao(vm: PdvViewModel, aoVoltar: () -> Unit) {
    val historico by vm.historicoImpressao.collectAsState()
    var previa by remember { mutableStateOf<String?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Fila de impressão") },
                navigationIcon = { TextButton(onClick = aoVoltar) { Text("Voltar") } },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = AzulMarca,
                    titleContentColor = androidx.compose.ui.graphics.Color.White,
                    navigationIconContentColor = AmareloMarca
                )
            )
        }
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Text(
                "Nenhuma impressão acontece fora desta fila. O que falhar fica aqui " +
                    "para reimprimir — o consumo já está lançado na comanda de qualquer forma.",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp, 12.dp, 16.dp, 4.dp)
            )

            if (historico.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Nada na fila ainda.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 24.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(historico, key = { it.id }) { t ->
                        CartaoImpressao(t, aoVerPrevia = { previa = t.previa }, aoReimprimir = { vm.reimprimir(t.id) })
                    }
                }
            }
        }
    }

    previa?.let { texto ->
        AlertDialog(
            onDismissRequest = { previa = null },
            title = { Text("Cupom") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(texto, fontFamily = FontFamily.Monospace, fontSize = 9.sp, lineHeight = 12.sp)
                }
            },
            confirmButton = { TextButton(onClick = { previa = null }) { Text("Fechar") } }
        )
    }
}

@Composable
private fun CartaoImpressao(
    t: TrabalhoImpressao,
    aoVerPrevia: () -> Unit,
    aoReimprimir: () -> Unit
) {
    val (rotulo, cor) = when (t.status) {
        StatusImpressao.ENVIADO -> "IMPRESSO" to VerdeOk
        StatusImpressao.FALHA -> "FALHOU" to VermelhoAlerta
        else -> "NA FILA" to AzulMarca
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Etiqueta(rotulo, cor)
                Spacer(Modifier.width(8.dp))
                Text(
                    hora.format(Date(t.impressoEm ?: t.criadoEm)),
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (t.tentativas > 0) {
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "${t.tentativas} tentativa(s)",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            Spacer(Modifier.height(4.dp))
            Text(t.descricao, fontWeight = FontWeight.Medium, fontSize = 14.sp)
            t.ultimoErro?.let {
                Text(it, fontSize = 12.sp, color = VermelhoAlerta)
            }
            Row {
                TextButton(onClick = aoVerPrevia) { Text("Ver cupom") }
                // cupom do delivery: a reimpressão vem do servidor, não daqui
                if (t.status == StatusImpressao.FALHA && t.trabalhoDeliveryId == null) {
                    TextButton(onClick = aoReimprimir) { Text("Reimprimir") }
                }
            }
        }
    }
}
