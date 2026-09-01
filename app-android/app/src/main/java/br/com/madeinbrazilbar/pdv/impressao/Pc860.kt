package br.com.madeinbrazilbar.pdv.impressao

/**
 * Codepage PC860 (portugues) - o que as Elgin i9 do bar usam.
 *
 * Nao usamos Charset.forName("IBM860") de proposito: nem todo Android traz
 * esse charset, e uma falha silenciosa aqui vira cupom com acento errado no
 * meio do servico. A tabela abaixo foi gerada da tabela oficial do codepage,
 * entao a conversao e deterministica em qualquer aparelho.
 */
object Pc860 {

    private val mapa: Map<Char, Byte> = mapOf(
    '\u00C7' to 0x80.toByte(), '\u00FC' to 0x81.toByte(), '\u00E9' to 0x82.toByte(), '\u00E2' to 0x83.toByte(),
    '\u00E3' to 0x84.toByte(), '\u00E0' to 0x85.toByte(), '\u00C1' to 0x86.toByte(), '\u00E7' to 0x87.toByte(),
    '\u00EA' to 0x88.toByte(), '\u00CA' to 0x89.toByte(), '\u00E8' to 0x8A.toByte(), '\u00CD' to 0x8B.toByte(),
    '\u00D4' to 0x8C.toByte(), '\u00EC' to 0x8D.toByte(), '\u00C3' to 0x8E.toByte(), '\u00C2' to 0x8F.toByte(),
    '\u00C9' to 0x90.toByte(), '\u00C0' to 0x91.toByte(), '\u00C8' to 0x92.toByte(), '\u00F4' to 0x93.toByte(),
    '\u00F5' to 0x94.toByte(), '\u00F2' to 0x95.toByte(), '\u00DA' to 0x96.toByte(), '\u00F9' to 0x97.toByte(),
    '\u00CC' to 0x98.toByte(), '\u00D5' to 0x99.toByte(), '\u00DC' to 0x9A.toByte(), '\u00A2' to 0x9B.toByte(),
    '\u00A3' to 0x9C.toByte(), '\u00D9' to 0x9D.toByte(), '\u20A7' to 0x9E.toByte(), '\u00D3' to 0x9F.toByte(),
    '\u00E1' to 0xA0.toByte(), '\u00ED' to 0xA1.toByte(), '\u00F3' to 0xA2.toByte(), '\u00FA' to 0xA3.toByte(),
    '\u00F1' to 0xA4.toByte(), '\u00D1' to 0xA5.toByte(), '\u00AA' to 0xA6.toByte(), '\u00BA' to 0xA7.toByte(),
    '\u00BF' to 0xA8.toByte(), '\u00D2' to 0xA9.toByte(), '\u00AC' to 0xAA.toByte(), '\u00BD' to 0xAB.toByte(),
    '\u00BC' to 0xAC.toByte(), '\u00A1' to 0xAD.toByte(), '\u00AB' to 0xAE.toByte(), '\u00BB' to 0xAF.toByte(),
    '\u2591' to 0xB0.toByte(), '\u2592' to 0xB1.toByte(), '\u2593' to 0xB2.toByte(), '\u2502' to 0xB3.toByte(),
    '\u2524' to 0xB4.toByte(), '\u2561' to 0xB5.toByte(), '\u2562' to 0xB6.toByte(), '\u2556' to 0xB7.toByte(),
    '\u2555' to 0xB8.toByte(), '\u2563' to 0xB9.toByte(), '\u2551' to 0xBA.toByte(), '\u2557' to 0xBB.toByte(),
    '\u255D' to 0xBC.toByte(), '\u255C' to 0xBD.toByte(), '\u255B' to 0xBE.toByte(), '\u2510' to 0xBF.toByte(),
    '\u2514' to 0xC0.toByte(), '\u2534' to 0xC1.toByte(), '\u252C' to 0xC2.toByte(), '\u251C' to 0xC3.toByte(),
    '\u2500' to 0xC4.toByte(), '\u253C' to 0xC5.toByte(), '\u255E' to 0xC6.toByte(), '\u255F' to 0xC7.toByte(),
    '\u255A' to 0xC8.toByte(), '\u2554' to 0xC9.toByte(), '\u2569' to 0xCA.toByte(), '\u2566' to 0xCB.toByte(),
    '\u2560' to 0xCC.toByte(), '\u2550' to 0xCD.toByte(), '\u256C' to 0xCE.toByte(), '\u2567' to 0xCF.toByte(),
    '\u2568' to 0xD0.toByte(), '\u2564' to 0xD1.toByte(), '\u2565' to 0xD2.toByte(), '\u2559' to 0xD3.toByte(),
    '\u2558' to 0xD4.toByte(), '\u2552' to 0xD5.toByte(), '\u2553' to 0xD6.toByte(), '\u256B' to 0xD7.toByte(),
    '\u256A' to 0xD8.toByte(), '\u2518' to 0xD9.toByte(), '\u250C' to 0xDA.toByte(), '\u2588' to 0xDB.toByte(),
    '\u2584' to 0xDC.toByte(), '\u258C' to 0xDD.toByte(), '\u2590' to 0xDE.toByte(), '\u2580' to 0xDF.toByte(),
    '\u03B1' to 0xE0.toByte(), '\u00DF' to 0xE1.toByte(), '\u0393' to 0xE2.toByte(), '\u03C0' to 0xE3.toByte(),
    '\u03A3' to 0xE4.toByte(), '\u03C3' to 0xE5.toByte(), '\u00B5' to 0xE6.toByte(), '\u03C4' to 0xE7.toByte(),
    '\u03A6' to 0xE8.toByte(), '\u0398' to 0xE9.toByte(), '\u03A9' to 0xEA.toByte(), '\u03B4' to 0xEB.toByte(),
    '\u221E' to 0xEC.toByte(), '\u03C6' to 0xED.toByte(), '\u03B5' to 0xEE.toByte(), '\u2229' to 0xEF.toByte(),
    '\u2261' to 0xF0.toByte(), '\u00B1' to 0xF1.toByte(), '\u2265' to 0xF2.toByte(), '\u2264' to 0xF3.toByte(),
    '\u2320' to 0xF4.toByte(), '\u2321' to 0xF5.toByte(), '\u00F7' to 0xF6.toByte(), '\u2248' to 0xF7.toByte(),
    '\u00B0' to 0xF8.toByte(), '\u2219' to 0xF9.toByte(), '\u00B7' to 0xFA.toByte(), '\u221A' to 0xFB.toByte(),
    '\u207F' to 0xFC.toByte(), '\u00B2' to 0xFD.toByte(), '\u25A0' to 0xFE.toByte(), '\u00A0' to 0xFF.toByte(),
    )

    /** Caractere que entra no lugar de algo que nao existe no PC860. */
    private const val SUBSTITUTO: Byte = 0x3F // '?'

    fun codificar(texto: String): ByteArray {
        val saida = ByteArray(texto.length)
        for (i in texto.indices) {
            val c = texto[i]
            saida[i] = when {
                c.code < 128 -> c.code.toByte()
                else -> mapa[c] ?: SUBSTITUTO
            }
        }
        return saida
    }
}
