package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.madeinbrazilbar.pdv.dados.*

/**
 * Recebimento de uma comanda. Aceita pagamento parcial e varias formas na
 * mesma conta - a operacao atual ja faz isso, entao o PDV precisa fazer.
 */
@Composable
fun DialogoRecebimento(
    vm: PdvViewModel,
    comanda: Comanda,
    aoFechar: () -> Unit
) {
    val sessao by vm.sessaoAberta.collectAsState()
    val pagamentos by vm.pagamentosDaComanda(comanda.id).collectAsState(initial = emptyList())
    var saldo by remember { mutableStateOf<SaldoComanda?>(null) }

    var metodo by remember { mutableStateOf(MetodoPagamento.DINHEIRO) }
    var valor by remember { mutableStateOf("") }
    var entregue by remember { mutableStateOf("") }

    LaunchedEffect(pagamentos, comanda) {
        saldo = vm.saldoDe(comanda.id)
        // por padrao, recebe tudo o que falta
        if (valor.isBlank()) {
            saldo?.let { valor = Dinheiro.formatar(it.faltaCentavos) }
        }
    }

    val s = saldo
    val valorCentavos = reaisParaCentavos(valor) ?: 0L
    val entregueCentavos = reaisParaCentavos(entregue)
    val troco = if (metodo == MetodoPagamento.DINHEIRO && entregueCentavos != null)
        (entregueCentavos - valorCentavos) else null

    AlertDialog(
        onDismissRequest = aoFechar,
        title = { Text("Receber comanda ${comanda.numero}") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                if (sessao == null) {
                    Surface(color = MaterialTheme.colorScheme.errorContainer) {
                        Text(
                            "O caixa está fechado. Abra o caixa antes de receber — " +
                                "é a guarda que evita diferença no fim do dia.",
                            Modifier.padding(10.dp), fontSize = 13.sp
                        )
                    }
                    return@Column
                }

                if (s == null) { CircularProgressIndicator(); return@Column }

                LinhaValor("Total da conta", Dinheiro.comSimbolo(s.totalCentavos))
                if (s.pagoCentavos > 0) {
                    LinhaValor("Já pago", Dinheiro.comSimbolo(s.pagoCentavos), cor = VerdeOk)
                }
                LinhaValor("Falta", Dinheiro.comSimbolo(s.faltaCentavos), destaque = true, cor = AzulMarca)

                HorizontalDivider()
                Text("Forma de pagamento", fontSize = 13.sp, fontWeight = FontWeight.Medium)
                Column {
                    MetodoPagamento.TODOS.chunked(3).forEach { linha ->
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            linha.forEach { m ->
                                FilterChip(
                                    selected = metodo == m,
                                    onClick = { metodo = m; entregue = "" },
                                    label = { Text(MetodoPagamento.rotulo(m), fontSize = 12.sp) }
                                )
                            }
                        }
                    }
                }

                OutlinedTextField(
                    value = valor,
                    onValueChange = { valor = it.filter { c -> c.isDigit() || c == ',' } },
                    label = { Text("Valor a receber (R$)") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth()
                )

                if (metodo == MetodoPagamento.DINHEIRO) {
                    OutlinedTextField(
                        value = entregue,
                        onValueChange = { entregue = it.filter { c -> c.isDigit() || c == ',' } },
                        label = { Text("Cliente entregou (R$) — opcional") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth()
                    )
                    troco?.let { t ->
                        if (t >= 0) {
                            LinhaValor("TROCO", Dinheiro.comSimbolo(t), destaque = true, cor = VerdeOk)
                        } else {
                            Text(
                                "Faltam ${Dinheiro.comSimbolo(-t)} para cobrir o valor",
                                color = VermelhoAlerta, fontSize = 13.sp
                            )
                        }
                    }
                }

                if (valorCentavos in 1 until s.faltaCentavos) {
                    Text(
                        "Pagamento parcial: sobra ${Dinheiro.comSimbolo(s.faltaCentavos - valorCentavos)} " +
                            "para receber depois.",
                        fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                if (pagamentos.isNotEmpty()) {
                    HorizontalDivider()
                    Text("Já recebido", fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    pagamentos.forEach { p ->
                        LinhaValor(
                            MetodoPagamento.rotulo(p.metodo) +
                                (if (p.trocoCentavos > 0) " (troco ${Dinheiro.formatar(p.trocoCentavos)})" else ""),
                            Dinheiro.comSimbolo(p.valorCentavos)
                        )
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    vm.receber(
                        comanda.id, metodo, valorCentavos,
                        if (metodo == MetodoPagamento.DINHEIRO) entregueCentavos else null
                    )
                    aoFechar()
                },
                enabled = sessao != null && s != null && valorCentavos > 0 &&
                    valorCentavos <= (s?.faltaCentavos ?: 0L) &&
                    (troco == null || troco >= 0)
            ) { Text("Receber") }
        },
        dismissButton = { TextButton(onClick = aoFechar) { Text("Fechar") } }
    )
}
