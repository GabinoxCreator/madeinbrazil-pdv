#!/usr/bin/env python3
"""
Estação de impressão do delivery, rodando no computador do bar.

Faz o mesmo papel do app Android: pega os cupons das duas filas do servidor
(delivery e comandas lançadas pelo navegador), imprime nas térmicas da rede
local por ESC/POS (porta 9100) e devolve o resultado.

Só depende do Python que já vem no macOS (3.8+). Para rodar à mão:

    python3 ferramentas/estacao-impressao.py

No computador do bar ela roda sozinha: a cópia instalada fica em
~/Library/Application Support/MadeInBrazilPDV/ (fora da pasta Downloads, que
o macOS bloqueia para serviços) e sobe pelo launchd
(~/Library/LaunchAgents/com.madeinbrazil.estacao-impressao.plist), com
RunAtLoad e KeepAlive: liga com o computador e volta sozinha se cair.
O arquivo estacao-conta.json (e-mail, senha do terminal e chave publicável)
fica ao lado e NÃO vai para o git.
"""

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

SUPABASE_URL = "https://ykhywmtauljpjuqxxpez.supabase.co"
ENV_PAINEL = os.path.expanduser("~/Downloads/Projetos/madeinbrazil-pdv-painel/.env")
CONTA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "estacao-conta.json")

LARGURA = 48  # colunas da Elgin i9 em fonte normal
ESPERA = 3  # segundos entre consultas à fila


def chave_publica():
    """Chave publicável do painel (a mesma que o site usa no navegador)."""
    with open(CONTA, encoding="utf8") as f:
        return json.load(f)["apikey"]


def post(caminho, corpo, apikey, token=None):
    pedido = urllib.request.Request(
        SUPABASE_URL + caminho,
        data=json.dumps(corpo).encode("utf8"),
        headers={
            "apikey": apikey,
            "Authorization": "Bearer " + (token or apikey),
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(pedido, timeout=20) as r:
        texto = r.read().decode("utf8")
    return json.loads(texto) if texto.strip() else {}


def entrar(apikey):
    with open(CONTA, encoding="utf8") as f:
        conta = json.load(f)
    resposta = post(
        "/auth/v1/token?grant_type=password",
        {"email": conta["email"], "password": conta["senha"]},
        apikey,
    )
    return resposta["access_token"]


# ---------------------------------------------------------------- cupom
# A Elgin i9 imprime claro demais no padrão: negrito + dupla batida deixam
# o papel legível na cozinha. Tamanho dobrado no que precisa ser lido de longe.
INIT = b"\x1b@" + b"\x1bt\x03" + b"\x1bG\x01"   # início + acentos PC860 + dupla batida
NEGRITO = b"\x1bE\x01"
SEM_NEGRITO = b"\x1bE\x00"
GRANDE = b"\x1d!\x11"      # dobra largura e altura
ALTO = b"\x1d!\x01"        # dobra só a altura
NORMAL = b"\x1d!\x00"
CENTRO = b"\x1ba\x01"
ESQUERDA = b"\x1ba\x00"
CORTAR = b"\n\n\n\n\x1dV\x00"


def cp(texto):
    return texto.encode("cp860", errors="replace")


def txt(texto="", grande=False, alto=False, negrito=False, centro=False):
    b = b""
    if centro:
        b += CENTRO
    if grande:
        b += GRANDE
    elif alto:
        b += ALTO
    if negrito:
        b += NEGRITO
    b += cp(texto) + b"\n"
    if negrito:
        b += SEM_NEGRITO
    if grande or alto:
        b += NORMAL
    if centro:
        b += ESQUERDA
    return b


def colunas(esquerda, direita, largura=None):
    largura = largura or LARGURA
    espaco = largura - len(esquerda) - len(direita)
    return esquerda + (" " * max(1, espaco)) + direita


def traco(c="-"):
    return cp(c * LARGURA) + b"\n"


def dinheiro(centavos) -> str:
    v = int(centavos or 0)
    return f"R$ {v // 100},{v % 100:02d}"


def hora(iso):
    return iso[11:16] if iso else ""


BEBIDAS = {"drink", "cerveja"}


def item_linhas(item, bebida=False):
    """Uma linha grande com quantidade e nome, complementos e observação abaixo."""
    b = txt(f"{item.get('quantidade')}x {item.get('nome')}", alto=True, negrito=True)
    opcoes = item.get("opcoes") or []
    if opcoes:
        partes = [f"{o.get('quantidade')}x {o.get('nome')}" if (o.get("quantidade") or 1) > 1 else str(o.get("nome"))
                  for o in opcoes]
        b += txt("   " + ", ".join(partes))
    if item.get("observacao"):
        b += txt(f"   OBS: {item['observacao']}", negrito=True)
    if bebida:
        b += txt("   >>> BEBIDA <<<", negrito=True)
    return b


def cupom_comanda(t):
    """Produção de um pedido lançado pelo navegador (painel ou /garcom)."""
    comanda = t.get("comanda") or {}
    pedido = t.get("pedido") or {}
    ponto = t.get("ponto") or {}
    b = INIT
    b += txt(str(ponto.get("nome") or "").upper(), grande=True, negrito=True, centro=True)
    b += traco("=")
    b += txt(f"COMANDA {comanda.get('numero')}", grande=True, negrito=True)
    if comanda.get("mesa"):
        b += txt(f"Mesa {comanda['mesa']}", alto=True, negrito=True)
    if comanda.get("cliente"):
        b += txt(str(comanda["cliente"]))
    b += txt(colunas(hora(pedido.get("criado_em")), str(pedido.get("operador") or "")))
    b += traco()
    for item in t.get("itens") or []:
        b += item_linhas(item)
    b += traco("=")
    return b + CORTAR


def cupom_delivery(t):
    pedido = t.get("pedido") or {}
    ponto = t.get("ponto") or {}
    tipo = t.get("tipo") or ""
    entrega = pedido.get("modo") == "entrega"
    endereco = pedido.get("endereco") or {}
    telefone = str(pedido.get("telefone") or "")

    b = INIT
    b += txt("MADE IN BRAZIL FOOD", negrito=True, centro=True)
    if tipo == "via_entrega":
        b += txt("VIA DE ENTREGA" if entrega else "VIA DA RETIRADA", grande=True, negrito=True, centro=True)
    elif tipo == "cancelamento":
        b += txt("PEDIDO CANCELADO", grande=True, negrito=True, centro=True)
    else:
        b += txt(str(ponto.get("nome") or "").upper(), grande=True, negrito=True, centro=True)
    b += traco("=")

    b += txt(f"PEDIDO #{pedido.get('numero')}", grande=True, negrito=True)
    b += txt(colunas("ENTREGA" if entrega else "RETIRADA", hora(pedido.get("criado_em"))), negrito=True)
    b += txt(str(pedido.get("cliente") or ""), alto=True, negrito=True)
    if telefone and tipo == "via_entrega":
        b += txt(telefone, alto=True, negrito=True)
    b += traco()

    for item in t.get("itens") or []:
        b += item_linhas(item, bebida=tipo == "via_entrega" and str(item.get("ponto") or "") in BEBIDAS)

    if tipo == "via_entrega":
        b += traco()
        b += txt(colunas("Subtotal", dinheiro(pedido.get("subtotal_cents"))))
        if entrega:
            b += txt(colunas("Taxa de entrega", dinheiro(pedido.get("taxa_entrega_cents"))))
        if pedido.get("desconto_cents"):
            b += txt(colunas("Desconto", "- " + dinheiro(pedido.get("desconto_cents"))))
        b += txt(colunas("TOTAL", dinheiro(pedido.get("total_cents")), LARGURA // 2), grande=True, negrito=True)
        if pedido.get("pago"):
            b += txt("PAGO ONLINE - NAO COBRAR", grande=True, negrito=True, centro=True)
        else:
            troco = pedido.get("troco_para_cents")
            b += txt("RECEBER: " + str(pedido.get("pagamento") or ""), alto=True, negrito=True)
            if troco:
                b += txt("Troco para " + dinheiro(troco), alto=True, negrito=True)
        if endereco:
            b += traco()
            b += txt("ENTREGAR EM", negrito=True)
            b += txt(f"{endereco.get('rua')}, {endereco.get('numero')}", grande=True, negrito=True)
            b += txt(str(endereco.get("bairro") or ""), alto=True, negrito=True)
            if endereco.get("complemento"):
                b += txt(str(endereco["complemento"]), negrito=True)
            if endereco.get("referencia"):
                b += txt("Ref.: " + str(endereco["referencia"]))
            if endereco.get("distancia_km"):
                b += txt(f"{float(endereco['distancia_km']):.1f} km")

    if pedido.get("observacao"):
        b += traco()
        b += txt("OBS: " + str(pedido["observacao"]), alto=True, negrito=True)

    b += traco("=")
    return b + CORTAR


def imprimir(ip, porta, dados):
    with socket.create_connection((ip, porta), timeout=6) as s:
        s.sendall(dados)


def main():
    apikey = chave_publica()
    token = entrar(apikey)
    print("estação ligada — Ctrl+C para parar")
    renovado = time.time()

    while True:
        try:
            if time.time() - renovado > 45 * 60:
                token = entrar(apikey)
                renovado = time.time()

            for fila, monta, rotulo in (
                ("dlv", cupom_delivery, "delivery"),
                ("pdv", cupom_comanda, "comanda"),
            ):
                trabalhos = post(f"/rest/v1/rpc/{fila}_reservar_impressoes", {"p_limite": 5}, apikey, token) or []
                for t in trabalhos:
                    ponto = t.get("ponto") or {}
                    ok, erro = True, None
                    try:
                        imprimir(str(ponto.get("ip")), int(ponto.get("porta") or 9100), monta(t))
                        alvo = (t.get("pedido") or {}).get("numero") or (t.get("comanda") or {}).get("numero")
                        print(f"  impresso: {rotulo} {alvo} em {ponto.get('nome')}")
                    except Exception as e:  # noqa: BLE001 — qualquer falha volta para a fila
                        ok, erro = False, str(e)[:200]
                        print(f"  FALHA em {ponto.get('nome')}: {erro}")
                    post(
                        f"/rest/v1/rpc/{fila}_concluir_impressao",
                        {"p_trabalho": t.get("trabalho_id"), "p_ok": ok, "p_erro": erro},
                        apikey,
                        token,
                    )
            time.sleep(ESPERA)
        except KeyboardInterrupt:
            print("\nestação desligada")
            return
        except urllib.error.HTTPError as e:
            print("erro do servidor:", e.code, e.read().decode("utf8", "ignore")[:200])
            token = entrar(apikey)
            renovado = time.time()
            time.sleep(ESPERA)
        except Exception as e:  # noqa: BLE001 — rede caindo não pode derrubar a estação
            print("erro:", str(e)[:200])
            time.sleep(ESPERA)


if __name__ == "__main__":
    sys.exit(main())
