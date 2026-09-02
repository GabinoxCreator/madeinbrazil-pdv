package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TelaComanda(vm: PdvViewModel, comandaId: Long, aoVoltar: () -> Unit) {
    val comanda by vm.comanda(comandaId).collectAsState(initial = null)
    val itens by vm.itens(comandaId).collectAsState(initial = emptyList())
    val ocupado by vm.ocupado.collectAsState()
    var aba by remember { mutableIntStateOf(0) }

    val c = comanda
    if (c == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        return
    }

    val conta = remember(itens, c) {
        Conta.calcular(itens, c.taxaServicoPct, c.descontoCentavos, c.pessoas)
    }
    val aberta = c.status == StatusComanda.ABERTA

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Comanda ${c.numero}", fontWeight = FontWeight.Bold)
                        Text(
                            listOfNotNull(c.mesa?.let { "Mesa $it" }, c.cliente).joinToString(" · ")
                                .ifBlank { if (aberta) "aberta" else "fechada" },
                            fontSize = 12.sp
                        )
                    }
                },
                navigationIcon = { TextButton(onClick = aoVoltar) { Text("Voltar") } },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = AzulMarca,
                    titleContentColor = androidx.compose.ui.graphics.Color.White,
                    navigationIconContentColor = AmareloMarca
                )
            )
        },
        bottomBar = {
            Surface(tonalElevation = 3.dp) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("Total", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    Text(
                        Dinheiro.comSimbolo(conta.totalCentavos),
                        fontWeight = FontWeight.Bold,
                        fontSize = 20.sp,
                        color = AzulMarca
                    )
                }
            }
        }
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            if (ocupado) LinearProgressIndicator(Modifier.fillMaxWidth())

            if (!aberta) {
                Surface(color = MaterialTheme.colorScheme.errorContainer) {
                    Text(
                        "Comanda fechada — não aceita novos lançamentos.",
                        Modifier.fillMaxWidth().padding(10.dp),
                        fontSize = 13.sp
                    )
                }
            }

            TabRow(selectedTabIndex = aba) {
                Tab(aba == 0, { aba = 0 }, text = { Text("Consumo") })
                Tab(aba == 1, { aba = 1 }, text = { Text("Lançar") }, enabled = aberta)
                Tab(aba == 2, { aba = 2 }, text = { Text("Conta") })
            }

            when (aba) {
                0 -> AbaConsumo(vm, itens, aberta)
                1 -> AbaLancar(vm, comandaId) { aba = 0 }
                else -> AbaConta(vm, c, conta, aberta)
            }
        }
    }
}

// ------------------------------------------------------------------ consumo

@Composable
private fun AbaConsumo(vm: PdvViewModel, itens: List<ItemLancado>, aberta: Boolean) {
    var cancelando by remember { mutableStateOf<ItemLancado?>(null) }

    if (itens.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("Nada lançado ainda.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }

    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items(itens, key = { it.id }) { item ->
            Card {
                Row(Modifier.padding(12.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("${item.quantidade}x ${item.nome}", fontWeight = FontWeight.Medium)
                        val ponto = vm.cardapio.ponto(item.pontoId)?.nome ?: item.pontoId
                        Text(
                            "$ponto · ${Dinheiro.formatar(item.precoUnitCentavos)} cada",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        item.observacao?.let {
                            Text("obs: $it", fontSize = 12.sp, color = AzulMarca)
                        }
                    }
                    Text(Dinheiro.formatar(item.totalCentavos), fontWeight = FontWeight.Bold)
                    if (aberta) {
                        TextButton(onClick = { cancelando = item }) { Text("Cancelar") }
                    }
                }
            }
        }
    }

    cancelando?.let { item ->
        var motivo by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { cancelando = null },
            title = { Text("Cancelar ${item.nome}?") },
            text = {
                Column {
                    Text("Cancelamento fica registrado com o motivo.", fontSize = 13.sp)
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = motivo, onValueChange = { motivo = it },
                        label = { Text("Motivo") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = { vm.cancelarItem(item.id, motivo); cancelando = null },
                    enabled = motivo.isNotBlank()
                ) { Text("Cancelar item") }
            },
            dismissButton = { TextButton(onClick = { cancelando = null }) { Text("Voltar") } }
        )
    }
}

// ------------------------------------------------------------------- lancar

@Composable
private fun AbaLancar(vm: PdvViewModel, comandaId: Long, aoEnviar: () -> Unit) {
    val carrinho = remember { mutableStateListOf<ItemEscolhido>() }
    var categoria by remember { mutableStateOf(vm.cardapio.categorias.first().slug) }
    var busca by remember { mutableStateOf("") }

    val visiveis = remember(categoria, busca) {
        if (busca.isBlank()) vm.cardapio.itensDe(categoria) else vm.cardapio.buscar(busca)
    }
    val totalCarrinho = carrinho.sumOf { it.item.precoCentavos * it.quantidade }

    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(
            value = busca,
            onValueChange = { busca = it },
            label = { Text("Buscar por nome ou código") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
        )

        if (busca.isBlank()) {
            ScrollableTabRow(
                selectedTabIndex = vm.cardapio.categorias.indexOfFirst { it.slug == categoria }
                    .coerceAtLeast(0),
                edgePadding = 12.dp
            ) {
                vm.cardapio.categorias.forEach { cat ->
                    Tab(
                        selected = cat.slug == categoria,
                        onClick = { categoria = cat.slug },
                        text = { Text(cat.nome, fontSize = 13.sp) }
                    )
                }
            }
        }

        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 8.dp)) {
            items(visiveis, key = { it.id }) { item ->
                Row(
                    Modifier.fillMaxWidth().clickable {
                        val i = carrinho.indexOfFirst { it.item.id == item.id }
                        if (i >= 0) carrinho[i] = carrinho[i].copy(quantidade = carrinho[i].quantidade + 1)
                        else carrinho.add(ItemEscolhido(item, 1))
                    }.padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(item.nome, fontSize = 15.sp)
                        Text(
                            "${item.codigo} · ${vm.cardapio.ponto(item.ponto)?.nome ?: item.ponto}" +
                                if (!item.pontoConfirmado) " (ponto a confirmar)" else "",
                            fontSize = 11.sp,
                            color = if (item.pontoConfirmado) MaterialTheme.colorScheme.onSurfaceVariant
                            else VermelhoAlerta
                        )
                    }
                    Text(Dinheiro.formatar(item.precoCentavos), fontWeight = FontWeight.Medium)
                    Spacer(Modifier.width(10.dp))
                    val n = carrinho.firstOrNull { it.item.id == item.id }?.quantidade ?: 0
                    if (n > 0) Etiqueta("${n}x", AzulMarca)
                }
                HorizontalDivider()
            }
        }

        if (carrinho.isNotEmpty()) {
            Surface(tonalElevation = 4.dp) {
                Column(Modifier.padding(16.dp)) {
                    Text(
                        "${carrinho.sumOf { it.quantidade }} item(ns) · ${Dinheiro.comSimbolo(totalCarrinho)}",
                        fontWeight = FontWeight.Bold
                    )
                    Spacer(Modifier.height(6.dp))
                    carrinho.toList().forEach { e ->
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 2.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("${e.quantidade}x ${e.item.nome}", Modifier.weight(1f), fontSize = 13.sp)
                            TextButton(onClick = {
                                val i = carrinho.indexOfFirst { it.item.id == e.item.id }
                                if (i >= 0) {
                                    if (carrinho[i].quantidade > 1)
                                        carrinho[i] = carrinho[i].copy(quantidade = carrinho[i].quantidade - 1)
                                    else carrinho.removeAt(i)
                                }
                            }) { Text("−") }
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    Button(
                        onClick = {
                            vm.lancarPedido(comandaId, carrinho.toList()) {
                                carrinho.clear(); aoEnviar()
                            }
                        },
                        modifier = Modifier.fillMaxWidth().height(50.dp)
                    ) { Text("ENVIAR PEDIDO") }
                    Text(
                        "Imprime em cada ponto de produção dos itens.",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

// -------------------------------------------------------------------- conta

@Composable
private fun AbaConta(vm: PdvViewModel, c: Comanda, conta: Conta, aberta: Boolean) {
    var pessoas by remember(c.id, c.pessoas) { mutableStateOf(c.pessoas.toString()) }
    var servico by remember(c.id, c.taxaServicoPct) { mutableStateOf(c.taxaServicoPct > 0) }
    var desconto by remember(c.id, c.descontoCentavos) {
        mutableStateOf(if (c.descontoCentavos > 0) Dinheiro.formatar(c.descontoCentavos) else "")
    }
    var previa by remember { mutableStateOf<String?>(null) }
    var confirmarFechar by remember { mutableStateOf(false) }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(
                value = pessoas, onValueChange = { pessoas = it.filter(Char::isDigit) },
                label = { Text("Pessoas") }, singleLine = true, enabled = aberta,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f)
            )
            OutlinedTextField(
                value = desconto,
                onValueChange = { desconto = it.filter { ch -> ch.isDigit() || ch == ',' } },
                label = { Text("Desconto (R$)") }, singleLine = true, enabled = aberta,
                modifier = Modifier.weight(1f)
            )
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = servico, onCheckedChange = { servico = it }, enabled = aberta)
            Text("Cobrar serviço (${Configuracao.TAXA_SERVICO_PCT.toInt()}%)")
        }

        if (aberta) {
            OutlinedButton(
                onClick = {
                    val centavos = desconto.replace(",", ".").toDoubleOrNull()
                        ?.let { Dinheiro.deReais(it) } ?: 0L
                    vm.ajustarConta(c.id, pessoas.toIntOrNull() ?: 1, servico, centavos)
                },
                modifier = Modifier.fillMaxWidth()
            ) { Text("Aplicar ajustes") }
        }

        HorizontalDivider()

        LinhaValor("Subtotal", Dinheiro.comSimbolo(conta.subtotalCentavos))
        if (conta.servicoCentavos > 0)
            LinhaValor("Serviço (${conta.taxaServicoPct.toInt()}%)", Dinheiro.comSimbolo(conta.servicoCentavos))
        if (conta.descontoCentavos > 0)
            LinhaValor("Desconto", "− " + Dinheiro.comSimbolo(conta.descontoCentavos), cor = VermelhoAlerta)
        HorizontalDivider()
        LinhaValor("TOTAL", Dinheiro.comSimbolo(conta.totalCentavos), destaque = true, cor = AzulMarca)
        if (conta.pessoas > 1)
            LinhaValor("Por pessoa (${conta.pessoas})", Dinheiro.comSimbolo(conta.porPessoaCentavos))

        Spacer(Modifier.height(6.dp))

        val escopo = rememberCoroutineScope()
        OutlinedButton(
            onClick = { escopo.launch { previa = vm.previaConferencia(c.id) } },
            modifier = Modifier.fillMaxWidth()
        ) { Text("Ver prévia do cupom") }

        OutlinedButton(
            onClick = { vm.imprimirConferencia(c.id) },
            modifier = Modifier.fillMaxWidth()
        ) { Text("Imprimir conferência no caixa") }

        if (aberta) {
            Button(
                onClick = { confirmarFechar = true },
                modifier = Modifier.fillMaxWidth().height(50.dp)
            ) { Text("FECHAR CONTA") }
        } else {
            OutlinedButton(
                onClick = { vm.reabrirComanda(c.id) },
                modifier = Modifier.fillMaxWidth()
            ) { Text("Reabrir comanda") }
        }

        Spacer(Modifier.height(20.dp))
    }

    previa?.let { texto ->
        AlertDialog(
            onDismissRequest = { previa = null },
            title = { Text("Prévia do cupom") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text(
                        "Exatamente o que sai no papel, 48 colunas.",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(texto, fontFamily = FontFamily.Monospace, fontSize = 9.sp, lineHeight = 12.sp)
                }
            },
            confirmButton = { TextButton(onClick = { previa = null }) { Text("Fechar") } }
        )
    }

    if (confirmarFechar) {
        AlertDialog(
            onDismissRequest = { confirmarFechar = false },
            title = { Text("Fechar a comanda ${c.numero}?") },
            text = { Text("Depois de fechada ela não aceita novos lançamentos. Dá para reabrir se precisar.") },
            confirmButton = {
                Button(onClick = { vm.fecharComanda(c.id); confirmarFechar = false }) { Text("Fechar conta") }
            },
            dismissButton = { TextButton(onClick = { confirmarFechar = false }) { Text("Voltar") } }
        )
    }
}
