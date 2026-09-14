package br.com.madeinbrazilbar.pdv

import br.com.madeinbrazilbar.pdv.dados.Comanda
import br.com.madeinbrazilbar.pdv.dados.ItemLancado
import br.com.madeinbrazilbar.pdv.sincronia.DataIso
import br.com.madeinbrazilbar.pdv.sincronia.Mapeamento
import br.com.madeinbrazilbar.pdv.sincronia.texto
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Tradução entre o aparelho e o servidor: data, dinheiro e campos. */
class MapeamentoTest {

    @Test
    fun `data vai e volta sem perder o milissegundo`() {
        val ms = 1_789_000_123_456L
        assertEquals(ms, DataIso.paraMillis(DataIso.deMillis(ms)))
    }

    @Test
    fun `le a data do servidor com microssegundos`() {
        assertEquals(
            DataIso.paraMillis("2026-09-14T18:00:00.123Z"),
            DataIso.paraMillis("2026-09-14T18:00:00.123456+00:00")
        )
    }

    @Test
    fun `respeita o fuso horario`() {
        assertEquals(
            DataIso.paraMillis("2026-09-14T15:00:00Z"),
            DataIso.paraMillis("2026-09-14T12:00:00-03:00")
        )
    }

    @Test
    fun `data sem fracao de segundo`() {
        assertEquals(0L, DataIso.paraMillis("1970-01-01T00:00:00+00:00"))
    }

    @Test
    fun `comanda vai com o id do aparelho e o nome de quem abriu`() {
        val c = Comanda(numero = 15, taxaServicoPct = 10.0, abertaPor = "Beto", abertaEm = 0L)
        val j = Mapeamento.comanda(c)
        assertEquals(c.uuid, j.texto("id"))
        assertEquals("Beto", j.texto("opened_by_name"))
        assertEquals("15", j.texto("card_number"))
    }

    @Test
    fun `comanda vai e volta igual`() {
        val c = Comanda(
            numero = 42, mesa = "7", status = "fechada", cliente = "Ana", pessoas = 3,
            controle = false, taxaServicoPct = 10.0, descontoCentavos = 550,
            abertaPor = "Beto", abertaEm = 1_789_000_000_000L, primeiroPedidoEm = 1_789_000_060_000L,
            fechadaEm = 1_789_000_900_123L, ultimaAtividadePor = "Jenifer", ultimaAtividadeEm = 1_789_000_900_123L
        )
        assertEquals(c, Mapeamento.paraComanda(Mapeamento.comanda(c), c.id))
    }

    @Test
    fun `item do cardapio do app nao manda o id do cardapio`() {
        val i = ItemLancado(
            pedidoId = 1, comandaId = 1, itemCardapioId = "almoco-002", nome = "Quarta · Feijoada",
            quantidade = 2, precoUnitCentavos = 2690, pontoId = "cozinha"
        )
        val j = Mapeamento.item(i, "p", "c", 0L)
        assertNull(j.texto("menu_item_id"))
        assertEquals("cozinha", j.texto(Mapeamento.CAMPO_CODIGO_PONTO))
    }

    @Test
    fun `item do cardapio do servidor manda o id do cardapio`() {
        val idServidor = "5567ba2c-59bb-4bbf-9cac-a1b4d9f24978"
        val i = ItemLancado(
            pedidoId = 1, comandaId = 1, itemCardapioId = idServidor, nome = "X",
            quantidade = 1, precoUnitCentavos = 100, pontoId = "drink"
        )
        assertEquals(idServidor, Mapeamento.item(i, "p", "c", 0L).texto("menu_item_id"))
    }
}
