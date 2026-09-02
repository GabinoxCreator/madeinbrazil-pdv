package br.com.madeinbrazilbar.pdv.impressao

/**
 * Montador de comandos ESC/POS para as termicas Elgin i9 (bobina 80mm, 48 colunas).
 *
 * Toda saida para termica do PDV passa por aqui. Nenhuma outra parte do app
 * monta bytes de impressora na mao - mesmo principio de ponto unico de saida
 * do motor de envio do WhatsApp no sistema do bar.
 *
 * Alem dos bytes, guarda a PREVIA em texto puro. As duas saem da mesma
 * chamada, entao a previa na tela e sempre igual ao papel - nao ha como uma
 * ficar desatualizada em relacao a outra.
 */
class EscPos {

    private val buffer = ArrayList<Byte>(1024)
    private val previa = StringBuilder()

    fun inicializar() = apply {
        cru(0x1B, 0x40)             // ESC @   reseta a impressora
        cru(0x1B, 0x74, 0x03)       // ESC t 3 codepage PC860 (portugues)
    }

    fun texto(s: String) = apply {
        buffer.addAll(Pc860.codificar(s).toList())
        previa.append(s)
    }

    fun linha(s: String = "") = apply { texto(s); texto("\n") }

    fun separador(caractere: Char = '-') = apply { linha(caractere.toString().repeat(COLUNAS)) }

    fun centralizado() = apply { cru(0x1B, 0x61, 0x01) }
    fun aEsquerda() = apply { cru(0x1B, 0x61, 0x00) }

    fun negrito(ligado: Boolean) = apply { cru(0x1B, 0x45, if (ligado) 1 else 0) }
    fun dobrado(ligado: Boolean) = apply { cru(0x1D, 0x21, if (ligado) 0x11 else 0x00) }

    /** Rotulo a esquerda, valor a direita, na mesma linha. Formato de item e de total. */
    fun colunas(esquerda: String, direita: String) = apply {
        val espaco = COLUNAS - esquerda.length - direita.length
        if (espaco >= 1) {
            linha(esquerda + " ".repeat(espaco) + direita)
        } else {
            val sobra = COLUNAS - direita.length - 1
            linha(esquerda.take(maxOf(sobra, 0)) + " " + direita)
        }
    }

    /** Texto longo quebrado na largura da bobina, sem cortar palavra no meio. */
    fun paragrafo(s: String, recuo: String = "") = apply {
        var atual = StringBuilder(recuo)
        for (palavra in s.split(" ")) {
            if (atual.length + palavra.length + 1 > COLUNAS && atual.isNotBlank()) {
                linha(atual.toString().trimEnd())
                atual = StringBuilder(recuo)
            }
            if (atual.isNotEmpty() && atual.toString() != recuo) atual.append(' ')
            atual.append(palavra)
        }
        if (atual.toString().isNotBlank()) linha(atual.toString().trimEnd())
    }

    fun avancar(linhas: Int = 3) = apply { repeat(linhas) { texto("\n") } }

    fun cortar() = apply { cru(0x1D, 0x56, 0x42, 0x00) }

    private fun cru(vararg bytes: Int) = apply { for (b in bytes) buffer.add(b.toByte()) }

    fun bytes(): ByteArray = buffer.toByteArray()

    /** O mesmo cupom em texto puro, para conferir na tela sem gastar bobina. */
    fun textoDaPrevia(): String = previa.toString()

    companion object {
        /** Colunas uteis da bobina de 80mm em fonte normal. */
        const val COLUNAS = 48
    }
}
