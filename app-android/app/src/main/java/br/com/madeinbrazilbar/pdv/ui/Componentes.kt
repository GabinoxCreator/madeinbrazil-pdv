package br.com.madeinbrazilbar.pdv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.concurrent.TimeUnit

/** Etiqueta colorida de status, como no mapa de comandas do salao. */
@Composable
fun Etiqueta(texto: String, cor: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(cor)
            .padding(horizontal = 8.dp, vertical = 3.dp)
    ) {
        Text(texto, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun LinhaValor(
    rotulo: String,
    valor: String,
    destaque: Boolean = false,
    cor: Color = MaterialTheme.colorScheme.onSurface
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            rotulo,
            fontWeight = if (destaque) FontWeight.Bold else FontWeight.Normal,
            fontSize = if (destaque) 17.sp else 15.sp,
            color = cor
        )
        Text(
            valor,
            fontWeight = if (destaque) FontWeight.Bold else FontWeight.Normal,
            fontSize = if (destaque) 17.sp else 15.sp,
            color = cor
        )
    }
}

/** "há 12 min" - o tempo desde o ultimo pedido, como a operacao ja usa hoje. */
fun tempoDesde(quando: Long?): String {
    if (quando == null) return "sem pedido"
    val ms = System.currentTimeMillis() - quando
    val min = TimeUnit.MILLISECONDS.toMinutes(ms)
    return when {
        min < 1L -> "agora"
        min < 60L -> "há $min min"
        else -> "há ${TimeUnit.MILLISECONDS.toHours(ms)} h"
    }
}

@Composable
fun CabecalhoMarca(titulo: String, subtitulo: String? = null) {
    Column(
        modifier = Modifier.fillMaxWidth().background(AzulMarca).padding(vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(titulo, color = AmareloMarca, fontWeight = FontWeight.Bold, fontSize = 20.sp)
        subtitulo?.let { Text(it, color = Color.White, fontSize = 12.sp) }
    }
}
