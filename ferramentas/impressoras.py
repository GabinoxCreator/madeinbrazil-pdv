#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Diagnostico das termicas Elgin i9 da rede do bar.

Nao depende de nada: so Python 3, que ja vem no Mac.
Precisa estar no Wi-Fi do bar (faixa 192.168.0.x).

USO:
    python3 impressoras.py procurar          # varre a rede e acha toda termica ligada
    python3 impressoras.py testar 192.168.0.70   # imprime um cupom de teste
    python3 impressoras.py testar todas          # imprime em todas que achar

A rede e detectada sozinha a partir do IP desta maquina. Se precisar
forcar outra faixa:
    python3 impressoras.py procurar 192.168.0
"""

import socket
import sys
from concurrent.futures import ThreadPoolExecutor

PORTA = 9100
REDE_DA_ESPECIFICACAO = "192.168.0"   # levantado em campo em 31/08/2026


def minha_rede():
    """Descobre a faixa desta maquina (ex: '192.168.1') sem depender de nada."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))      # nao envia nada, so resolve a rota de saida
        ip = s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()
    return ip.rsplit(".", 1)[0]

# O que a especificacao mapeou em campo (31/08/2026)
CONHECIDAS = {
    "192.168.0.70": "Caixa",
    "192.168.0.71": "Cozinha (IP NAO CONFIRMADO)",
    "192.168.0.72": "Bar de drink",
    "192.168.0.73": "Bar de cerveja",
}

# ---------------------------------------------------------------- ESC/POS
ESC = b"\x1b"
GS = b"\x1d"

INICIALIZA = ESC + b"@"
CODEPAGE_PC860 = ESC + b"t\x03"       # PC860 = portugues (acentuacao)
CENTRALIZA = ESC + b"a\x01"
ESQUERDA = ESC + b"a\x00"
NEGRITO_ON = ESC + b"E\x01"
NEGRITO_OFF = ESC + b"E\x00"
DOBRO = GS + b"!\x11"                  # altura e largura dobradas
NORMAL = GS + b"!\x00"
CORTA = GS + b"V\x42\x00"              # avanca e corta


def texto(s):
    """Converte para o codepage da impressora. Acento que nao existe vira '?'."""
    return s.encode("cp860", errors="replace")


def cupom_de_teste(nome_do_ponto, ip):
    p = bytearray()
    p += INICIALIZA
    p += CODEPAGE_PC860
    p += CENTRALIZA
    p += DOBRO + NEGRITO_ON
    p += texto("MADE IN BRAZIL\n")
    p += NORMAL + NEGRITO_OFF
    p += texto("TESTE DE IMPRESSAO\n")
    p += texto("=" * 32 + "\n")
    p += ESQUERDA
    p += texto("Ponto...: %s\n" % nome_do_ponto)
    p += texto("IP......: %s:%d\n" % (ip, PORTA))
    p += texto("-" * 32 + "\n")
    p += NEGRITO_ON + texto("TESTE DE ACENTUACAO:\n") + NEGRITO_OFF
    # Se sair certo aqui, a codepage esta correta e o cardapio vai imprimir legivel
    p += texto("Ação, coração, pão, açúcar\n")
    p += texto("Feijoada · Filé · Tilápia\n")
    p += texto("Strogonoff · Parmegiana\n")
    p += texto("Guarnição · Porção · Limão\n")
    p += texto("-" * 32 + "\n")
    p += texto("Se os acentos acima estao certos,\n")
    p += texto("a impressao do PDV vai funcionar.\n")
    p += texto("\n")
    p += CENTRALIZA
    p += texto("NAO E DOCUMENTO FISCAL\n")
    p += b"\n\n\n"
    p += CORTA
    return bytes(p)


# ---------------------------------------------------------------- rede
def porta_aberta(ip, timeout=0.4):
    try:
        with socket.create_connection((ip, PORTA), timeout=timeout):
            return True
    except OSError:
        return False


def procurar(rede=None):
    if rede is None:
        rede = minha_rede()
        if rede is None:
            print("Nao consegui detectar a rede. Voce esta conectado no Wi-Fi?")
            return []
        print("Esta maquina esta na rede: %s.x" % rede)
        if rede != REDE_DA_ESPECIFICACAO:
            print("")
            print("  ATENCAO: a especificacao mapeou as impressoras em %s.x," % REDE_DA_ESPECIFICACAO)
            print("  e voce esta em %s.x. Ou voce nao esta no Wi-Fi do bar," % rede)
            print("  ou a rede do bar mudou. Vou varrer %s.x mesmo assim -" % rede)
            print("  se as impressoras aparecerem aqui, a spec e que esta desatualizada.")
        print("")

    print("Varrendo %s.1-254 na porta %d ...\n" % (rede, PORTA))
    alvos = ["%s.%d" % (rede, i) for i in range(1, 255)]
    with ThreadPoolExecutor(max_workers=64) as pool:
        achados = [ip for ip, ok in zip(alvos, pool.map(porta_aberta, alvos)) if ok]

    if not achados:
        print("Nenhuma impressora respondeu em %s.x\n" % rede)
        print("Provaveis motivos, em ordem:")
        print("  1. voce nao esta no Wi-Fi do bar (mais provavel)")
        print("  2. as impressoras estao desligadas")
        print("  3. as termicas foram movidas pra outra faixa de IP")
        return []

    print("%d impressora(s) respondendo:\n" % len(achados))
    for ip in achados:
        etiqueta = CONHECIDAS.get(ip, ">>> NAO ESTAVA NO MAPA <<<")
        print("   %-16s %s" % (ip, etiqueta))

    print("")
    faltando = [ip for ip in CONHECIDAS if ip not in achados and ip.startswith(rede + ".")]
    if faltando:
        print("Do mapa da especificacao, NAO responderam:")
        for ip in faltando:
            print("   %-16s %s" % (ip, CONHECIDAS[ip]))
        print("")
    return achados


def testar(ip):
    nome = CONHECIDAS.get(ip, "Desconhecido")
    print("Enviando cupom de teste para %s (%s) ..." % (ip, nome))
    try:
        with socket.create_connection((ip, PORTA), timeout=5) as s:
            s.sendall(cupom_de_teste(nome, ip))
        print("   enviado. Va ate a impressora e veja se saiu.\n")
        return True
    except OSError as e:
        print("   FALHOU: %s\n" % e)
        return False


# ---------------------------------------------------------------- main
if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] not in ("procurar", "testar"):
        print(__doc__)
        sys.exit(1)

    if args[0] == "procurar":
        procurar(args[1] if len(args) > 1 else None)
    else:
        if len(args) < 2:
            print("Faltou o IP. Ex: python3 impressoras.py testar 192.168.0.70")
            sys.exit(1)
        if args[1] == "todas":
            for ip in procurar():
                testar(ip)
        else:
            testar(args[1])
