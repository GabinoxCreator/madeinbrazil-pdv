package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Conta do terminal no servidor. É digitada aqui, e não vem dentro do APK,
 * pra senha não viajar junto com o arquivo do app. A senha salva nunca
 * aparece: o campo começa vazio e só serve pra digitar uma nova.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TelaTerminal(vm: PdvViewModel, aoVoltar: () -> Unit) {
    val sincronia by vm.estadoSincronia.collectAsState()
    val emailSalvo by vm.emailTerminal.collectAsState()
    val ocupado by vm.ocupado.collectAsState()
    var email by remember(emailSalvo) { mutableStateOf(emailSalvo) }
    var senha by remember { mutableStateOf("") }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Terminal") },
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
            val (situacao, cor) = when {
                !sincronia.habilitada ->
                    "Este app foi instalado sem o endereço do servidor. Ele funciona, mas só guarda no aparelho." to VermelhoAlerta
                sincronia.semLogin ->
                    "Terminal sem login. O que for feito fica guardado no aparelho e sobe quando o terminal conectar." to VermelhoAlerta
                sincronia.ultimoErro != null ->
                    "Conectado como $emailSalvo, mas com problema: ${sincronia.ultimoErro}" to VermelhoAlerta
                sincronia.ultimaSincronizacaoEm == null -> "Conectando como $emailSalvo…" to AzulMarca
                else -> "Conectado como $emailSalvo · sincronizado ${tempoDesde(sincronia.ultimaSincronizacaoEm)}" to VerdeOk
            }
            Text(situacao, color = cor, fontSize = 14.sp)
            if (sincronia.habilitada) {
                Text("Aguardando envio: ${sincronia.pendentes}", fontSize = 13.sp)
            }

            HorizontalDivider()

            Text(
                "Use a conta do terminal cadastrada no servidor do PDV. " +
                    "A senha fica guardada só neste aparelho.",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            OutlinedTextField(
                value = email, onValueChange = { email = it.trim() },
                label = { Text("E-mail do terminal") }, singleLine = true,
                enabled = sincronia.habilitada && !ocupado,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = senha, onValueChange = { senha = it },
                label = { Text("Senha") }, singleLine = true,
                enabled = sincronia.habilitada && !ocupado,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                onClick = { vm.configurarTerminal(email, senha) { senha = "" } },
                enabled = sincronia.habilitada && !ocupado && email.isNotBlank() && senha.isNotBlank(),
                modifier = Modifier.fillMaxWidth().height(52.dp)
            ) { Text("Conectar") }

            if (ocupado) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}
