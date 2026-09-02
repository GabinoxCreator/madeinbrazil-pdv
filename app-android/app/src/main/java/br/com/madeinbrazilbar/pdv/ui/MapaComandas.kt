package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.madeinbrazilbar.pdv.dados.Comanda
import br.com.madeinbrazilbar.pdv.dados.StatusComanda

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MapaComandas(
    vm: PdvViewModel,
    aoAbrirComanda: (Long) -> Unit,
    aoIrParaDiagnostico: () -> Unit,
    aoIrParaFila: () -> Unit
) {
    val comandas by vm.comandas.collectAsState()
    val operador by vm.operador.collectAsState()
    var mostrarNova by remember { mutableStateOf(false) }
    var mostrarOperador by remember { mutableStateOf(false) }
    var busca by remember { mutableStateOf("") }

    val filtradas = remember(comandas, busca) {
        if (busca.isBlank()) comandas
        else comandas.filter {
            it.numero.toString().contains(busca.trim()) ||
                (it.mesa ?: "").contains(busca.trim(), ignoreCase = true) ||
                (it.cliente ?: "").contains(busca.trim(), ignoreCase = true)
        }
    }
    val abertas = filtradas.count { it.status == StatusComanda.ABERTA }
    val fechadas = filtradas.count { it.status == StatusComanda.FECHADA }

    Scaffold(
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { mostrarNova = true },
                containerColor = AzulMarca,
                contentColor = androidx.compose.ui.graphics.Color.White
            ) { Text("Abrir comanda") }
        }
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize()) {
            CabecalhoMarca("MADE IN BRAZIL", "Mapa de comandas")

            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text("$abertas aberta(s) · $fechadas fechada(s)", fontSize = 13.sp)
                    Text(
                        "Operando: $operador",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.clickable { mostrarOperador = true }
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val emAberto by vm.impressoesEmAberto.collectAsState()
                    TextButton(onClick = aoIrParaFila) {
                        Text(if (emAberto > 0) "Fila ($emAberto)" else "Fila")
                    }
                    TextButton(onClick = aoIrParaDiagnostico) { Text("Impressoras") }
                }
            }

            OutlinedTextField(
                value = busca,
                onValueChange = { busca = it },
                label = { Text("Buscar por número, mesa ou cliente") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)
            )

            Spacer(Modifier.height(8.dp))

            if (filtradas.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        if (comandas.isEmpty()) "Nenhuma comanda aberta.\nToque em \"Abrir comanda\"."
                        else "Nada encontrado para \"$busca\".",
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(16.dp, 0.dp, 16.dp, 96.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(filtradas, key = { it.id }) { c ->
                        CartaoComanda(c) { aoAbrirComanda(c.id) }
                    }
                }
            }
        }
    }

    if (mostrarNova) {
        DialogoNovaComanda(
            aoFechar = { mostrarNova = false },
            aoConfirmar = { numero, mesa, pessoas, cliente, controle ->
                vm.abrirComanda(numero, mesa, pessoas, cliente, controle)
                mostrarNova = false
            }
        )
    }

    if (mostrarOperador) {
        AlertDialog(
            onDismissRequest = { mostrarOperador = false },
            title = { Text("Quem está operando?") },
            text = {
                Column {
                    Text(
                        "Sem senha por enquanto — o login do colaborador no terminal ainda será definido.",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.height(8.dp))
                    LazyColumn(Modifier.heightIn(max = 320.dp)) {
                        items(vm.cardapio.colaboradores) { c ->
                            ListItem(
                                headlineContent = { Text(c.nome) },
                                supportingContent = { Text(c.funcao) },
                                modifier = Modifier.clickable {
                                    vm.trocarOperador(c.nome); mostrarOperador = false
                                }
                            )
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { mostrarOperador = false }) { Text("Fechar") } }
        )
    }
}

@Composable
private fun CartaoComanda(c: Comanda, aoClicar: () -> Unit) {
    val aberta = c.status == StatusComanda.ABERTA
    Card(modifier = Modifier.fillMaxWidth().clickable(onClick = aoClicar)) {
        Row(
            modifier = Modifier.padding(14.dp).fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("${c.numero}", fontSize = 26.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.width(10.dp))
                    Etiqueta(
                        if (aberta) "ABERTA" else "FECHADA",
                        if (aberta) VerdeOk else CinzaFechada
                    )
                    if (c.controle) {
                        Spacer(Modifier.width(6.dp))
                        Etiqueta("CONTROLE", AzulMarca)
                    }
                }
                Spacer(Modifier.height(4.dp))
                val detalhe = buildList {
                    c.mesa?.let { add("Mesa $it") }
                    c.cliente?.let { add(it) }
                    add("${c.pessoas} pessoa(s)")
                }.joinToString(" · ")
                Text(detalhe, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    "${c.ultimaAtividadePor ?: c.abertaPor} · ${tempoDesde(c.ultimaAtividadeEm)}",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun DialogoNovaComanda(
    aoFechar: () -> Unit,
    aoConfirmar: (Int, String?, Int, String?, Boolean) -> Unit
) {
    var numero by remember { mutableStateOf("") }
    var mesa by remember { mutableStateOf("") }
    var pessoas by remember { mutableStateOf("1") }
    var cliente by remember { mutableStateOf("") }
    var controle by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = aoFechar,
        title = { Text("Abrir comanda") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = numero, onValueChange = { numero = it.filter(Char::isDigit) },
                    label = { Text("Número da comanda") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = mesa, onValueChange = { mesa = it },
                    label = { Text("Mesa (opcional)") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = pessoas, onValueChange = { pessoas = it.filter(Char::isDigit) },
                    label = { Text("Pessoas") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = cliente, onValueChange = { cliente = it },
                    label = { Text("Cliente (opcional)") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = controle, onCheckedChange = { controle = it })
                    Column {
                        Text("Comanda de controle")
                        Text(
                            "Banda, equipe. Fica aberta e não cobra serviço.",
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    aoConfirmar(
                        numero.toIntOrNull() ?: 0,
                        mesa.ifBlank { null },
                        pessoas.toIntOrNull() ?: 1,
                        cliente.ifBlank { null },
                        controle
                    )
                },
                enabled = numero.isNotBlank()
            ) { Text("Abrir") }
        },
        dismissButton = { TextButton(onClick = aoFechar) { Text("Cancelar") } }
    )
}
