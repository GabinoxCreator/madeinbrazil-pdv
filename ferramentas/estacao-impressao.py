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
INIT = b"\x1b@" + b"\x1bt\x03" + b"\x1bG\x01" + b"\x1b3\x24"
# início + acentos PC860 + dupla batida (letra escura) + entrelinha maior,
# para o cupom não sair com tudo grudado
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


def quebrar(texto, largura):
    """Quebra a linha respeitando o recuo dos complementos."""
    texto = str(texto or "")
    if len(texto) <= largura:
        return [texto]
    recuo = " " * (len(texto) - len(texto.lstrip(" ")))
    partes, atual = [], ""
    for palavra in texto.split():
        tentativa = (atual + " " + palavra).strip()
        if len(recuo + tentativa) <= largura:
            atual = tentativa
        else:
            partes.append(recuo + atual)
            atual = palavra
    partes.append(recuo + atual)
    return partes


def render_linhas(linhas):
    """Imprime o cupom que o SERVIDOR montou (chave 'linhas').

    Cada linha: {"t": texto} ou {"esq","dir"} ou {"tipo": traco|traco_duplo|espaco}.
    Estilo em "e": b = negrito, a = altura dobrada, g = largura e altura dobradas.
    "c": true centraliza.
    """
    b = INIT
    for ln in linhas:
        tipo = ln.get("tipo")
        if tipo == "traco":
            b += traco()
            continue
        if tipo == "traco_duplo":
            b += traco("=")
            continue
        if tipo == "espaco":
            b += txt()
            continue
        estilo = ln.get("e")
        grande, alto, negrito = estilo == "g", estilo == "a", estilo == "b"
        largura = LARGURA // 2 if grande else LARGURA
        if "esq" in ln:
            b += txt(colunas(str(ln.get("esq") or ""), str(ln.get("dir") or ""), largura),
                     grande=grande, alto=alto, negrito=negrito, centro=ln.get("c", False))
            continue
        for parte in quebrar(ln.get("t"), largura):
            b += txt(parte, grande=grande, alto=alto, negrito=negrito, centro=ln.get("c", False))
    return b + CORTAR


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
    """Delivery. Cozinha/bar: letra grande, direto ao ponto.
    Caixa (via de entrega/retirada): letra normal, blocos separados,
    negrito só no que decide a ação — total, o que receber e o endereço."""
    pedido = t.get("pedido") or {}
    ponto = t.get("ponto") or {}
    tipo = t.get("tipo") or ""
    entrega = pedido.get("modo") == "entrega"
    endereco = pedido.get("endereco") or {}
    telefone = str(pedido.get("telefone") or "")
    via = tipo == "via_entrega"

    b = INIT
    b += txt("MADE IN BRAZIL FOOD", centro=True)
    if via:
        b += txt("VIA DE ENTREGA" if entrega else "VIA DA RETIRADA", alto=True, negrito=True, centro=True)
    elif tipo == "cancelamento":
        b += txt("PEDIDO CANCELADO", grande=True, negrito=True, centro=True)
    else:
        b += txt(str(ponto.get("nome") or "").upper(), grande=True, negrito=True, centro=True)
    b += traco("=")

    if via:
        # cabeçalho enxuto: número, hora, cliente e telefone
        b += txt(colunas(f"PEDIDO #{pedido.get('numero')}", hora(pedido.get("criado_em"))), negrito=True)
        b += txt(("Entrega" if entrega else "Retirada") + " · " + str(pedido.get("cliente") or ""))
        if telefone:
            b += txt("Telefone " + telefone)
        b += txt()
        b += txt("ITENS")
        b += traco()
        for item in t.get("itens") or []:
            bebida = str(item.get("ponto") or "") in BEBIDAS
            nome = f"{item.get('quantidade')}x {item.get('nome')}"
            b += txt(nome + ("   [BEBIDA]" if bebida else ""), negrito=bebida)
            for o in item.get("opcoes") or []:
                q = o.get("quantidade") or 1
                b += txt(f"    {str(q) + 'x ' if q > 1 else ''}{o.get('nome')}")
            if item.get("observacao"):
                b += txt(f"    obs: {item['observacao']}")
        b += traco()
        b += txt(colunas("Subtotal", dinheiro(pedido.get("subtotal_cents"))))
        if entrega:
            b += txt(colunas("Taxa de entrega", dinheiro(pedido.get("taxa_entrega_cents"))))
        if pedido.get("desconto_cents"):
            b += txt(colunas("Desconto", "- " + dinheiro(pedido.get("desconto_cents"))))
        b += txt(colunas("TOTAL", dinheiro(pedido.get("total_cents"))), negrito=True)
        b += txt()
        if pedido.get("pago"):
            b += txt("PAGO ONLINE - NAO COBRAR", alto=True, negrito=True, centro=True)
        else:
            b += txt("RECEBER: " + str(pedido.get("pagamento") or ""), negrito=True)
            if pedido.get("troco_para_cents"):
                b += txt("Levar troco para " + dinheiro(pedido["troco_para_cents"]), negrito=True)
        if entrega and endereco:
            b += txt()
            b += traco("=")
            b += txt("ENTREGAR EM", negrito=True, centro=True)
            b += traco("=")
            b += txt(f"{endereco.get('rua')}, {endereco.get('numero')}", alto=True, negrito=True)
            b += txt(str(endereco.get("bairro") or ""))
            if endereco.get("complemento"):
                b += txt("Compl.: " + str(endereco["complemento"]))
            if endereco.get("referencia"):
                b += txt("Ref.: " + str(endereco["referencia"]))
            if endereco.get("distancia_km"):
                b += txt(f"Distancia: {float(endereco['distancia_km']):.1f} km")
            if telefone:
                b += txt("Cliente: " + str(pedido.get("cliente") or "") + " · " + telefone)
        if pedido.get("observacao"):
            b += txt()
            b += txt("OBSERVACAO DO PEDIDO", negrito=True)
            b += txt(str(pedido["observacao"]))
        b += traco("=")
        return b + CORTAR

    # cupom de produção (cozinha e bares): grande e curto
    b += txt(f"PEDIDO #{pedido.get('numero')}", grande=True, negrito=True)
    b += txt(colunas("ENTREGA" if entrega else "RETIRADA", hora(pedido.get("criado_em"))), negrito=True)
    b += txt(str(pedido.get("cliente") or ""), alto=True, negrito=True)
    b += traco()
    for item in t.get("itens") or []:
        b += item_linhas(item)
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
                        # o servidor manda o cupom pronto; o desenho local é só reserva
                        dados = render_linhas(t["linhas"]) if t.get("linhas") else monta(t)
                        imprimir(str(ponto.get("ip")), int(ponto.get("porta") or 9100), dados)
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
