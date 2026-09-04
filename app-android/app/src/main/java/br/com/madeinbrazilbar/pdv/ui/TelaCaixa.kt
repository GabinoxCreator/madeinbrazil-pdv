package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.madeinbrazilbar.pdv.dados.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val hhmm = SimpleDateFormat("HH:mm", Locale("pt", "BR"))

/** Le "12,50" ou "12.50" e devolve centavos. Nulo se nao for numero. */
internal fun reaisParaCentavos(texto: String): Long? =
    texto.trim().replace(".", "").replace(",", ".").toDoubleOrNull()?.let { Dinheiro.deReais(it) }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TelaCaixa(vm: PdvViewModel, aoVoltar: () -> Unit) {
    val sessao by vm.sessaoAberta.collectAsState()
    val ocupado by vm.ocupado.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Caixa") },
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
            if (ocupado) LinearProgressIndicator(Modifier.fillMaxWidth())
            val s = sessao
            if (s == null) AbrirCaixa(vm) else CaixaAberto(vm, s)
        }
    }
}

// ------------------------------------------------------------------ abrir

@Composable
private fun AbrirCaixa(vm: PdvViewModel) {
    var fundo by remember { mutableStateOf("") }

    Column(
        Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text("Caixa fechado", style = MaterialTheme.typography.titleLarge)
        Text(
            "Enquanto o caixa estiver fechado, nenhum recebimento é aceito. " +
                "É a guarda que evita dinheiro entrando fora de sessão e diferença no fim do dia.",
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        OutlinedTextField(
            value = fundo,
            onValueChange = { fundo = it.filter { c -> c.isDigit() || c == ',' } },
            label = { Text("Fundo de troco (R$)") },
            placeholder = { Text("0,00") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth()
        )

        Button(
            onClick = { vm.abrirCaixa(reaisParaCentavos(fundo) ?: 0L) },
            modifier = Modifier.fillMaxWidth().height(52.dp)
        ) { Text("ABRIR CAIXA") }
    }
}

// ----------------------------------------------------------- caixa aberto

@Composable
private fun CaixaAberto(vm: PdvViewModel, sessao: SessaoCaixa) {
    val escopo = rememberCoroutineScope()
    val movimentos by vm.movimentos(sessao.id).collectAsState(initial = emptyList())
    var apuracao by remember { mutableStateOf<Fechamento?>(null) }
    var dialogo by remember { mutableStateOf<String?>(null) }   // "sangria" | "suprimento" | "fechar"

    // recalcula a apuracao sempre que algo muda
    LaunchedEffect(movimentos, sessao) { apuracao = vm.apuracao() }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Etiqueta("ABERTO", VerdeOk)
            Spacer(Modifier.width(8.dp))
            Text(
                "por ${sessao.abertaPor} às ${hhmm.format(Date(sessao.abertaEm))}",
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        val f = apuracao
        if (f == null) {
            CircularProgressIndicator()
        } else {
            HorizontalDivider()
            Text("Dinheiro na gaveta", style = MaterialTheme.typography.titleSmall)
            LinhaValor("Fundo de troco", Dinheiro.comSimbolo(f.fundoTrocoCentavos))
            if (f.suprimentosCentavos > 0)
                LinhaValor("Suprimentos", "+ " + Dinheiro.comSimbolo(f.suprimentosCentavos), cor = VerdeOk)
            if (f.sangriasCentavos > 0)
                LinhaValor("Sangrias", "− " + Dinheiro.comSimbolo(f.sangriasCentavos), cor = VermelhoAlerta)
            LinhaValor("Recebido em dinheiro", Dinheiro.comSimbolo(f.dinheiroRecebidoCentavos))
            HorizontalDivider()
            LinhaValor(
                "DEVE TER NA GAVETA",
                Dinheiro.comSimbolo(f.esperadoEmDinheiroCentavos),
                destaque = true, cor = AzulMarca
            )

            if (f.porMetodo.isNotEmpty()) {
                Spacer(Modifier.height(6.dp))
                HorizontalDivider()
                Text("Recebido por forma", style = MaterialTheme.typography.titleSmall)
                MetodoPagamento.TODOS.forEach { m ->
                    val v = f.porMetodo[m] ?: 0L
                    if (v > 0) LinhaValor(MetodoPagamento.rotulo(m), Dinheiro.comSimbolo(v))
                }
                HorizontalDivider()
                LinhaValor("Total recebido", Dinheiro.comSimbolo(f.totalRecebidoCentavos), destaque = true)
                LinhaValor("Comandas recebidas", f.comandasRecebidas.toString())
            }
        }

        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = { dialogo = TipoMovimento.SANGRIA }, modifier = Modifier.weight(1f)) {
                Text("Sangria")
            }
            OutlinedButton(onClick = { dialogo = TipoMovimento.SUPRIMENTO }, modifier = Modifier.weight(1f)) {
                Text("Suprimento")
            }
        }

        if (movimentos.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            Text("Movimentos", style = MaterialTheme.typography.titleSmall)
            movimentos.reversed().forEach { m ->
                Row(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            (if (m.tipo == TipoMovimento.SANGRIA) "Sangria" else "Suprimento") +
                                " · ${hhmm.format(Date(m.criadoEm))}",
                            fontSize = 13.sp
                        )
                        Text(m.motivo, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(
                        (if (m.tipo == TipoMovimento.SANGRIA) "− " else "+ ") +
                            Dinheiro.comSimbolo(m.valorCentavos),
                        fontSize = 13.sp,
                        color = if (m.tipo == TipoMovimento.SANGRIA) VermelhoAlerta else VerdeOk
                    )
                }
            }
        }

        Spacer(Modifier.height(10.dp))
        Button(
            onClick = { dialogo = "fechar" },
            modifier = Modifier.fillMaxWidth().height(52.dp)
        ) { Text("FECHAR CAIXA") }
        Spacer(Modifier.height(20.dp))
    }

    when (dialogo) {
        TipoMovimento.SANGRIA, TipoMovimento.SUPRIMENTO -> DialogoMovimento(
            tipo = dialogo!!,
            aoFechar = { dialogo = null },
            aoConfirmar = { valor, motivo ->
                vm.registrarMovimento(dialogo!!, valor, motivo); dialogo = null
            }
        )
        "fechar" -> DialogoFechamento(
            vm = vm,
            aoFechar = { dialogo = null },
            aoConfirmar = { contado, obs -> vm.fecharCaixa(contado, obs); dialogo = null }
        )
    }
}

@Composable
private fun DialogoMovimento(
    tipo: String,
    aoFechar: () -> Unit,
    aoConfirmar: (Long, String) -> Unit
) {
    var valor by remember { mutableStateOf("") }
    var motivo by remember { mutableStateOf("") }
    val sangria = tipo == TipoMovimento.SANGRIA

    AlertDialog(
        onDismissRequest = aoFechar,
        title = { Text(if (sangria) "Sangria" else "Suprimento") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    if (sangria) "Retirada de dinheiro da gaveta."
                    else "Entrada de dinheiro na gaveta.",
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                OutlinedTextField(
                    value = valor,
                    onValueChange = { valor = it.filter { c -> c.isDigit() || c == ',' } },
                    label = { Text("Valor (R$)") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = motivo, onValueChange = { motivo = it },
                    label = { Text("Motivo") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { aoConfirmar(reaisParaCentavos(valor) ?: 0L, motivo) },
                enabled = valor.isNotBlank() && motivo.isNotBlank()
            ) { Text("Registrar") }
        },
        dismissButton = { TextButton(onClick = aoFechar) { Text("Cancelar") } }
    )
}

@Composable
private fun DialogoFechamento(
    vm: PdvViewModel,
    aoFechar: () -> Unit,
    aoConfirmar: (Long, String?) -> Unit
) {
    val escopo = rememberCoroutineScope()
    var contado by remember { mutableStateOf("") }
    var obs by remember { mutableStateOf("") }
    var previa by remember { mutableStateOf<Fechamento?>(null) }

    LaunchedEffect(contado) {
        previa = vm.apuracao(reaisParaCentavos(contado))
    }

    AlertDialog(
        onDismissRequest = aoFechar,
        title = { Text("Fechar o caixa") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    "Conte o dinheiro da gaveta e informe quanto encontrou.",
                    fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                previa?.let {
                    LinhaValor("Deve ter na gaveta", Dinheiro.comSimbolo(it.esperadoEmDinheiroCentavos))
                }
                OutlinedTextField(
                    value = contado,
                    onValueChange = { contado = it.filter { c -> c.isDigit() || c == ',' } },
                    label = { Text("Contado na gaveta (R$)") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth()
                )
                previa?.diferencaCentavos?.let { d ->
                    val (rotulo, cor) = when {
                        d == 0L -> "Bateu certinho" to VerdeOk
                        d > 0 -> "Sobrando ${Dinheiro.comSimbolo(d)}" to AzulMarca
                        else -> "Faltando ${Dinheiro.comSimbolo(-d)}" to VermelhoAlerta
                    }
                    Text(rotulo, color = cor, fontWeight = FontWeight.Bold)
                }
                OutlinedTextField(
                    value = obs, onValueChange = { obs = it },
                    label = { Text("Observação (opcional)") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { aoConfirmar(reaisParaCentavos(contado) ?: 0L, obs.ifBlank { null }) },
                enabled = contado.isNotBlank()
            ) { Text("Fechar caixa") }
        },
        dismissButton = { TextButton(onClick = aoFechar) { Text("Cancelar") } }
    )
}
