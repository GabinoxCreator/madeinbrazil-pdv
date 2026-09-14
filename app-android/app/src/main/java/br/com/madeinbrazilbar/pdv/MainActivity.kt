package br.com.madeinbrazilbar.pdv

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import androidx.navigation.NavType
import br.com.madeinbrazilbar.pdv.pagamento.CieloSmart
import br.com.madeinbrazilbar.pdv.ui.*

/*
 * A resposta da maquininha Cielo chega aqui: a Cielo abre
 * mibpdv://pagamento?response=... (intent-filter no AndroidManifest).
 * launchMode="singleTask" faz a resposta cair nesta mesma tela (onNewIntent)
 * em vez de abrir outra cópia do app. Se o sistema matou o app durante o
 * pagamento, a resposta chega no onCreate - o pendente está gravado no banco.
 */
class MainActivity : ComponentActivity() {

    /** Mesmo ViewModel que as telas usam (mesmo dono: esta activity). */
    private val vm: PdvViewModel by viewModels()

    /** Marca que o app voltou COM resposta da Cielo (não é "voltou sem retorno"). */
    private var retornoRecebido = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        tratarRetornoDaCielo(intent)
        setContent { TemaPdv { Surface(Modifier.fillMaxSize()) { AppPdv() } } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        tratarRetornoDaCielo(intent)
    }

    override fun onResume() {
        super.onResume()
        // voltou da Cielo sem resposta: o pendente (se houver) passa a aparecer como aviso
        if (retornoRecebido) retornoRecebido = false else vm.voltouDaMaquininha()
    }

    private fun tratarRetornoDaCielo(recebido: Intent?) {
        val dados = recebido?.data ?: return
        if (dados.scheme != CieloSmart.ESQUEMA_RETORNO || dados.host != CieloSmart.HOST_RETORNO) return
        retornoRecebido = true
        // texto cru da URI: o base64 não pode passar por decodificação de query string
        vm.retornoDaMaquininha(recebido.dataString ?: dados.toString())
        // não reprocessa a mesma resposta se a tela for recriada
        // (e, se reprocessasse, o uuid do pagamento impede registrar duas vezes)
        setIntent(Intent(recebido).apply { data = null })
    }
}

@Composable
private fun AppPdv() {
    val vm: PdvViewModel = viewModel()
    val nav = rememberNavController()
    val aviso by vm.aviso.collectAsState()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(aviso) {
        aviso?.let { snackbar.showSnackbar(it); vm.limparAviso() }
    }

    Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        NavHost(
            navController = nav,
            startDestination = "mapa",
            modifier = Modifier.fillMaxSize().padding(padding)
        ) {
            composable("mapa") {
                MapaComandas(
                    vm = vm,
                    aoAbrirComanda = { id -> nav.navigate("comanda/$id") },
                    aoIrParaDiagnostico = { nav.navigate("diagnostico") },
                    aoIrParaFila = { nav.navigate("fila") },
                    aoIrParaCaixa = { nav.navigate("caixa") },
                    aoIrParaTerminal = { nav.navigate("terminal") }
                )
            }
            composable(
                "comanda/{id}",
                arguments = listOf(navArgument("id") { type = NavType.LongType })
            ) { entrada ->
                TelaComanda(
                    vm = vm,
                    comandaId = entrada.arguments?.getLong("id") ?: 0L,
                    aoVoltar = { nav.popBackStack() }
                )
            }
            composable("diagnostico") {
                TelaDiagnostico(vm = vm, aoVoltar = { nav.popBackStack() })
            }
            composable("fila") {
                TelaFilaImpressao(vm = vm, aoVoltar = { nav.popBackStack() })
            }
            composable("caixa") {
                TelaCaixa(vm = vm, aoVoltar = { nav.popBackStack() })
            }
            composable("terminal") {
                TelaTerminal(vm = vm, aoVoltar = { nav.popBackStack() })
            }
        }
    }
}
