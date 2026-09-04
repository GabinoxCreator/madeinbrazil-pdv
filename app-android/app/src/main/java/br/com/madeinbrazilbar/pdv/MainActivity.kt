package br.com.madeinbrazilbar.pdv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
import br.com.madeinbrazilbar.pdv.ui.*

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { TemaPdv { Surface(Modifier.fillMaxSize()) { AppPdv() } } }
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
                    aoIrParaCaixa = { nav.navigate("caixa") }
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
        }
    }
}
