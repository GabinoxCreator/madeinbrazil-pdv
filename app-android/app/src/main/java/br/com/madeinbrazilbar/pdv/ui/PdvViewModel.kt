package br.com.madeinbrazilbar.pdv.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import br.com.madeinbrazilbar.pdv.BuildConfig
import br.com.madeinbrazilbar.pdv.dados.*
import br.com.madeinbrazilbar.pdv.impressao.FilaImpressao
import br.com.madeinbrazilbar.pdv.pagamento.CieloSmart
import br.com.madeinbrazilbar.pdv.pagamento.CredenciaisCielo
import br.com.madeinbrazilbar.pdv.pagamento.PagamentoMaquininha
import br.com.madeinbrazilbar.pdv.pagamento.PagamentoPendente
import br.com.madeinbrazilbar.pdv.sincronia.ClienteServidor
import br.com.madeinbrazilbar.pdv.sincronia.ClienteSupabase
import br.com.madeinbrazilbar.pdv.sincronia.EstadoSincronia
import br.com.madeinbrazilbar.pdv.sincronia.MotorSincronizacao
import br.com.madeinbrazilbar.pdv.sincronia.Sincronia
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class PdvViewModel(app: Application) : AndroidViewModel(app) {

    /**
     * Cardápio em uso. Fica em estado do Compose pra que as telas se
     * redesenhem sozinhas quando o motor baixa um cardápio novo do servidor -
     * sem precisar fechar e abrir o app.
     */
    var cardapio: Cardapio by mutableStateOf(Cardapio.carregar(app))
        private set
    private val banco = BancoLocal.obter(app)
    private val dao = banco.dao()

    /** Conta do terminal, digitada no aparelho (não vem mais dentro do APK). */
    private val terminal = ConfiguracaoTerminal(app)

    /**
     * A fila de envio liga sempre que o app conhece o servidor, mesmo antes do
     * terminal ter login: nada do que for feito antes de configurar se perde,
     * sobe tudo quando o terminal conectar.
     */
    private val sincronia: Sincronia? =
        if (BuildConfig.SERVIDOR_URL.isNotBlank()) Sincronia(banco) else null

    private val repo = Repositorio(dao, { cardapio }, sincronia)

    private val caixa = RepositorioCaixa(dao, sincronia)

    /** Motor de sincronização: envia a fila e traz o que outros terminais fizeram. Só existe com login. */
    private val motor = MutableStateFlow<MotorSincronizacao?>(null)

    /** Liga o motor uma vez só: dois motores mandariam a mesma fila em dobro. */
    private fun ligarMotor(cliente: ClienteServidor) {
        if (motor.value != null || sincronia == null) return
        motor.value = MotorSincronizacao(banco, cliente).also { m ->
            m.iniciar(viewModelScope, { cardapio }) { novo ->
                if (novo != cardapio) {
                    Cardapio.salvar(getApplication(), novo)
                    withContext(Dispatchers.Main) { cardapio = novo }
                }
            }
        }
    }

    init {
        if (sincronia != null && terminal.configurado) {
            ligarMotor(
                ClienteSupabase(
                    BuildConfig.SERVIDOR_URL,
                    BuildConfig.SERVIDOR_CHAVE_PUBLICA,
                    terminal.email,
                    terminal.senha
                )
            )
        }
    }

    /** Sem motor: ou o app não conhece o servidor, ou o terminal ainda não tem login. */
    private fun estadoSemMotor() = EstadoSincronia(habilitada = sincronia != null, semLogin = sincronia != null)

    @OptIn(ExperimentalCoroutinesApi::class)
    val estadoSincronia: StateFlow<EstadoSincronia> =
        combine(motor.flatMapLatest { m -> m?.estado ?: flowOf(estadoSemMotor()) }, dao.operacoesPendentes()) { e, n ->
            e.copy(pendentes = n)
        }.stateIn(viewModelScope, SharingStarted.Eagerly, motor.value?.estado?.value ?: estadoSemMotor())

    private val _emailTerminal = MutableStateFlow(terminal.email)
    /** E-mail da conta do terminal. A senha nunca sai daqui. */
    val emailTerminal: StateFlow<String> = _emailTerminal.asStateFlow()

    /**
     * Conecta o terminal ao servidor. Testa o login ANTES de gravar: senha
     * errada não fica guardada nem liga o motor com uma conta que não entra.
     */
    fun configurarTerminal(email: String, senha: String, aoConectar: () -> Unit = {}) {
        if (sincronia == null) {
            _aviso.value = "Este app foi instalado sem o endereço do servidor"
            return
        }
        val emailLimpo = email.trim()
        if (emailLimpo.isBlank() || senha.isBlank()) {
            _aviso.value = "Informe o e-mail e a senha do terminal"
            return
        }
        viewModelScope.launch {
            _ocupado.value = true
            try {
                val cliente = ClienteSupabase(
                    BuildConfig.SERVIDOR_URL, BuildConfig.SERVIDOR_CHAVE_PUBLICA, emailLimpo, senha
                )
                cliente.renovarLogin()
                // o motor liga uma vez só; se já rodava com outra conta, segue com ela até reabrir o app
                val contaTrocada = motor.value != null && (terminal.email != emailLimpo || terminal.senha != senha)
                terminal.salvar(emailLimpo, senha)
                _emailTerminal.value = emailLimpo
                ligarMotor(cliente)   // o cliente acabou de entrar: começa com o token na mão
                _aviso.value = if (contaTrocada)
                    "Terminal conectado. A nova conta vale para o envio quando o app for reaberto."
                else "Terminal conectado"
                aoConectar()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _aviso.value = e.message ?: "Não foi possível conectar o terminal"
            } finally {
                _ocupado.value = false
            }
        }
    }

    val sessaoAberta: StateFlow<SessaoCaixa?> = caixa.sessaoAberta()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    fun movimentos(sessaoId: Long) = caixa.movimentos(sessaoId)
    fun pagamentosDaComanda(comandaId: Long) = caixa.pagamentosDaComanda(comandaId)

    fun abrirCaixa(fundoCentavos: Long) = rodar { caixa.abrirCaixa(fundoCentavos, _operador.value) }

    fun registrarMovimento(tipo: String, valorCentavos: Long, motivo: String) =
        rodar { caixa.registrarMovimento(tipo, valorCentavos, motivo, _operador.value) }

    fun receber(comandaId: Long, metodo: String, valorCentavos: Long, recebidoCentavos: Long?) =
        rodar { caixa.receber(comandaId, metodo, valorCentavos, recebidoCentavos, _operador.value) }

    fun fecharCaixa(contadoCentavos: Long, observacao: String?) =
        rodar { caixa.fecharCaixa(contadoCentavos, _operador.value, observacao) }

    // ------------------------------------------------- maquininha Cielo Smart

    private val maquininha = PagamentoMaquininha(dao, caixa)

    /** Só é true numa Cielo Smart com as credenciais preenchidas. Celular comum: false. */
    val maquininhaDisponivel: Boolean = CieloSmart.maquininhaDisponivel(app)

    /** Cobrança mandada pra maquininha que ainda não teve resposta. */
    val pendenteMaquininha: StateFlow<PagamentoPendente?> = maquininha.pendenteAoVivo()
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val _cobrandoNaMaquininha = MutableStateFlow(false)
    /** True enquanto o app da Cielo está aberto: nessa hora o pendente é normal, não é aviso. */
    val cobrandoNaMaquininha: StateFlow<Boolean> = _cobrandoNaMaquininha.asStateFlow()

    init {
        viewModelScope.launch {
            try { maquininha.arrumarAoAbrir() } catch (e: CancellationException) { throw e } catch (e: Exception) { }
        }
    }

    /**
     * Grava o pendente e abre a Cielo. `abrir` recebe a URI e devolve false
     * se não conseguiu abrir o app da maquininha.
     */
    fun cobrarNaMaquininha(comandaId: Long, metodo: String, valorCentavos: Long, abrir: (String) -> Boolean) {
        viewModelScope.launch {
            _ocupado.value = true
            try {
                when (val p = maquininha.preparar(
                    comandaId, metodo, valorCentavos, _operador.value, CredenciaisCielo.doApp()
                )) {
                    is PagamentoMaquininha.Preparo.Erro -> _aviso.value = p.mensagem
                    is PagamentoMaquininha.Preparo.Pronto -> {
                        _cobrandoNaMaquininha.value = true
                        if (!abrir(p.uri)) {
                            _cobrandoNaMaquininha.value = false
                            maquininha.descartar()
                            _aviso.value = "Não consegui abrir o app da maquininha"
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _aviso.value = e.message ?: "Falha ao cobrar na maquininha"
            } finally {
                _ocupado.value = false
            }
        }
    }

    /** A Cielo abriu mibpdv://pagamento?response=... */
    fun retornoDaMaquininha(uriCrua: String) {
        viewModelScope.launch {
            val r = try {
                maquininha.processarRetorno(CieloSmart.lerRetorno(uriCrua))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                ResultadoOperacao.Erro(e.message ?: "Falha ao ler a resposta da maquininha")
            }
            _aviso.value = when (r) {
                is ResultadoOperacao.Ok -> r.mensagem
                is ResultadoOperacao.Erro -> r.mensagem
            }
            _cobrandoNaMaquininha.value = false
        }
    }

    /** O app voltou pra frente sem resposta da Cielo: se ficou pendente, vira aviso. */
    fun voltouDaMaquininha() { _cobrandoNaMaquininha.value = false }

    fun registrarPendenteComoPago() = rodar { maquininha.registrarComoPago() }
    fun descartarPendenteMaquininha() = rodar { maquininha.descartar() }

    suspend fun apuracao(contadoCentavos: Long? = null): Fechamento? = caixa.apuracao(contadoCentavos)
    suspend fun saldoDe(comandaId: Long): SaldoComanda? = caixa.saldo(comandaId)

    /** Motor de impressao: roda em segundo plano, a tela nunca espera termica. */
    private val fila = FilaImpressao(dao, { cardapio }, viewModelScope, sincronia).also { it.iniciar() }

    val historicoImpressao: StateFlow<List<TrabalhoImpressao>> = repo.historicoImpressao()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val impressoesEmAberto: StateFlow<Int> = repo.impressoesEmAberto()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    fun reimprimir(id: Long) = rodar { repo.reimprimir(id) }

    /**
     * Quem esta operando. Sem senha por enquanto: o mecanismo de login do
     * colaborador no terminal ainda nao foi definido (codigo + PIN e o padrao
     * de salao). Isto e um marcador provisorio, nao uma decisao.
     *
     * Comeca no primeiro da equipe. Sem ninguem na equipe, fica um texto de
     * reserva em vez de travar o app. Se chegar cardapio novo e essa pessoa
     * nao estiver mais na equipe, o operador NAO muda sozinho no meio do turno.
     */
    private val _operador = MutableStateFlow(cardapio.colaboradores.firstOrNull()?.nome ?: "Operador não escolhido")
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
    fun cancelarComanda(comandaId: Long, motivo: String) =
        rodar { repo.cancelarComanda(comandaId, motivo, _operador.value) }
    fun imprimirConferencia(comandaId: Long) = rodar { repo.imprimirConferencia(comandaId) }

    suspend fun contaDe(comandaId: Long): Conta? = repo.conta(comandaId)
    suspend fun previaConferencia(comandaId: Long): String? =
        repo.montarConferencia(comandaId)?.first
}
