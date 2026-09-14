package br.com.madeinbrazilbar.pdv.dados

import android.content.Context

/**
 * Conta do terminal (e-mail e senha) usada pra falar com o servidor.
 *
 * Antes vinha compilada dentro do APK - e APK é só um zip: qualquer um com o
 * arquivo instalado lia a senha. Agora é digitada no próprio aparelho, na
 * tela "Terminal", e fica só aqui, nas preferências PRIVADAS do app (outro
 * app do terminal não enxerga). A senha nunca volta pra tela.
 */
class ConfiguracaoTerminal(context: Context) {

    private val preferencias =
        context.applicationContext.getSharedPreferences(ARQUIVO, Context.MODE_PRIVATE)

    val email: String get() = preferencias.getString(CHAVE_EMAIL, null) ?: ""
    val senha: String get() = preferencias.getString(CHAVE_SENHA, null) ?: ""

    val configurado: Boolean get() = email.isNotBlank() && senha.isNotBlank()

    fun salvar(email: String, senha: String) {
        preferencias.edit()
            .putString(CHAVE_EMAIL, email)
            .putString(CHAVE_SENHA, senha)
            .apply()
    }

    private companion object {
        const val ARQUIVO = "terminal"
        const val CHAVE_EMAIL = "email"
        const val CHAVE_SENHA = "senha"
    }
}
