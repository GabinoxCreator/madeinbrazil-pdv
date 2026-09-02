package br.com.madeinbrazilbar.pdv.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import br.com.madeinbrazilbar.pdv.dados.*
import br.com.madeinbrazilbar.pdv.impressao.FilaImpressao
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class PdvViewModel(app: Application) : AndroidViewModel(app) {

    val cardapio: Cardapio = Cardapio.carregar(app)
    private val dao = BancoLocal.obter(app).dao()
    private val repo = Repositorio(dao, cardapio)

    /** Motor de impressao: roda em segundo plano, a tela nunca espera termica. */
    private val fila = FilaImpressao(dao, cardapio, viewModelScope).also { it.iniciar() }

    val historicoImpressao: StateFlow<List<TrabalhoImpressao>> = repo.historicoImpressao()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val impressoesEmAberto: StateFlow<Int> = repo.impressoesEmAberto()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    fun reimprimir(id: Long) = rodar { repo.reimprimir(id) }

    /**
     * Quem esta operando. Sem senha por enquanto: o mecanismo de login do
     * colaborador no terminal ainda nao foi definido (codigo + PIN e o padrao
     * de salao). Isto e um marcador provisorio, nao uma decisao.
     */
    private val _operador = MutableStateFlow(cardapio.colaboradores.first().nome)
    val operador: StateFlow<String> = _operador.asStateFlow()
    fun trocarOperador(nome: String) { _operador.value = nome }

    private val _aviso = MutableStateFlow<String?>(null)
    val aviso: StateFlow<String?> = _aviso.asStateFlow()
    fun limparAviso() { _aviso.value = null }

    private val _ocupado = MutableStateFlow(false)
    val ocupado: StateFlow<Boolean> = _ocupado.asStateFlow()

    val comandas: StateFlow<List<Comanda>> = repo.comandasVivas()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun comanda(id: Long) = repo.comanda(id)
    fun itens(id: Long) = repo.itensDaComanda(id)

    private fun rodar(bloco: suspend () -> ResultadoOperacao) {
        viewModelScope.launch {
            _ocupado.value = true
            val r = try {
                bloco()
            } catch (e: Exception) {
                ResultadoOperacao.Erro(e.message ?: "Falha inesperada")
            }
            _aviso.value = when (r) {
                is ResultadoOperacao.Ok -> r.mensagem
                is ResultadoOperacao.Erro -> r.mensagem
            }
            _ocupado.value = false
        }
    }

    fun abrirComanda(numero: Int, mesa: String?, pessoas: Int, cliente: String?, controle: Boolean) =
        rodar { repo.abrirComanda(numero, mesa, pessoas, cliente, controle, _operador.value) }

    fun lancarPedido(comandaId: Long, escolhidos: List<ItemEscolhido>, aoTerminar: () -> Unit) {
        viewModelScope.launch {
            _ocupado.value = true
            val r = try {
                repo.lancarPedido(comandaId, escolhidos, _operador.value)
            } catch (e: Exception) {
                ResultadoOperacao.Erro(e.message ?: "Falha inesperada")
            }
            _aviso.value = when (r) {
                is ResultadoOperacao.Ok -> r.mensagem
                is ResultadoOperacao.Erro -> r.mensagem
            }
            _ocupado.value = false
            aoTerminar()
        }
    }

    fun cancelarItem(itemId: Long, motivo: String) =
        rodar { repo.cancelarItem(itemId, motivo, _operador.value) }

    fun ajustarConta(comandaId: Long, pessoas: Int, cobrarServico: Boolean, descontoCentavos: Long) =
        rodar { repo.ajustarConta(comandaId, pessoas, cobrarServico, descontoCentavos) }

    fun fecharComanda(comandaId: Long) = rodar { repo.fecharComanda(comandaId, _operador.value) }
    fun reabrirComanda(comandaId: Long) = rodar { repo.reabrirComanda(comandaId, _operador.value) }
    fun imprimirConferencia(comandaId: Long) = rodar { repo.imprimirConferencia(comandaId) }

    suspend fun contaDe(comandaId: Long): Conta? = repo.conta(comandaId)
    suspend fun previaConferencia(comandaId: Long): String? =
        repo.montarConferencia(comandaId)?.first
}
