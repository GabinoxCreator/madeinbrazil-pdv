package br.com.madeinbrazilbar.pdv.dados

import java.util.Locale

/**
 * Dinheiro em CENTAVOS (Long), nunca em Double.
 *
 * Num PDV, 0.1 + 0.2 dando 0.30000000000000004 vira diferenca de caixa no
 * fim do dia. Todo valor monetario do app trafega como centavos inteiros e
 * so vira texto na hora de mostrar.
 */
object Dinheiro {

    fun deReais(reais: Double): Long = Math.round(reais * 100.0)

    fun formatar(centavos: Long): String =
        String.format(Locale("pt", "BR"), "%.2f", centavos / 100.0).replace('.', ',')

    fun comSimbolo(centavos: Long): String = "R$ " + formatar(centavos)

    /** Percentual sobre um valor, arredondado ao centavo. */
    fun percentual(centavos: Long, pct: Double): Long = Math.round(centavos * pct / 100.0)
}
