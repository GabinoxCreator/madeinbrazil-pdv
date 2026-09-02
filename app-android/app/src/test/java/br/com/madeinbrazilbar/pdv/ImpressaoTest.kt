package br.com.madeinbrazilbar.pdv

import br.com.madeinbrazilbar.pdv.impressao.EscPos
import br.com.madeinbrazilbar.pdv.impressao.Pc860
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImpressaoTest {

    @Test
    fun `PC860 converte os acentos do portugues nos bytes certos`() {
        // valores da tabela oficial do codepage PC860
        assertEquals(0x87.toByte(), Pc860.codificar("ç")[0])
        assertEquals(0x82.toByte(), Pc860.codificar("é")[0])
        assertEquals(0xA0.toByte(), Pc860.codificar("á")[0])
        assertEquals(0x84.toByte(), Pc860.codificar("ã")[0])
        assertEquals(0x8E.toByte(), Pc860.codificar("Ã")[0])
        assertEquals(0x90.toByte(), Pc860.codificar("É")[0])
    }

    @Test
    fun `ASCII passa intacto`() {
        assertEquals("Feijoada", String(Pc860.codificar("Feijoada"), Charsets.US_ASCII))
    }

    @Test
    fun `caractere fora do PC860 vira interrogacao em vez de quebrar`() {
        // emoji nao existe na termica: melhor '?' do que lixo ou excecao
        assertEquals('?'.code.toByte(), Pc860.codificar("🍺")[0])
    }

    @Test
    fun `colunas alinham rotulo e valor na largura da bobina`() {
        val linha = EscPos().colunas("Subtotal", "56,80").textoDaPrevia().trimEnd('\n')
        assertEquals(EscPos.COLUNAS, linha.length)
        assertTrue(linha.startsWith("Subtotal"))
        assertTrue(linha.endsWith("56,80"))
    }

    @Test
    fun `rotulo comprido e cortado sem desalinhar o valor`() {
        val nome = "Batata Frita com Cheddar e Bacon em Porcao Muito Grande Extra"
        val linha = EscPos().colunas(nome, "36,99").textoDaPrevia().trimEnd('\n')
        assertTrue(linha.length <= EscPos.COLUNAS)
        assertTrue(linha.endsWith("36,99"))
    }

    @Test
    fun `previa em texto acompanha os bytes enviados`() {
        val cupom = EscPos().inicializar().linha("Ação").colunas("TOTAL", "10,00")
        assertTrue(cupom.textoDaPrevia().contains("Ação"))
        assertTrue(cupom.textoDaPrevia().contains("TOTAL"))
        // os bytes trazem os comandos de controle alem do texto
        assertTrue(cupom.bytes().size > cupom.textoDaPrevia().length)
    }

    @Test
    fun `separador ocupa a largura exata da bobina`() {
        val linha = EscPos().separador('=').textoDaPrevia().trimEnd('\n')
        assertEquals(EscPos.COLUNAS, linha.length)
    }

    @Test
    fun `paragrafo quebra sem cortar palavra no meio`() {
        val texto = "Cliente pediu a carne bem passada e sem cebola no acompanhamento por favor"
        val saida = EscPos().paragrafo(texto).textoDaPrevia()
        saida.split("\n").filter { it.isNotBlank() }.forEach {
            assertTrue("linha longa demais: '$it'", it.length <= EscPos.COLUNAS)
        }
        // nenhuma palavra pode ter sido partida
        assertEquals(
            texto.split(" ").size,
            saida.split(Regex("\\s+")).filter { it.isNotBlank() }.size
        )
    }
}
