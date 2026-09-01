package br.com.madeinbrazilbar.pdv.impressao

/**
 * Montador de comandos ESC/POS para as termicas Elgin i9 (bobina 80mm, 48 colunas).
 *
 * Toda saida para termica do PDV passa por aqui. Nenhuma outra parte do app
 * monta bytes de impressora na mao - mesmo principio de ponto unico de saida
 * que o motor de envio do WhatsApp segue no sistema do bar.
 */
class EscPos {

    private val buffer = ArrayList<Byte>(1024)

    fun inicializar() = apply {
        cru(0x1B, 0x40)             // ESC @  - reseta a impressora
        cru(0x1B, 0x74, 0x03)       // ESC t 3 - seleciona codepage PC860
    }

    fun texto(s: String) = apply { buffer.addAll(Pc860.codificar(s).toList()) }

    fun linha(s: String = "") = apply { texto(s); texto("\n") }

    /** Linha separadora ocupando a largura da bobina. */
    fun separador(caractere: Char = '-') = apply { linha(caractere.toString().repeat(COLUNAS)) }

    fun centralizado() = apply { cru(0x1B, 0x61, 0x01) }
    fun aEsquerda() = apply { cru(0x1B, 0x61, 0x00) }

    fun negrito(ligado: Boolean) = apply { cru(0x1B, 0x45, if (ligado) 1 else 0) }
    fun dobrado(ligado: Boolean) = apply { cru(0x1D, 0x21, if (ligado) 0x11 else 0x00) }

    /**
     * Escreve rotulo a esquerda e valor a direita na mesma linha.
     * E o formato de item de comanda e de totais.
     */
    fun colunas(esquerda: String, direita: String) = apply {
        val espaco = COLUNAS - esquerda.length - direita.length
        if (espaco >= 1) {
            linha(esquerda + " ".repeat(espaco) + direita)
        } else {
            // nao coube: corta o rotulo em vez de quebrar o alinhamento do valor
            val sobra = COLUNAS - direita.length - 1
            linha(esquerda.take(maxOf(sobra, 0)) + " " + direita)
        }
    }

    fun avancar(linhas: Int = 3) = apply { repeat(linhas) { texto("\n") } }

    fun cortar() = apply { cru(0x1D, 0x56, 0x42, 0x00) }

    private fun cru(vararg bytes: Int) = apply {
        for (b in bytes) buffer.add(b.toByte())
    }

    fun bytes(): ByteArray = buffer.toByteArray()

    companion object {
        /** Colunas uteis da bobina de 80mm em fonte normal. */
        const val COLUNAS = 48
    }
}
