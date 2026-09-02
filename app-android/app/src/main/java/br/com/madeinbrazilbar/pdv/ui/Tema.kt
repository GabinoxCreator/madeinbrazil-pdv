package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val AzulMarca = Color(0xFF001CEE)
val AmareloMarca = Color(0xFFF5E400)
val VerdeOk = Color(0xFF1B7F3B)
val VermelhoAlerta = Color(0xFFB3261E)
val CinzaFechada = Color(0xFF6B6B6B)

@Composable
fun TemaPdv(conteudo: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = AzulMarca,
            secondary = AzulMarca,
            error = VermelhoAlerta
        ),
        content = conteudo
    )
}
