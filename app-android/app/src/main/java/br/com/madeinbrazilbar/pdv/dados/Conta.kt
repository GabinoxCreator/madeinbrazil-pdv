package br.com.madeinbrazilbar.pdv.dados

/**
 * Calculo da conta. Ponto UNICO da matematica de dinheiro do app:
 * a tela, o cupom de conferencia e o recebimento leem daqui.
 * Se a regra mudar, muda num lugar so.
 */
data class Conta(
    val subtotalCentavos: Long,
    val taxaServicoPct: Double,
    val servicoCentavos: Long,
    val descontoCentavos: Long,
    val totalCentavos: Long,
    val pessoas: Int,
    val porPessoaCentavos: Long
) {
    companion object {
        fun calcular(
            itens: List<ItemLancado>,
            taxaServicoPct: Double,
            descontoCentavos: Long,
            pessoas: Int
        ): Conta {
            val subtotal = itens.filter { it.status == StatusItem.ATIVO }
                .sumOf { it.totalCentavos }
            val servico = Dinheiro.percentual(subtotal, taxaServicoPct)
            // desconto nunca deixa o total negativo
            val desconto = descontoCentavos.coerceAtMost(subtotal + servico)
            val total = subtotal + servico - desconto
            val n = pessoas.coerceAtLeast(1)
            return Conta(
                subtotalCentavos = subtotal,
                taxaServicoPct = taxaServicoPct,
                servicoCentavos = servico,
                descontoCentavos = desconto,
                totalCentavos = total,
                pessoas = n,
                // arredonda para cima: dividir 10,00 por 3 nao pode somar 9,99
                porPessoaCentavos = if (total <= 0) 0 else (total + n - 1) / n
            )
        }
    }
}
