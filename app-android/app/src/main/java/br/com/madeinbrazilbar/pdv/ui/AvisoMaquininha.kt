package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.madeinbrazilbar.pdv.dados.Dinheiro
import br.com.madeinbrazilbar.pdv.dados.MetodoPagamento
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Cobrança na maquininha que ficou sem resposta (app morreu no meio, a Cielo
 * não respondeu, ou a resposta veio ilegível). Não some sozinha: o operador
 * confere no comprovante/extrato da maquininha e decide.
 */
@Composable
fun AvisoMaquininhaPendente(vm: PdvViewModel) {
    val pendente by vm.pendenteMaquininha.collectAsState()
    val cobrando by vm.cobrandoNaMaquininha.collectAsState()
    var confirmarDescarte by remember { mutableStateOf(false) }

    val p = pendente ?: return
    if (cobrando) return   // a Cielo ainda está aberta: não é aviso

    val hora = remember(p.criadoEm) { SimpleDateFormat("HH:mm", Locale("pt", "BR")).format(Date(p.criadoEm)) }

    Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Pagamento na maquininha sem confirmação", fontWeight = FontWeight.Bold)
            Text(
                "Comanda ${p.comandaNumero} · ${MetodoPagamento.rotulo(p.metodo)} · " +
                    "${Dinheiro.comSimbolo(p.valorCentavos)} · ${p.operador} às $hora",
                fontSize = 13.sp
            )
            p.problema?.let { Text(it, fontSize = 12.sp) }
            Text(
                "Confira no comprovante ou no extrato da maquininha se o valor foi pago.",
                fontSize = 12.sp
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { vm.registrarPendenteComoPago() }, modifier = Modifier.weight(1f)) {
                    Text("Registrar como pago", fontSize = 13.sp)
                }
                OutlinedButton(onClick = { confirmarDescarte = true }, modifier = Modifier.weight(1f)) {
                    Text("Descartar", fontSize = 13.sp)
                }
            }
        }
    }

    if (confirmarDescarte) {
        AlertDialog(
            onDismissRequest = { confirmarDescarte = false },
            title = { Text("Descartar a cobrança?") },
            text = {
                Text(
                    "Use só se conferiu que a maquininha NÃO cobrou " +
                        "${Dinheiro.comSimbolo(p.valorCentavos)}. Nada é registrado na comanda ${p.comandaNumero}."
                )
            },
            confirmButton = {
                Button(onClick = { vm.descartarPendenteMaquininha(); confirmarDescarte = false }) { Text("Descartar") }
            },
            dismissButton = { TextButton(onClick = { confirmarDescarte = false }) { Text("Voltar") } }
        )
    }
}
