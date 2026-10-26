#!/bin/bash
#
# Instalador do Sistema de Busca Ativa Escolar
# Secretaria de Educacao e Inovacao Pedagogica de Goiana - PE
#
# Uso:
#   sudo bash install.sh                  # instala ou atualiza em /opt/sistemas-locais
#   sudo bash install.sh /outro/caminho   # instala ou atualiza em outro caminho
#
# Instalacao NOVA:      gera senhas aleatorias (banco de dados e administrador) e as grava em .env
# Instalacao EXISTENTE: atualiza apenas o sistema (backend e front-end). Preserva o
#                       docker-compose.yml, o nginx.conf, o .env, as senhas e todos os dados.
#
set -e

INSTALL_DIR="${1:-/opt/sistemas-locais}"
VERSAO="2026-10-26"

echo "=========================================="
echo " Instalador - Busca Ativa Escolar ($VERSAO)"
echo "=========================================="
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "Este script precisa rodar como root (use: sudo bash install.sh)"
    exit 1
fi

gerar_senha() {
    head -c 512 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"
}

# ---------------------------------------------------------
# 1. Instalar o Docker, se ainda nao estiver instalado
# ---------------------------------------------------------
if [ "${SKIP_DOCKER:-0}" = "1" ]; then
    echo "SKIP_DOCKER=1: etapa do Docker ignorada (modo de teste)."
else
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker nao encontrado. Instalando Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
        echo "Docker instalado com sucesso."
    else
        echo "Docker ja esta instalado, pulando essa etapa."
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "ERRO: plugin 'docker compose' nao encontrado mesmo apos a instalacao do Docker."
        echo "Instale manualmente: https://docs.docker.com/compose/install/"
        exit 1
    fi
fi
echo

# ---------------------------------------------------------
# 2. Criar a estrutura de pastas e arquivos
# ---------------------------------------------------------
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
mkdir -p app_alunos/backend app_alunos/frontend nginx

if [ -f docker-compose.yml ]; then
    ATUALIZACAO=1
    PASTA_BKP="backups/sistema_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$PASTA_BKP"
    for f in app_alunos/backend/main.py app_alunos/frontend/index.html; do
        [ -f "$f" ] && cp "$f" "$PASTA_BKP/$(basename "$f")"
    done
    echo "Instalacao existente encontrada em $INSTALL_DIR: ATUALIZANDO o sistema."
    echo "  - copia dos arquivos anteriores em $PASTA_BKP"
    echo "  - docker-compose.yml, nginx.conf, .env, senhas e dados serao preservados"
else
    ATUALIZACAO=0
    echo "Instalacao nova em $INSTALL_DIR ..."
fi
echo

if [ "$ATUALIZACAO" = "0" ]; then
    if [ ! -f .env ]; then
        echo "  - gerando senhas aleatorias (arquivo .env, somente o root le)"
        (
            umask 077
            printf 'DB_PASSWORD=%s\nADMIN_INITIAL_PASSWORD=%s\n' "$(gerar_senha 28)" "$(gerar_senha 12)" > .env
        )
        chmod 600 .env
    fi

    echo "  - gravando docker-compose.yml"
cat > 'docker-compose.yml' << 'EOF_BUSCA_ATIVA'
services:
  nginx_gateway:
    image: nginx:alpine
    container_name: nginx_gateway
    restart: always
    ports:
      - "8085:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./app_alunos/frontend:/usr/share/nginx/html/app_alunos:ro
    depends_on:
      - api_busca_ativa
  postgres_busca_ativa:
    image: postgres:15-alpine
    container_name: postgres_busca_ativa
    restart: always
    environment:
      POSTGRES_DB: busca_ativa_db
      POSTGRES_USER: admin_local
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - pgdata_busca_ativa:/var/lib/postgresql/data
  api_busca_ativa:
    build: ./app_alunos/backend
    container_name: api_busca_ativa
    restart: always
    environment:
      - DB_HOST=postgres_busca_ativa
      - DB_NAME=busca_ativa_db
      - DB_USER=admin_local
      - DB_PASSWORD=${DB_PASSWORD}
      - ADMIN_INITIAL_PASSWORD=${ADMIN_INITIAL_PASSWORD:-admin123}
    depends_on:
      - postgres_busca_ativa
volumes:
  pgdata_busca_ativa:
EOF_BUSCA_ATIVA

    echo "  - gravando nginx/nginx.conf"
cat > 'nginx/nginx.conf' << 'EOF_BUSCA_ATIVA'
events { worker_connections 1024; }
http {
    include mime.types;
    default_type application/octet-stream;
    charset utf-8;
    server {
        listen 80;
        client_max_body_size 10m;

        # Se o sistema estiver ATRAS de outro proxy ou tunel (por exemplo, um proxy HTTPS em outro
        # conteiner), o nginx enxerga todos os acessos com o IP desse proxy. Para que o IP REAL do
        # cliente chegue ao sistema (auditoria e bloqueio de tentativas), descomente as 3 linhas
        # abaixo e troque o IP pelo do proxy (veja com: docker logs nginx_gateway --tail 3):
        # set_real_ip_from 172.19.0.1;
        # real_ip_header X-Forwarded-For;
        # real_ip_recursive on;

        # App 1: Front-end e API de Alunos
        location /alunos/ {
            alias /usr/share/nginx/html/app_alunos/;
            index index.html;
        }
        location /alunos/api/ {
            proxy_pass http://api_busca_ativa:8000/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
        # Central de Aplicações
        location / {
            default_type "text/html; charset=utf-8";
            return 200 '
            <!DOCTYPE html>
            <html lang="pt-BR">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Central de Aplicações</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; text-align: center; padding-top: 60px; background: #0f172a; color: white; margin: 0; }
                    h1 { margin-bottom: 30px; font-weight: 600; }
                    .btn { display: inline-block; padding: 14px 28px; background: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; transition: background 0.2s; }
                    .btn:hover { background: #1d4ed8; }
                </style>
            </head>
            <body>
                <h1>Central de Aplicações Locais</h1>
                <a href="/alunos/" class="btn">Busca Ativa Escolar</a>
            </body>
            </html>';
        }
    }
}
EOF_BUSCA_ATIVA
fi

echo "  - gravando app_alunos/backend/main.py"
cat > 'app_alunos/backend/main.py' << 'EOF_BUSCA_ATIVA'
from fastapi import FastAPI, APIRouter, HTTPException, UploadFile, File, Form, Query, Header, Depends, Request
from fastapi.responses import StreamingResponse, Response
from pydantic import BaseModel
import psycopg2
from psycopg2 import pool
from psycopg2.extras import RealDictCursor, Json
from contextlib import contextmanager
import os
import io
import base64
import hashlib
import hmac
import ipaddress
import secrets
import json
import time
import logging
import pandas as pd
from datetime import datetime, date
from zoneinfo import ZoneInfo

from reportlab.lib.pagesizes import letter, landscape, A4
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle, Spacer, HRFlowable, Image as RLImage
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.utils import ImageReader
from xml.sax.saxutils import escape as _xml_escape

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("busca_ativa")

app = FastAPI(title="Busca Ativa Escolar API", version="2.2.0")
api_router = APIRouter()

DB_HOST = os.getenv("DB_HOST", "postgres_busca_ativa")
DB_NAME = os.getenv("DB_NAME", "busca_ativa_db")
DB_USER = os.getenv("DB_USER", "admin_local")
DB_PASS = os.getenv("DB_PASSWORD")
if not DB_PASS:
    raise RuntimeError("Variável de ambiente DB_PASSWORD não definida (o instalador gera a senha no arquivo .env).")

TOKEN_DURACAO_HORAS = int(os.getenv("TOKEN_DURACAO_HORAS", "24"))
FUSO_RECIFE = ZoneInfo("America/Recife")


def _agora_recife():
    """Hora real de Recife, sem fuso (é assim que o sistema guarda e mostra as datas)."""
    return datetime.now(FUSO_RECIFE).replace(tzinfo=None, microsecond=0)


def _para_naive_recife(valor):
    """Converte um ISO (com ou sem fuso) para a hora de parede de Recife, sem fuso. Retorna None se inválido."""
    if not valor:
        return None
    try:
        dt = datetime.fromisoformat(str(valor).strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone(FUSO_RECIFE).replace(tzinfo=None)
    return dt.replace(microsecond=0)


def agora_sistema(cur):
    """Relógio oficial do sistema: hora real de Recife (modo automático) ou, no modo manual, a data/hora definida
    pelo administrador, que continua contando a partir do momento em que foi salva."""
    real = _agora_recife()
    cur.execute("SELECT modo_hora, data_hora_manual, data_hora_manual_ref FROM configuracoes_sistema WHERE id = 1;")
    cfg = cur.fetchone()
    if cfg and cfg["modo_hora"] == "manual" and cfg["data_hora_manual"]:
        if cfg["data_hora_manual_ref"]:
            return cfg["data_hora_manual"] + (real - cfg["data_hora_manual_ref"])
        return cfg["data_hora_manual"]
    return real

# Configurações de Bloqueio por Tentativas Incorretas (Brute-force protection em 3 camadas)
MAX_TENTATIVAS_IP_USUARIO = int(os.getenv("MAX_TENTATIVAS_IP_USUARIO", os.getenv("MAX_TENTATIVAS_LOGIN", "5")))
MAX_TENTATIVAS_IP = int(os.getenv("MAX_TENTATIVAS_IP", "20"))
MAX_TENTATIVAS_USUARIO = int(os.getenv("MAX_TENTATIVAS_USUARIO", "30"))
TEMPO_BLOQUEIO_SEGUNDOS = int(os.getenv("TEMPO_BLOQUEIO_SEGUNDOS", "900"))  # 15 minutos
JANELA_TENTATIVAS_SEGUNDOS = 900
MAX_REGISTROS_MEMORIA = 2000
TENTATIVAS_FALHAS = {}

OPCOES_PERFIL = ["Usuário Comum", "Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"]
CATEGORIAS_MOTIVO = ["Evasão", "Frequência Irregular", "Vulnerabilidade Social", "Saúde", "Violência/Negligência", "Outro"]
CATEGORIAS_MENSAGEM = ["Ligação", "Visita Domiciliar", "Reunião", "Contato com Conselho Tutelar", "Contato com CRAS/CREAS", "Contato com Unidade de Saúde", "Outro"]
DESTINOS_ENCAMINHAMENTO = ["Conselho Tutelar", "CRAS/CREAS", "Unidade de Saúde", "Ministério Público", "Outro"]
CATEGORIAS_SIGILOSAS = {"Saúde", "Violência/Negligência"}

# ---------------------------------------------------------
# POOL DE CONEXÕES COM O BANCO DE DADOS
# ---------------------------------------------------------
DB_POOL = None


def get_db_pool():
    global DB_POOL
    if DB_POOL is None or DB_POOL.closed:
        DB_POOL = pool.ThreadedConnectionPool(
            minconn=1,
            maxconn=25,
            host=DB_HOST,
            database=DB_NAME,
            user=DB_USER,
            password=DB_PASS,
            options="-c timezone=America/Recife",
            cursor_factory=RealDictCursor
        )
    return DB_POOL


@contextmanager
def get_db_connection():
    p = get_db_pool()
    conn = p.getconn()
    try:
        yield conn
    except Exception:
        try:
            conn.rollback()
        except Exception:
            pass
        raise
    finally:
        try:
            p.putconn(conn)
        except Exception:
            pass


# ---------------------------------------------------------
# GERENCIAMENTO SEGURO DA SECRET_KEY
# ---------------------------------------------------------
_SECRET_KEY_CACHE = None


def obter_secret_key() -> str:
    """
    Retorna a chave secreta para assinatura dos tokens JWT/HMAC.
    Se SECRET_KEY não foi configurada nas variáveis de ambiente,
    gera dinamicamente uma chave aleatória de 128 caracteres exclusiva para esta
    instalação e a persiste no banco de dados. Nunca utiliza segredos fixos públicos.
    """
    global _SECRET_KEY_CACHE
    if _SECRET_KEY_CACHE:
        return _SECRET_KEY_CACHE

    env_secret = os.getenv("SECRET_KEY")
    if env_secret and env_secret.strip() and env_secret.strip() != "busca_ativa_secedi_chave_secreta_2026_@#!g0i4n4":
        _SECRET_KEY_CACHE = env_secret.strip()
        return _SECRET_KEY_CACHE

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS chave_secreta_jwt VARCHAR(255);")
                cur.execute("SELECT chave_secreta_jwt FROM configuracoes_sistema WHERE id = 1;")
                row = cur.fetchone()
                if row and row.get("chave_secreta_jwt"):
                    _SECRET_KEY_CACHE = row["chave_secreta_jwt"]
                    return _SECRET_KEY_CACHE

                nova_chave = secrets.token_hex(64)
                cur.execute("UPDATE configuracoes_sistema SET chave_secreta_jwt = %s WHERE id = 1;", (nova_chave,))
                conn.commit()
                logger.warning("ATENÇÃO DE SEGURANÇA: SECRET_KEY não definida no ambiente. Uma chave aleatória de 128 caracteres foi gerada e armazenada com segurança no banco de dados desta instalação.")
                _SECRET_KEY_CACHE = nova_chave
                return _SECRET_KEY_CACHE
    except Exception as e:
        logger.error(f"Erro ao verificar chave secreta no banco: {e}")
        if not _SECRET_KEY_CACHE:
            _SECRET_KEY_CACHE = secrets.token_hex(64)
        return _SECRET_KEY_CACHE


# ---------------------------------------------------------
# CRIPTOGRAFIA DE SENHAS (PBKDF2-HMAC-SHA256)
# ---------------------------------------------------------
def gerar_hash_senha(senha: str) -> str:
    salt = secrets.token_hex(16)
    hash_bytes = hashlib.pbkdf2_hmac("sha256", senha.encode("utf-8"), salt.encode("utf-8"), 600000)
    return f"pbkdf2:sha256:600000${salt}${hash_bytes.hex()}"


def verificar_senha(senha_fornecida: str, hash_ou_plain: str) -> tuple[bool, bool]:
    """
    Retorna (valido, precisa_upgrade).
    Suporta senhas legadas em texto puro com migração automática transparente para PBKDF2.
    """
    if not hash_ou_plain:
        return False, False
    if hash_ou_plain.startswith("pbkdf2:sha256:"):
        try:
            parts = hash_ou_plain.split("$")
            iteracoes = int(parts[0].split(":")[2])
            salt = parts[1]
            hash_hex = parts[2]
            calc_hash = hashlib.pbkdf2_hmac("sha256", senha_fornecida.encode("utf-8"), salt.encode("utf-8"), iteracoes)
            valido = hmac.compare_digest(calc_hash.hex(), hash_hex)
            return valido, False
        except Exception:
            return False, False
    # Legado: texto puro
    if hmac.compare_digest(senha_fornecida, hash_ou_plain):
        return True, True
    return False, False


# ---------------------------------------------------------
# SESSÃO E TOKENS DE AUTENTICAÇÃO SEGUROS (HMAC-SHA256)
# ---------------------------------------------------------
def gerar_token_sessao(usuario: str, nome: str, perfil: str) -> str:
    chave = obter_secret_key()
    exp = int(time.time()) + (TOKEN_DURACAO_HORAS * 3600)
    payload = {
        "usr": usuario,
        "nome": nome,
        "prf": perfil,
        "exp": exp
    }
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    b64_payload = base64.urlsafe_b64encode(raw).decode("utf-8").rstrip("=")
    assinatura = hmac.new(chave.encode("utf-8"), b64_payload.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"{b64_payload}.{assinatura}"


def decodificar_token(token: str) -> dict:
    if not token or "." not in token:
        raise HTTPException(status_code=401, detail="Token de autenticação inválido ou ausente.")
    chave = obter_secret_key()
    b64_payload, assinatura = token.split(".", 1)
    esperada = hmac.new(chave.encode("utf-8"), b64_payload.encode("utf-8"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(assinatura, esperada):
        raise HTTPException(status_code=401, detail="Assinatura de autenticação inválida.")
    try:
        pad = "=" * (-len(b64_payload) % 4)
        data = json.loads(base64.urlsafe_b64decode(b64_payload + pad).decode("utf-8"))
        if time.time() > data.get("exp", 0):
            raise HTTPException(status_code=401, detail="Sua sessão expirou. Faça login novamente.")
        return data
    except Exception:
        raise HTTPException(status_code=401, detail="Falha ao decodificar sessão.")


def obter_usuario_atual(
    authorization: str | None = Header(None),
    token: str | None = Query(None)
) -> dict:
    token_val = None
    if authorization:
        if authorization.startswith("Bearer "):
            token_val = authorization[7:].strip()
        else:
            token_val = authorization.strip()
    elif token:
        token_val = token.strip()

    if not token_val:
        raise HTTPException(status_code=401, detail="Autenticação obrigatória.")
    dados = decodificar_token(token_val)
    return {
        "usuario": dados["usr"],
        "nome": dados["nome"],
        "perfil": dados["prf"]
    }


def exigir_perfil(*perfis_permitidos):
    def _validador(usuario: dict = Depends(obter_usuario_atual)):
        if usuario["perfil"] not in perfis_permitidos:
            raise HTTPException(status_code=403, detail="Acesso não autorizado para o seu perfil de usuário.")
        return usuario
    return _validador


# ---------------------------------------------------------
# PROTEÇÃO CONTRA FORÇA BRUTA (RATE LIMITING EM 3 CAMADAS)
# ---------------------------------------------------------
def extrair_ip_cliente(request: Request) -> str:
    """
    Obtém o IP real do cliente.
    Prioriza o cabeçalho 'X-Real-IP' configurado no proxy reverso (Nginx: proxy_set_header X-Real-IP $remote_addr;),
    que sobrescreve qualquer cabeçalho forjado pelo cliente HTTP.
    Ignora valores arbitrários de 'X-Forwarded-For' para evitar contorno do bloqueio por spoofing.
    Caso não haja proxy reverso ou o cabeçalho esteja ausente, utiliza a conexão TCP direta (request.client.host).
    """
    real_ip = (request.headers.get("X-Real-IP") or "").strip()
    if real_ip:
        try:
            return str(ipaddress.ip_address(real_ip))
        except ValueError:
            pass  # cabeçalho inválido: ignora e usa a conexão direta
    if request.client and request.client.host:
        return request.client.host
    return "desconhecido"


def classificar_origem_ip(ip: str) -> str:
    """Diz se o acesso veio da rede local (IP privado) ou de fora (internet / dados móveis)."""
    try:
        endereco = ipaddress.ip_address(ip)
    except ValueError:
        return "origem desconhecida"
    endereco = getattr(endereco, "ipv4_mapped", None) or endereco
    if endereco.is_loopback:
        return "o próprio servidor"
    if endereco.version == 4 and endereco in ipaddress.ip_network("172.16.0.0/12"):
        return "rede interna do Docker ou de um proxy — o IP real do cliente não chegou ao sistema"
    if endereco.is_private or endereco.is_link_local:
        return "rede local"
    return "acesso externo (internet)"


def ips_informados_pelo_proxy(request: Request, ip_conexao: str):
    """IPs de cliente declarados por proxies/túneis (Cloudflare, Tailscale, outro nginx...).
    São só INFORMATIVOS para a auditoria: quem controla o cabeçalho pode forjá-los, então nunca
    entram no bloqueio de tentativas."""
    achados = []
    for nome in ("CF-Connecting-IP", "True-Client-IP", "X-Forwarded-For"):
        valor = request.headers.get(nome)
        if not valor:
            continue
        for parte in valor.split(","):
            try:
                candidato = str(ipaddress.ip_address(parte.strip()))
            except ValueError:
                continue
            if candidato != ip_conexao and candidato not in achados:
                achados.append(candidato)
            break  # só o primeiro endereço válido de cada cabeçalho (o cliente original)
    return achados[:2]


def descrever_dispositivo(user_agent) -> str:
    """Resumo legível do aparelho e do navegador (sem guardar o texto bruto do navegador)."""
    ua = str(user_agent or "").lower()
    if not ua:
        return "dispositivo desconhecido"
    if "ipad" in ua or "tablet" in ua or ("android" in ua and "mobile" not in ua):
        tipo = "Tablet"
    elif "iphone" in ua or "ipod" in ua or "mobile" in ua or "android" in ua:
        tipo = "Celular"
    else:
        tipo = "Computador"
    if "android" in ua:
        so = "Android"
    elif "iphone" in ua or "ipad" in ua or "ipod" in ua:
        so = "iOS"
    elif "windows" in ua:
        so = "Windows"
    elif "cros" in ua:
        so = "ChromeOS"
    elif "macintosh" in ua or "mac os x" in ua:
        so = "macOS"
    elif "linux" in ua or "x11" in ua:
        so = "Linux"
    else:
        so = "sistema desconhecido"
    if "edg/" in ua or "edga/" in ua or "edgios/" in ua:
        nav = "Edge"
    elif "opr/" in ua or "opera" in ua:
        nav = "Opera"
    elif "samsungbrowser" in ua:
        nav = "Samsung Internet"
    elif "firefox" in ua or "fxios" in ua:
        nav = "Firefox"
    elif "chrome" in ua or "crios" in ua:
        nav = "Chrome"
    elif "safari" in ua:
        nav = "Safari"
    else:
        nav = "navegador desconhecido"
    return f"{tipo} {so} · {nav}"


def descrever_origem(request: Request, ip: str) -> str:
    texto = f"IP {ip} ({classificar_origem_ip(ip)}) · {descrever_dispositivo(request.headers.get('User-Agent'))}"
    informados = ips_informados_pelo_proxy(request, ip)
    if informados:
        texto += " · IP informado pelo proxy: " + ", ".join(f"{i} ({classificar_origem_ip(i)})" for i in informados)
    return texto


def limpar_registros_expirados():
    """Remove entradas expiradas da memória para evitar vazamento ou sobrecarga."""
    agora = time.time()
    chaves_expiradas = [
        k for k, v in TENTATIVAS_FALHAS.items()
        if agora > v.get("bloqueado_ate", 0) and (agora - v.get("primeiro_erro", 0) > JANELA_TENTATIVAS_SEGUNDOS)
    ]
    for k in chaves_expiradas:
        TENTATIVAS_FALHAS.pop(k, None)

    # Se a lista ultrapassar o limite de segurança, descarta primeiro os registros com MENOS erros
    # (e mais antigos). Bloqueios ativos nunca são descartados, e contadores altos (ex.: o teto de uma
    # conta sob ataque) são os últimos a sair — assim uma inundação de usuários/IPs inventados não
    # consegue apagar o histórico de quem está sendo atacado.
    if len(TENTATIVAS_FALHAS) > MAX_REGISTROS_MEMORIA:
        excesso = len(TENTATIVAS_FALHAS) - MAX_REGISTROS_MEMORIA
        candidatos = sorted(
            ((k, v) for k, v in TENTATIVAS_FALHAS.items() if v.get("bloqueado_ate", 0) <= agora),
            key=lambda item: (item[1].get("tentativas", 0), item[1].get("primeiro_erro", 0))
        )
        for k, _ in candidatos[:excesso]:
            TENTATIVAS_FALHAS.pop(k, None)


def verificar_limite_tentativas(identificador: str, mensagem_detalhe: str = None):
    agora = time.time()
    registro = TENTATIVAS_FALHAS.get(identificador)
    if not registro:
        return

    if registro.get("bloqueado_ate", 0) > agora:
        segundos_restantes = int(registro["bloqueado_ate"] - agora)
        minutos = max(1, (segundos_restantes + 59) // 60)
        detalhe = mensagem_detalhe or f"Muitas tentativas incorretas a partir deste endereço. Acesso bloqueado temporariamente por {minutos} minuto(s)."
        if "{minutos}" in detalhe:
            detalhe = detalhe.replace("{minutos}", str(minutos))
        raise HTTPException(
            status_code=429,
            detail=detalhe
        )

    if agora - registro.get("primeiro_erro", 0) > JANELA_TENTATIVAS_SEGUNDOS:
        TENTATIVAS_FALHAS.pop(identificador, None)


def registrar_falha_login(identificador: str, max_tentativas: int, usuario_nome: str, ip: str, motivo_log: str = ""):
    limpar_registros_expirados()
    agora = time.time()
    registro = TENTATIVAS_FALHAS.get(identificador)
    if not registro or (agora - registro.get("primeiro_erro", 0) > JANELA_TENTATIVAS_SEGUNDOS):
        registro = {
            "tentativas": 1,
            "primeiro_erro": agora,
            "bloqueado_ate": 0
        }
        TENTATIVAS_FALHAS[identificador] = registro
    else:
        registro["tentativas"] += 1

    if registro["tentativas"] >= max_tentativas and registro.get("bloqueado_ate", 0) <= agora:
        registro["bloqueado_ate"] = agora + TEMPO_BLOQUEIO_SEGUNDOS
        desc_log = motivo_log or f"Bloqueio temporário (15 min) para '{identificador}' após {registro['tentativas']} tentativas incorretas (usuário: {usuario_nome}, IP: {ip})."
        registrar_log(
            usuario_nome,
            "Bloqueio de Segurança",
            desc_log
        )


def limpar_falhas_login(identificador: str):
    TENTATIVAS_FALHAS.pop(identificador, None)


# ---------------------------------------------------------
# REGRAS DE PERMISSÃO DE NEGÓCIO
# ---------------------------------------------------------
def pode_ver_sigiloso(perfil: str) -> bool:
    return perfil in ("Coordenador de Acompanhamento", "Administrador")


def pode_reabrir(perfil: str, sigiloso: bool) -> bool:
    if perfil == "Administrador":
        return True
    if sigiloso and perfil == "Coordenador de Acompanhamento":
        return True
    return False


def pode_editar_mensagem(perfil: str, sigiloso: bool) -> bool:
    if perfil == "Administrador":
        return True
    if sigiloso and perfil == "Coordenador de Acompanhamento":
        return True
    return False


# ---------------------------------------------------------
# INICIALIZAÇÃO DO BANCO DE DADOS
# ---------------------------------------------------------
def init_db():
    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                # Tabela de alunos
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS alunos (
                        id SERIAL PRIMARY KEY,
                        nome VARCHAR(255) NOT NULL,
                        cpf VARCHAR(20) NOT NULL,
                        data_nasc DATE NOT NULL,
                        tipo_busca VARCHAR(100) NOT NULL,
                        escola_origem VARCHAR(255) NOT NULL,
                        turma VARCHAR(100) NOT NULL,
                        endereco TEXT NOT NULL,
                        observacoes TEXT,
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    );
                """)
                cur.execute("ALTER TABLE alunos ADD COLUMN IF NOT EXISTS foto TEXT;")

                # Tabela de usuários
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS usuarios (
                        id SERIAL PRIMARY KEY,
                        usuario VARCHAR(100) UNIQUE NOT NULL,
                        senha VARCHAR(255) NOT NULL,
                        nome VARCHAR(255) NOT NULL,
                        perfil VARCHAR(50) NOT NULL
                    );
                """)

                # Tabela de logs de auditoria
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS logs_auditoria (
                        id SERIAL PRIMARY KEY,
                        usuario VARCHAR(255),
                        acao VARCHAR(255),
                        detalhes TEXT,
                        data_hora TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    );
                """)

                # Tabela de configurações do sistema
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS configuracoes_sistema (
                        id INTEGER PRIMARY KEY DEFAULT 1,
                        titulo_login VARCHAR(255),
                        subtitulo_login VARCHAR(255),
                        titulo_interno VARCHAR(255),
                        logo_base64 TEXT
                    );
                """)
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS chave_secreta_jwt VARCHAR(255);")

                # Tabela de escolas da rede
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS escolas (
                        id SERIAL PRIMARY KEY,
                        nome VARCHAR(255) UNIQUE NOT NULL
                    );
                """)
                cur.execute("ALTER TABLE escolas ADD COLUMN IF NOT EXISTS ordem INTEGER;")

                cur.execute("SELECT COUNT(*) as total FROM escolas;")
                if cur.fetchone()["total"] == 0:
                    escolas_iniciais = [
                        "Adélia Carneiro Pedrosa", "Arcendrino César de Albuquerque", "Capela de São Sebastião",
                        "Centro de Atendimento de Educação Especial Professora Margarida Braga",
                        "CMEI - Carlos Alberto dos Santos Viegas", "CMEI - Prefeito Osvaldo Rabelo Filho",
                        "CMEI - Vereador Jose Batista dos Santos", "Cônego Fernando Passos",
                        "Creche Criança Feliz", "Creche Municipal Profª Etenile Urbano Pessoa", "Diogo Dias",
                        "Dr. Araújo Filho", "Dr. Benigno Araújo", "Dr. Clóvis Fontenelle Guimarães",
                        "Dr. Ludovico Correia", "Dr. Manoel Borba", "Edith Gadelha",
                        "Edjanete Maria Valença da Silveira", "Eufrásio Vilarim", "Francisco Nicolau da Silva",
                        "Heroínas de Tejucupapo", "Iracema Nogueira Rabelo", "Irmã Marie Armelle Falguières",
                        "IV Centenário", "João Carneiro de Melo", "João Gonçalves de Azevedo",
                        "José Maciel da Silva", "Lourenço de Albuquerque Gadelha (DISTRITO)",
                        "Lourenço de Albuquerque Gadelha (SEDE)", "Major Manoel Gadelha",
                        "Manuel César de Albuquerque", "Nossa Senhora das Maravilhas",
                        "Prefeito Ângelo Jordão", "Presidente Costa e Silva",
                        "Profª. Belisana Pinto Abreu de Araújo", "Profª. Cynira Florianna dos Prazeres",
                        "Profª. Lizete Maria de Souza Rodrigues", "Profª. Mª Emília Valença da Silveira",
                        "Profª. Tarcila Coutinho Amaral", "Profª. Zilma Gemir Baracho", "Santa Maria",
                        "Santo Antônio de Pádua", "São Thomaz de Aquino"
                    ]
                    for indice, nome in enumerate(escolas_iniciais):
                        cur.execute(
                            "INSERT INTO escolas (nome, ordem) VALUES (%s, %s) ON CONFLICT (nome) DO NOTHING;",
                            (nome, indice)
                        )

                cur.execute("""
                    UPDATE escolas SET ordem = sub.rn
                    FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY nome) AS rn FROM escolas) AS sub
                    WHERE escolas.id = sub.id AND escolas.ordem IS NULL;
                """)

                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS modo_ordenacao_escolas VARCHAR(20) DEFAULT 'alfabetica';")

                # Cria usuário admin padrão com senha hasheada se ainda não houver nenhum usuário
                cur.execute("SELECT COUNT(*) as total FROM usuarios;")
                if cur.fetchone()["total"] == 0:
                    # O instalador gera uma senha aleatória (ADMIN_INITIAL_PASSWORD); sem ela, mantém o padrão antigo
                    senha_hash = gerar_hash_senha(os.getenv("ADMIN_INITIAL_PASSWORD") or "admin123")
                    cur.execute(
                        "INSERT INTO usuarios (usuario, senha, nome, perfil) VALUES (%s, %s, %s, %s);",
                        ("admin", senha_hash, "Administrador", "Administrador")
                    )

                # Colunas visuais e de personalização
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS cor_cabecalho VARCHAR(20) DEFAULT '#1e293b';")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS cor_menu VARCHAR(20) DEFAULT '#0f172a';")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS cor_texto_cabecalho VARCHAR(20) DEFAULT '#ffffff';")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS cor_destaque VARCHAR(20) DEFAULT '#2563eb';")
                for coluna, tipo in [
                    ("chat_bg_color", "VARCHAR(20) DEFAULT '#e5ddd5'"), ("chat_bubble_sent", "VARCHAR(20) DEFAULT '#dcf8c6'"),
                    ("chat_bubble_received", "VARCHAR(20) DEFAULT '#ffffff'"), ("chat_header_color", "VARCHAR(20) DEFAULT '#075e54'"),
                    ("chat_bg_image", "TEXT"),
                    ("rel_finalidade", "TEXT"), ("rel_fund_ldb", "TEXT"), ("rel_fund_eca", "TEXT"), ("rel_fund_aplicacao", "TEXT"),
                    ("rel_prox_aberto", "TEXT"), ("rel_prox_fechado", "TEXT"), ("rel_prox_arquivado", "TEXT"),
                    ("rel_orgao_resp", "TEXT"), ("rel_unidade_resp", "TEXT"),
                ]:
                    cur.execute(f"ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS {coluna} {tipo};")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS cabecalho_pdf_texto TEXT;")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS rodape_pdf_texto TEXT;")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS logo_pdf_base64 TEXT;")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS tamanho_logo_pdf INTEGER DEFAULT 60;")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS modo_hora VARCHAR(20) DEFAULT 'automatico';")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS data_hora_manual TIMESTAMP;")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS data_hora_manual_ref TIMESTAMP;")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS imagem_fundo_login TEXT;")
                cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS rodape_texto TEXT;")

                # Cria configuração padrão se não existir
                cur.execute("SELECT COUNT(*) as total FROM configuracoes_sistema;")
                if cur.fetchone()["total"] == 0:
                    cur.execute("""
                        INSERT INTO configuracoes_sistema (id, titulo_login, subtitulo_login, titulo_interno, logo_base64)
                        VALUES (1, 'Sistema de Gestão Escolar', 'Acesse com suas credenciais para continuar', 'Busca Ativa Escolar & Gestão', NULL);
                    """)

                rodape_padrao = (
                    "© 2026 Secretaria de Educação e Inovação Pedagógica de Goiana - PE\n"
                    "Desenvolvimento: Coordenação de Tecnologia\n"
                    "Todos os direitos reservados."
                )
                cur.execute(
                    "UPDATE configuracoes_sistema SET rodape_texto = %s WHERE id = 1 AND rodape_texto IS NULL;",
                    (rodape_padrao,)
                )

                # Acompanhamentos e Mensagens
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS acompanhamentos (
                        id SERIAL PRIMARY KEY,
                        aluno_id INTEGER NOT NULL REFERENCES alunos(id) ON DELETE CASCADE,
                        motivo VARCHAR(255) NOT NULL,
                        categoria_motivo VARCHAR(50) NOT NULL,
                        urgencia VARCHAR(20) NOT NULL DEFAULT 'media',
                        status VARCHAR(20) NOT NULL DEFAULT 'aberto',
                        sigiloso BOOLEAN NOT NULL DEFAULT FALSE,
                        data_prevista_retorno DATE,
                        criado_por VARCHAR(255),
                        criado_em TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                        fechado_por VARCHAR(255),
                        fechado_em TIMESTAMP,
                        reaberto_por VARCHAR(255),
                        reaberto_em TIMESTAMP
                    );
                """)

                cur.execute("""
                    CREATE TABLE IF NOT EXISTS acompanhamento_mensagens (
                        id SERIAL PRIMARY KEY,
                        acompanhamento_id INTEGER NOT NULL REFERENCES acompanhamentos(id) ON DELETE CASCADE,
                        usuario_responsavel VARCHAR(255),
                        categoria VARCHAR(50),
                        texto TEXT NOT NULL,
                        encaminhamento_oficial BOOLEAN DEFAULT FALSE,
                        encaminhado_para VARCHAR(100),
                        data_hora TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                        editado_por VARCHAR(255),
                        editado_em TIMESTAMP
                    );
                """)

                cur.execute("""
                    CREATE TABLE IF NOT EXISTS anexos_mensagem (
                        id SERIAL PRIMARY KEY,
                        mensagem_id INTEGER NOT NULL REFERENCES acompanhamento_mensagens(id) ON DELETE CASCADE,
                        nome_arquivo VARCHAR(255),
                        tipo_mime VARCHAR(100),
                        conteudo BYTEA,
                        criado_em TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    );
                """)

                cur.execute("ALTER TABLE acompanhamentos ADD COLUMN IF NOT EXISTS arquivado BOOLEAN NOT NULL DEFAULT FALSE;")

                cur.execute("""
                    CREATE TABLE IF NOT EXISTS anos_letivos (
                        id SERIAL PRIMARY KEY,
                        ano INTEGER UNIQUE NOT NULL,
                        fechado_em TIMESTAMP,
                        fechado_por VARCHAR(255),
                        casos_snapshot JSONB
                    );
                """)

            conn.commit()
            logger.info("Banco de dados verificado e inicializado com sucesso.")
    except Exception as e:
        logger.error(f"Erro ao inicializar o banco de dados: {e}")


@app.on_event("startup")
def startup_event():
    init_db()
    obter_secret_key()


def registrar_log(usuario: str, acao: str, detalhes: str = ""):
    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO logs_auditoria (usuario, acao, detalhes) VALUES (%s, %s, %s);",
                    (usuario, acao, detalhes)
                )
            conn.commit()
    except Exception as e:
        logger.error(f"Erro ao registrar log de auditoria: {e}")


# ---------------------------------------------------------
# SCHEMAS PYDANTIC
# ---------------------------------------------------------
class AlunoSchema(BaseModel):
    nome: str
    cpf: str
    data_nasc: str
    tipo_busca: str
    escola_origem: str
    turma: str
    endereco: str
    observacoes: str = ""


class LoginSchema(BaseModel):
    usuario: str
    senha: str


class UsuarioSchema(BaseModel):
    usuario: str
    senha: str
    nome: str
    perfil: str


class PerfilUpdateSchema(BaseModel):
    perfil: str


class ResetSenhaSchema(BaseModel):
    nova_senha: str


class ConfigSchema(BaseModel):
    titulo_login: str
    subtitulo_login: str
    titulo_interno: str
    logo_base64: str | None = None
    cor_cabecalho: str = "#1e293b"
    cor_menu: str = "#0f172a"
    cor_texto_cabecalho: str = "#ffffff"
    cor_destaque: str = "#2563eb"
    chat_bg_color: str = "#e5ddd5"
    chat_bubble_sent: str = "#dcf8c6"
    chat_bubble_received: str = "#ffffff"
    chat_header_color: str = "#075e54"
    chat_bg_image_base64: str | None = None
    chat_bg_image_remover: bool = False
    rel_finalidade: str = ""
    rel_fund_ldb: str = ""
    rel_fund_eca: str = ""
    rel_fund_aplicacao: str = ""
    rel_prox_aberto: str = ""
    rel_prox_fechado: str = ""
    rel_prox_arquivado: str = ""
    rel_orgao_resp: str = ""
    rel_unidade_resp: str = ""
    cabecalho_pdf_texto: str = ""
    rodape_pdf_texto: str = ""
    logo_pdf_base64: str | None = None
    tamanho_logo_pdf: int = 60
    modo_hora: str = "automatico"
    data_hora_manual: str | None = None
    imagem_fundo_login: str | None = None
    rodape_texto: str = ""
    modo_ordenacao_escolas: str = "alfabetica"


class ExcluirTodosSchema(BaseModel):
    confirmacao: str


class EscolaSchema(BaseModel):
    nome: str


class OrdemEscolasSchema(BaseModel):
    ordem: list[int]


class ModoOrdenacaoSchema(BaseModel):
    modo: str


class FotoAlunoSchema(BaseModel):
    foto: str


class AbrirAcompanhamentoSchema(BaseModel):
    aluno_id: int
    motivo: str
    categoria_motivo: str
    urgencia: str = "media"
    data_prevista_retorno: str | None = None
    criado_em: str | None = None


class FecharAnoLetivoSchema(BaseModel):
    ano: int
    fechado_em: str | None = None


class MensagemUpdateSchema(BaseModel):
    texto: str
    categoria: str


# ---------------------------------------------------------
# AUTENTICAÇÃO COM RATE LIMITING EM 3 CAMADAS (IP+USUÁRIO, IP, USUÁRIO)
# ---------------------------------------------------------
MSG_BLOQUEIO_IP_USUARIO = "Muitas tentativas incorretas para este usuário a partir deste endereço. Acesso bloqueado temporariamente por {minutos} minuto(s)."
MSG_BLOQUEIO_IP = "Muitas tentativas incorretas a partir deste endereço IP. Acesso temporariamente bloqueado por {minutos} minuto(s)."
MSG_BLOQUEIO_USUARIO = "Esta conta atingiu o limite de segurança de tentativas incorretas. Acesso bloqueado temporariamente por {minutos} minuto(s)."


@api_router.post("/login")
def login(dados: LoginSchema, request: Request):
    ip = extrair_ip_cliente(request)
    usuario_chave = dados.usuario.strip().lower()

    # Chaves de bloqueio em 3 níveis complementares:
    # 1. ip_user: Bloqueia ataques locais pontuais (5 erros) sem travar outros usuários no mesmo IP nem o admin em outro IP
    # 2. ip: Bloqueia ataque de dicionário/varredura partindo da mesma máquina/rede (20 erros, permitindo folga para NATs/escolas)
    # 3. user: Teto global por conta (30 erros) para frear quem tenta contornar trocando de IP ou ataques distribuídos
    identificador_ip_usuario = f"ip_user:{ip}:{usuario_chave}"
    identificador_ip = f"ip:{ip}"
    identificador_usuario = f"user:{usuario_chave}"

    verificar_limite_tentativas(identificador_ip_usuario, MSG_BLOQUEIO_IP_USUARIO)
    verificar_limite_tentativas(identificador_ip, MSG_BLOQUEIO_IP)
    verificar_limite_tentativas(identificador_usuario, MSG_BLOQUEIO_USUARIO)

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, usuario, senha, nome, perfil FROM usuarios WHERE LOWER(usuario) = %s;",
                (usuario_chave,)
            )
            usuario = cur.fetchone()
            if not usuario:
                registrar_log(dados.usuario.strip()[:60] or "(vazio)", "Falha de Login", f"Usuário inexistente — {descrever_origem(request, ip)}")
                registrar_falha_login(identificador_ip_usuario, MAX_TENTATIVAS_IP_USUARIO, dados.usuario, ip)
                registrar_falha_login(identificador_ip, MAX_TENTATIVAS_IP, dados.usuario, ip)
                registrar_falha_login(identificador_usuario, MAX_TENTATIVAS_USUARIO, dados.usuario, ip)
                verificar_limite_tentativas(identificador_ip_usuario, MSG_BLOQUEIO_IP_USUARIO)
                verificar_limite_tentativas(identificador_ip, MSG_BLOQUEIO_IP)
                verificar_limite_tentativas(identificador_usuario, MSG_BLOQUEIO_USUARIO)
                raise HTTPException(status_code=401, detail="Usuário ou senha incorretos.")

            valido, precisa_upgrade = verificar_senha(dados.senha, usuario["senha"])
            if not valido:
                registrar_log(usuario["usuario"], "Falha de Login", f"Senha incorreta — {descrever_origem(request, ip)}")
                registrar_falha_login(identificador_ip_usuario, MAX_TENTATIVAS_IP_USUARIO, usuario["usuario"], ip)
                registrar_falha_login(identificador_ip, MAX_TENTATIVAS_IP, usuario["usuario"], ip)
                registrar_falha_login(identificador_usuario, MAX_TENTATIVAS_USUARIO, usuario["usuario"], ip)
                verificar_limite_tentativas(identificador_ip_usuario, MSG_BLOQUEIO_IP_USUARIO)
                verificar_limite_tentativas(identificador_ip, MSG_BLOQUEIO_IP)
                verificar_limite_tentativas(identificador_usuario, MSG_BLOQUEIO_USUARIO)
                raise HTTPException(status_code=401, detail="Usuário ou senha incorretos.")

            if precisa_upgrade:
                novo_hash = gerar_hash_senha(dados.senha)
                cur.execute("UPDATE usuarios SET senha = %s WHERE id = %s;", (novo_hash, usuario["id"]))
                conn.commit()

    # Sucesso na autenticação:
    # Zera histórico de falhas do usuário neste IP e o teto global da conta
    limpar_falhas_login(identificador_ip_usuario)
    limpar_falhas_login(identificador_usuario)

    token = gerar_token_sessao(usuario["usuario"], usuario["nome"], usuario["perfil"])
    registrar_log(usuario["usuario"], "Login Realizado", descrever_origem(request, ip))
    return {
        "token": token,
        "usuario": usuario["usuario"],
        "nome": usuario["nome"],
        "perfil": usuario["perfil"]
    }


# ---------------------------------------------------------
# ALUNOS
# ---------------------------------------------------------
@api_router.get("/alunos")
def listar_alunos(
    skip: int = Query(0, ge=0),
    limit: int = Query(300, ge=1, le=1000),
    usuario: dict = Depends(obter_usuario_atual)
):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id, nome, cpf, data_nasc, tipo_busca, escola_origem, turma, endereco, observacoes,
                       created_at, (foto IS NOT NULL) AS tem_foto
                FROM alunos ORDER BY id DESC LIMIT %s OFFSET %s;
            """, (limit, skip))
            return cur.fetchall()


@api_router.post("/alunos")
def cadastrar_aluno(
    aluno: AlunoSchema,
    usuario: dict = Depends(obter_usuario_atual)
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO alunos (nome, cpf, data_nasc, tipo_busca, escola_origem, turma, endereco, observacoes)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING id;
            """, (aluno.nome, aluno.cpf, aluno.data_nasc, aluno.tipo_busca, aluno.escola_origem,
                  aluno.turma, aluno.endereco, aluno.observacoes))
            novo_id = cur.fetchone()["id"]
        conn.commit()

    detalhes = f"Aluno: {aluno.nome} | CPF: {aluno.cpf} | Escola: {aluno.escola_origem}"
    registrar_log(usuario_resp, "Cadastro Individual", detalhes)
    return {"status": "sucesso", "id": novo_id}


@api_router.get("/alunos/modelo")
def baixar_modelo_alunos(usuario: dict = Depends(obter_usuario_atual)):
    df_modelo = pd.DataFrame({
        "nome": ["Exemplo Nome Aluno"],
        "cpf": ["000.000.000-00"],
        "data_nasc": ["2015-01-01"],
        "tipo_busca": ["Busca Ativa"],
        "escola_origem": ["Adélia Carneiro Pedrosa"],
        "turma": ["1º Ano A"],
        "endereco": ["Rua Exemplo, Nº 100, Bairro Centenário"],
        "observacoes": ["Sem observações"]
    })
    buffer = io.BytesIO()
    with pd.ExcelWriter(buffer, engine="openpyxl") as writer:
        df_modelo.to_excel(writer, index=False, sheet_name="Modelo_Importacao")
    buffer.seek(0)
    return StreamingResponse(
        buffer,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": "attachment; filename=modelo_importacao_alunos.xlsx"}
    )


@api_router.get("/alunos/export")
def exportar_alunos(usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM alunos ORDER BY id DESC;")
            dados = cur.fetchall()

    df = pd.DataFrame(dados)
    if "foto" in df.columns:
        df = df.drop(columns=["foto"])
    buffer = io.BytesIO()
    with pd.ExcelWriter(buffer, engine="openpyxl") as writer:
        df.to_excel(writer, index=False, sheet_name="Base_Alunos")
    buffer.seek(0)
    nome_arquivo = f"base_alunos_{datetime.now(FUSO_RECIFE).strftime('%Y%m%d_%H%M%S')}.xlsx"
    return StreamingResponse(
        buffer,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename={nome_arquivo}"}
    )


@api_router.get("/alunos/busca")
def buscar_alunos(
    q: str = Query(""),
    usuario: dict = Depends(obter_usuario_atual)
):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            termo = f"%{q}%"
            cur.execute("""
                SELECT a.id, a.nome, a.cpf, a.escola_origem, a.turma, (a.foto IS NOT NULL) AS tem_foto,
                       EXISTS(SELECT 1 FROM acompanhamentos ac WHERE ac.aluno_id = a.id AND ac.status = 'aberto' AND ac.arquivado = FALSE) AS tem_caso_aberto
                FROM alunos a
                WHERE a.nome ILIKE %s OR a.cpf ILIKE %s
                ORDER BY a.nome
                LIMIT 30;
            """, (termo, termo))
            return cur.fetchall()


@api_router.get("/alunos/{aluno_id}/perfil")
def obter_perfil_aluno(
    aluno_id: int,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    perfil = usuario["perfil"]
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id, nome, cpf, data_nasc, escola_origem, turma, endereco, tipo_busca,
                       (foto IS NOT NULL) AS tem_foto
                FROM alunos WHERE id = %s;
            """, (aluno_id,))
            aluno = cur.fetchone()
            if not aluno:
                raise HTTPException(status_code=404, detail="Aluno não encontrado.")

            if pode_ver_sigiloso(perfil):
                cur.execute("SELECT * FROM acompanhamentos WHERE aluno_id = %s ORDER BY criado_em DESC;", (aluno_id,))
            else:
                cur.execute(
                    "SELECT * FROM acompanhamentos WHERE aluno_id = %s AND sigiloso = FALSE ORDER BY criado_em DESC;",
                    (aluno_id,)
                )
            casos = cur.fetchall()

    aluno["casos"] = casos
    return aluno


@api_router.post("/alunos/{aluno_id}/foto")
def salvar_foto_aluno(
    aluno_id: int,
    dados: FotoAlunoSchema,
    usuario: dict = Depends(obter_usuario_atual)
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("UPDATE alunos SET foto = %s WHERE id = %s;", (dados.foto, aluno_id))
        conn.commit()

    registrar_log(usuario_resp, "Atualização de Foto do Aluno", f"Aluno ID {aluno_id}")
    return {"status": "sucesso"}


# BLOQUEIO DE SEGURANÇA: Foto de menor requer login obrigatório
@api_router.get("/alunos/{aluno_id}/foto")
def obter_foto_aluno(
    aluno_id: int,
    usuario: dict = Depends(obter_usuario_atual)
):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT foto FROM alunos WHERE id = %s;", (aluno_id,))
            row = cur.fetchone()

    mime, raw = _decodificar_data_uri(row["foto"] if row else None)
    if not raw:
        raise HTTPException(status_code=404, detail="Foto não configurada.")
    return Response(content=raw, media_type=mime, headers={"Cache-Control": "private, no-cache, no-store, must-revalidate"})


@api_router.delete("/alunos/{aluno_id}/foto")
def excluir_foto_aluno(
    aluno_id: int,
    usuario: dict = Depends(obter_usuario_atual)
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("UPDATE alunos SET foto = NULL WHERE id = %s;", (aluno_id,))
        conn.commit()

    registrar_log(usuario_resp, "Exclusão de Foto do Aluno", f"Aluno ID {aluno_id}")
    return {"status": "sucesso"}


@api_router.post("/alunos/lote")
async def importar_alunos_lote(
    arquivo: UploadFile = File(...),
    usuario: dict = Depends(obter_usuario_atual)
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    conteudo = await arquivo.read()
    buffer = io.BytesIO(conteudo)

    if arquivo.filename.endswith(".csv"):
        df = pd.read_csv(buffer)
    else:
        df = pd.read_excel(buffer)

    colunas_esperadas = ["nome", "cpf", "data_nasc", "tipo_busca", "escola_origem", "turma", "endereco", "observacoes"]
    df.columns = [c.strip().lower().replace(" ", "_") for c in df.columns]
    for col in colunas_esperadas:
        if col not in df.columns:
            df[col] = ""

    df["data_nasc"] = pd.to_datetime(df["data_nasc"], errors="coerce").dt.strftime("%Y-%m-%d")

    total = 0
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            for _, row in df.iterrows():
                if not row["nome"] or pd.isna(row["nome"]):
                    continue
                cur.execute("""
                    INSERT INTO alunos (nome, cpf, data_nasc, tipo_busca, escola_origem, turma, endereco, observacoes)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
                """, (row["nome"], str(row.get("cpf", "")), row.get("data_nasc", "2015-01-01"),
                      row.get("tipo_busca", "Busca Ativa"), row.get("escola_origem", ""),
                      row.get("turma", ""), row.get("endereco", ""), str(row.get("observacoes", "") or "")))
                total += 1
        conn.commit()

    registrar_log(usuario_resp, "Importação em Lote", f"Importados {total} alunos via planilha.")
    return {"status": "sucesso", "total_importado": total}


@api_router.post("/alunos/excluir-tudo")
def excluir_todos_alunos(
    dados: ExcluirTodosSchema,
    usuario: dict = Depends(exigir_perfil("Administrador"))
):
    if dados.confirmacao.strip() != "DELETAR":
        raise HTTPException(status_code=400, detail="Texto de confirmação incorreto. Digite exatamente 'DELETAR'.")

    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) as total FROM alunos;")
            qtd = cur.fetchone()["total"]
            cur.execute("DELETE FROM alunos;")
        conn.commit()

    registrar_log(usuario_resp, "Exclusão da Base de Alunos", f"A base contendo {qtd} aluno(s) foi zerada.")
    return {"status": "sucesso", "excluidos": qtd}


# ---------------------------------------------------------
# DASHBOARD
# ---------------------------------------------------------
@api_router.get("/dashboard")
def dashboard_stats(usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                    COUNT(*) AS total_alunos,
                    COUNT(DISTINCT escola_origem) AS escolas_ativas,
                    ROUND(AVG(DATE_PART('year', AGE(data_nasc)))::numeric, 1) AS media_idade
                FROM alunos;
            """)
            resumo = cur.fetchone()

            cur.execute("""
                SELECT escola_origem, COUNT(*) AS quantidade
                FROM alunos
                GROUP BY escola_origem
                ORDER BY quantidade DESC
                LIMIT 10;
            """)
            por_escola = cur.fetchall()

            cur.execute("""
                SELECT tipo_busca, COUNT(*) AS quantidade
                FROM alunos
                GROUP BY tipo_busca;
            """)
            por_tipo_busca = cur.fetchall()

    return {
        "total_alunos": resumo["total_alunos"] or 0,
        "escolas_ativas": resumo["escolas_ativas"] or 0,
        "media_idade": float(resumo["media_idade"]) if resumo["media_idade"] else 0.0,
        "por_escola": por_escola,
        "por_tipo_busca": por_tipo_busca
    }


# ---------------------------------------------------------
# USUÁRIOS
# ---------------------------------------------------------
@api_router.get("/usuarios")
def listar_usuarios(usuario: dict = Depends(exigir_perfil("Administrador"))):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT usuario, nome, perfil FROM usuarios ORDER BY id;")
            return cur.fetchall()


@api_router.post("/usuarios")
def criar_usuario(
    dados: UsuarioSchema,
    usuario_adm: dict = Depends(exigir_perfil("Administrador"))
):
    if dados.perfil not in OPCOES_PERFIL:
        raise HTTPException(status_code=400, detail="Perfil de acesso inválido.")

    usuario_resp = f"{usuario_adm['nome']} ({usuario_adm['usuario']})"
    senha_hash = gerar_hash_senha(dados.senha)

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute(
                    "INSERT INTO usuarios (usuario, senha, nome, perfil) VALUES (%s, %s, %s, %s);",
                    (dados.usuario, senha_hash, dados.nome, dados.perfil)
                )
                conn.commit()
            except psycopg2.errors.UniqueViolation:
                conn.rollback()
                raise HTTPException(status_code=400, detail="Já existe um usuário com esse login.")

    registrar_log(usuario_resp, "Cadastro de Usuário", f"Criou o usuário {dados.usuario} ({dados.perfil})")
    return {"status": "sucesso"}


@api_router.put("/usuarios/{usuario_login}")
def atualizar_perfil(
    usuario_login: str,
    dados: PerfilUpdateSchema,
    usuario_adm: dict = Depends(exigir_perfil("Administrador"))
):
    if dados.perfil not in OPCOES_PERFIL:
        raise HTTPException(status_code=400, detail="Perfil inválido.")

    usuario_resp = f"{usuario_adm['nome']} ({usuario_adm['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("UPDATE usuarios SET perfil = %s WHERE usuario = %s;", (dados.perfil, usuario_login))
        conn.commit()

    registrar_log(usuario_resp, "Alteração de Perfil", f"Alterou perfil de {usuario_login} para {dados.perfil}")
    return {"status": "sucesso"}


@api_router.delete("/usuarios/{usuario_login}")
def remover_usuario(
    usuario_login: str,
    usuario_adm: dict = Depends(exigir_perfil("Administrador"))
):
    if usuario_login == "admin":
        raise HTTPException(status_code=400, detail="Não é permitido remover o usuário administrador padrão.")

    usuario_resp = f"{usuario_adm['nome']} ({usuario_adm['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM usuarios WHERE usuario = %s;", (usuario_login,))
        conn.commit()

    registrar_log(usuario_resp, "Exclusão de Usuário", f"Removeu o usuário {usuario_login}")
    return {"status": "sucesso"}


@api_router.post("/usuarios/{usuario_login}/resetar-senha")
def resetar_senha_usuario(
    usuario_login: str,
    dados: ResetSenhaSchema,
    usuario_adm: dict = Depends(exigir_perfil("Administrador"))
):
    nova = dados.nova_senha or ""
    if len(nova) < 4:
        raise HTTPException(status_code=400, detail="A senha deve ter no mínimo 4 caracteres.")

    usuario_resp = f"{usuario_adm['nome']} ({usuario_adm['usuario']})"
    senha_hash = gerar_hash_senha(nova)
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE usuarios SET senha = %s WHERE usuario = %s RETURNING usuario;",
                (senha_hash, usuario_login)
            )
            alterado = cur.fetchone()
        if not alterado:
            raise HTTPException(status_code=404, detail="Usuário não encontrado.")
        conn.commit()

    # Libera o teto de tentativas dessa conta, caso ela estivesse bloqueada
    limpar_falhas_login(f"user:{usuario_login.strip().lower()}")
    registrar_log(usuario_resp, "Redefinição de Senha", f"Redefiniu a senha do usuário {usuario_login}")
    return {"status": "sucesso"}


@api_router.get("/usuarios/modelo")
def baixar_modelo_usuarios(usuario: dict = Depends(exigir_perfil("Administrador"))):
    df_modelo = pd.DataFrame({
        "nome": ["João da Silva", "Maria Oliveira"],
        "usuario": ["joao.silva", "maria.gestora"],
        "senha": ["senha123", "senha456"],
        "perfil": ["Usuário Comum", "Gestor / Visualizador"]
    })
    buffer = io.BytesIO()
    with pd.ExcelWriter(buffer, engine="openpyxl") as writer:
        df_modelo.to_excel(writer, index=False, sheet_name="Modelo_Usuarios")
    buffer.seek(0)
    return StreamingResponse(
        buffer,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": "attachment; filename=modelo_usuarios.xlsx"}
    )


@api_router.post("/usuarios/lote")
async def importar_usuarios_lote(
    arquivo: UploadFile = File(...),
    usuario_adm: dict = Depends(exigir_perfil("Administrador"))
):
    usuario_resp = f"{usuario_adm['nome']} ({usuario_adm['usuario']})"
    conteudo = await arquivo.read()
    buffer = io.BytesIO(conteudo)

    if arquivo.filename.endswith(".csv"):
        df = pd.read_csv(buffer)
    else:
        df = pd.read_excel(buffer)

    df.columns = [c.strip().lower() for c in df.columns]
    df["perfil"] = df["perfil"].apply(lambda p: p if p in OPCOES_PERFIL else "Usuário Comum")

    total = 0
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            for _, row in df.iterrows():
                try:
                    senha_hash = gerar_hash_senha(str(row["senha"]))
                    cur.execute(
                        "INSERT INTO usuarios (usuario, senha, nome, perfil) VALUES (%s, %s, %s, %s);",
                        (row["usuario"], senha_hash, row["nome"], row["perfil"])
                    )
                    total += 1
                except psycopg2.errors.UniqueViolation:
                    conn.rollback()
                    continue
        conn.commit()

    registrar_log(usuario_resp, "Importação de Usuários em Lote", f"Importados {total} usuários via planilha.")
    return {"status": "sucesso", "total_importado": total}


# ---------------------------------------------------------
# ESCOLAS
# ---------------------------------------------------------
@api_router.get("/escolas")
def listar_escolas(usuario: dict = Depends(obter_usuario_atual)):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT modo_ordenacao_escolas FROM configuracoes_sistema WHERE id = 1;")
            row = cur.fetchone()
            modo = row["modo_ordenacao_escolas"] if row and row["modo_ordenacao_escolas"] else "alfabetica"

            if modo == "manual":
                cur.execute("SELECT id, nome, ordem FROM escolas ORDER BY ordem NULLS LAST, nome;")
            else:
                cur.execute("SELECT id, nome, ordem FROM escolas ORDER BY nome;")
            escolas = cur.fetchall()

    return {"modo": modo, "escolas": escolas}


@api_router.put("/escolas/ordem")
def reordenar_escolas(
    dados: OrdemEscolasSchema,
    usuario: dict = Depends(exigir_perfil("Administrador"))
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            for posicao, escola_id in enumerate(dados.ordem):
                cur.execute("UPDATE escolas SET ordem = %s WHERE id = %s;", (posicao, escola_id))
        conn.commit()

    registrar_log(usuario_resp, "Reordenação de Escolas", "Atualizou a ordem manual das escolas")
    return {"status": "sucesso"}


@api_router.post("/escolas/modo")
def definir_modo_ordenacao(
    dados: ModoOrdenacaoSchema,
    usuario: dict = Depends(exigir_perfil("Administrador"))
):
    if dados.modo not in ("alfabetica", "manual"):
        raise HTTPException(status_code=400, detail="Modo inválido. Use 'alfabetica' ou 'manual'.")

    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("UPDATE configuracoes_sistema SET modo_ordenacao_escolas = %s WHERE id = 1;", (dados.modo,))
        conn.commit()

    registrar_log(usuario_resp, "Alteração do Modo de Ordenação", f"Escolas ordenadas por: {dados.modo}")
    return {"status": "sucesso"}


@api_router.post("/escolas")
def criar_escola(
    dados: EscolaSchema,
    usuario: dict = Depends(exigir_perfil("Administrador"))
):
    nome = dados.nome.strip()
    if not nome:
        raise HTTPException(status_code=400, detail="O nome da escola não pode ficar em branco.")

    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute("INSERT INTO escolas (nome) VALUES (%s) RETURNING id;", (nome,))
                novo_id = cur.fetchone()["id"]
                conn.commit()
            except psycopg2.errors.UniqueViolation:
                conn.rollback()
                raise HTTPException(status_code=400, detail="Essa escola já está cadastrada.")

    registrar_log(usuario_resp, "Cadastro de Escola", f"Adicionou a escola {nome}")
    return {"status": "sucesso", "id": novo_id}


@api_router.delete("/escolas/{escola_id}")
def remover_escola(
    escola_id: int,
    usuario: dict = Depends(exigir_perfil("Administrador"))
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT nome FROM escolas WHERE id = %s;", (escola_id,))
            row = cur.fetchone()
            cur.execute("DELETE FROM escolas WHERE id = %s;", (escola_id,))
        conn.commit()

    if row:
        registrar_log(usuario_resp, "Exclusão de Escola", f"Removeu a escola {row['nome']}")
    return {"status": "sucesso"}


# ---------------------------------------------------------
# CONSULTA E ACOMPANHAMENTO
# ---------------------------------------------------------
@api_router.get("/acompanhamentos/abertos")
def listar_abertos(usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))):
    perfil = usuario["perfil"]
    ver_sigilosos = pode_ver_sigiloso(perfil)
    filtro_sigilo = "" if ver_sigilosos else "AND ac.sigiloso = FALSE"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(f"""
                SELECT ac.id, ac.motivo, ac.categoria_motivo, ac.urgencia, ac.sigiloso,
                       ac.data_prevista_retorno, ac.criado_por, ac.criado_em,
                       al.id AS aluno_id, al.nome AS aluno_nome, al.escola_origem, (al.foto IS NOT NULL) AS aluno_tem_foto,
                       EXTRACT(DAY FROM (%(agora)s::timestamp - ac.criado_em))::int AS dias_aberto,
                       (ac.data_prevista_retorno IS NOT NULL AND ac.data_prevista_retorno < %(agora)s::date) AS atrasado
                FROM acompanhamentos ac
                JOIN alunos al ON al.id = ac.aluno_id
                WHERE ac.status = 'aberto' AND ac.arquivado = FALSE {filtro_sigilo}
                ORDER BY CASE ac.urgencia WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END, ac.criado_em ASC;
            """, {"agora": agora_sistema(cur)})
            casos = cur.fetchall()

    total = len(casos)
    atrasados = sum(1 for c in casos if c["atrasado"])
    return {"total": total, "atrasados": atrasados, "casos": casos}


@api_router.get("/acompanhamentos/estatisticas")
def estatisticas_acompanhamento(usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))):
    perfil = usuario["perfil"]
    ver_sigilosos = pode_ver_sigiloso(perfil)
    filtro_sigilo = "" if ver_sigilosos else "AND sigiloso = FALSE"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(f"SELECT COUNT(*) as total FROM acompanhamentos WHERE status = 'aberto' AND arquivado = FALSE {filtro_sigilo};")
            total_abertos = cur.fetchone()["total"]

            cur.execute(f"""
                SELECT COUNT(*) as total FROM acompanhamentos
                WHERE status = 'aberto' AND arquivado = FALSE AND data_prevista_retorno IS NOT NULL
                      AND data_prevista_retorno < %(agora)s::date {filtro_sigilo};
            """, {"agora": agora_sistema(cur)})
            total_atrasados = cur.fetchone()["total"]

            cur.execute(f"SELECT COUNT(*) as total FROM acompanhamentos WHERE status = 'fechado' AND arquivado = FALSE {filtro_sigilo};")
            total_fechados = cur.fetchone()["total"]

            cur.execute(f"""
                SELECT ROUND(AVG(EXTRACT(EPOCH FROM (fechado_em - criado_em)) / 86400)::numeric, 1) as media
                FROM acompanhamentos
                WHERE status = 'fechado' AND arquivado = FALSE {filtro_sigilo};
            """)
            row = cur.fetchone()
            tempo_medio = float(row["media"]) if row and row["media"] else 0.0

            cur.execute(f"""
                SELECT urgencia, COUNT(*) as quantidade
                FROM acompanhamentos
                WHERE status = 'aberto' AND arquivado = FALSE {filtro_sigilo}
                GROUP BY urgencia;
            """)
            por_urgencia = cur.fetchall()

    return {
        "total_abertos": total_abertos,
        "total_atrasados": total_atrasados,
        "total_fechados": total_fechados,
        "tempo_medio_dias": tempo_medio,
        "por_urgencia": por_urgencia
    }


@api_router.get("/acompanhamentos/fechados")
def listar_fechados(usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))):
    perfil = usuario["perfil"]
    ver_sigilosos = pode_ver_sigiloso(perfil)
    filtro_sigilo = "" if ver_sigilosos else "AND ac.sigiloso = FALSE"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(f"""
                SELECT ac.id, ac.motivo, ac.categoria_motivo, ac.urgencia, ac.sigiloso,
                       ac.criado_por, ac.criado_em, ac.fechado_por, ac.fechado_em,
                       al.id AS aluno_id, al.nome AS aluno_nome, al.escola_origem, (al.foto IS NOT NULL) AS aluno_tem_foto,
                       EXTRACT(DAY FROM (ac.fechado_em - ac.criado_em))::int AS dias_duracao
                FROM acompanhamentos ac
                JOIN alunos al ON al.id = ac.aluno_id
                WHERE ac.status = 'fechado' AND ac.arquivado = FALSE {filtro_sigilo}
                ORDER BY ac.fechado_em DESC
                LIMIT 200;
            """)
            casos = cur.fetchall()

    return {"total": len(casos), "casos": casos}


@api_router.get("/acompanhamentos/exportar")
def exportar_abertos(usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))):
    perfil = usuario["perfil"]
    ver_sigilosos = pode_ver_sigiloso(perfil)
    filtro_sigilo = "" if ver_sigilosos else "AND ac.sigiloso = FALSE"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(f"""
                SELECT al.nome AS aluno, al.escola_origem AS escola, ac.motivo, ac.categoria_motivo AS categoria,
                       ac.urgencia, ac.status, ac.criado_por, ac.criado_em, ac.data_prevista_retorno
                FROM acompanhamentos ac
                JOIN alunos al ON al.id = ac.aluno_id
                WHERE ac.status = 'aberto' AND ac.arquivado = FALSE {filtro_sigilo}
                ORDER BY ac.criado_em ASC;
            """)
            dados = cur.fetchall()

    df = pd.DataFrame(dados)
    buffer = io.BytesIO()
    with pd.ExcelWriter(buffer, engine="openpyxl") as writer:
        df.to_excel(writer, index=False, sheet_name="Casos_Abertos")
    buffer.seek(0)
    return StreamingResponse(
        buffer,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": "attachment; filename=casos_abertos.xlsx"}
    )


@api_router.post("/acompanhamentos")
def abrir_acompanhamento(
    dados: AbrirAcompanhamentoSchema,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM acompanhamentos WHERE aluno_id = %s AND status = 'aberto' AND arquivado = FALSE;", (dados.aluno_id,))
            existente = cur.fetchone()
            if existente:
                raise HTTPException(status_code=400, detail=f"Este aluno já possui um acompanhamento em aberto (ID {existente['id']}).")

            sigiloso = dados.categoria_motivo in CATEGORIAS_SIGILOSAS

            agora = agora_sistema(cur)
            cur.execute("""
                INSERT INTO acompanhamentos (aluno_id, motivo, categoria_motivo, urgencia, status, sigiloso, data_prevista_retorno, criado_por, criado_em)
                VALUES (%s, %s, %s, %s, 'aberto', %s, %s, %s, %s) RETURNING id;
            """, (dados.aluno_id, dados.motivo, dados.categoria_motivo, dados.urgencia, sigiloso,
                  dados.data_prevista_retorno, usuario_resp, agora))
            novo_id = cur.fetchone()["id"]
        conn.commit()

    registrar_log(usuario_resp, "Abertura de Acompanhamento", f"Aluno ID {dados.aluno_id} | Motivo: {dados.motivo}")
    return {"status": "sucesso", "id": novo_id, "sigiloso": sigiloso}


@api_router.get("/acompanhamentos/{acompanhamento_id}")
def obter_acompanhamento(
    acompanhamento_id: int,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    perfil = usuario["perfil"]
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM acompanhamentos WHERE id = %s;", (acompanhamento_id,))
            caso = cur.fetchone()
            if not caso:
                raise HTTPException(status_code=404, detail="Acompanhamento não encontrado.")
            if caso["sigiloso"] and not pode_ver_sigiloso(perfil):
                raise HTTPException(status_code=403, detail="Você não tem permissão para visualizar este acompanhamento sigiloso.")

            cur.execute("SELECT * FROM acompanhamento_mensagens WHERE acompanhamento_id = %s ORDER BY data_hora ASC, id ASC;", (acompanhamento_id,))
            mensagens = cur.fetchall()
            for m in mensagens:
                cur.execute("SELECT id, nome_arquivo, tipo_mime FROM anexos_mensagem WHERE mensagem_id = %s;", (m["id"],))
                m["anexos"] = cur.fetchall()

    caso["mensagens"] = mensagens
    caso["pode_editar"] = pode_editar_mensagem(perfil, caso["sigiloso"])
    caso["pode_reabrir"] = pode_reabrir(perfil, caso["sigiloso"])
    return caso


@api_router.post("/acompanhamentos/{acompanhamento_id}/mensagens")
async def criar_mensagem(
    acompanhamento_id: int,
    categoria: str = Form(...),
    texto: str = Form(...),
    encaminhamento_oficial: bool = Form(False),
    encaminhado_para: str = Form(""),
    data_hora: str | None = Form(None),
    arquivos: list[UploadFile] = File(default=[]),
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT status, arquivado, sigiloso FROM acompanhamentos WHERE id = %s;", (acompanhamento_id,))
            caso = cur.fetchone()
            if not caso:
                raise HTTPException(status_code=404, detail="Acompanhamento não encontrado.")
            if caso["sigiloso"] and not pode_ver_sigiloso(usuario["perfil"]):
                raise HTTPException(status_code=403, detail="Sem permissão para interagir com este acompanhamento sigiloso.")
            if caso["arquivado"]:
                raise HTTPException(status_code=400, detail="Este acompanhamento pertence a um ano letivo encerrado e está em modo somente leitura.")
            if caso["status"] != "aberto":
                raise HTTPException(status_code=400, detail="Este acompanhamento está fechado. Reabra para adicionar novas mensagens.")

            cur.execute("""
                INSERT INTO acompanhamento_mensagens (acompanhamento_id, usuario_responsavel, categoria, texto, encaminhamento_oficial, encaminhado_para, data_hora)
                VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id;
            """, (acompanhamento_id, usuario_resp, categoria, texto, encaminhamento_oficial, encaminhado_para, agora_sistema(cur)))
            mensagem_id = cur.fetchone()["id"]

            for arquivo in arquivos:
                conteudo = await arquivo.read()
                if conteudo:
                    cur.execute("""
                        INSERT INTO anexos_mensagem (mensagem_id, nome_arquivo, tipo_mime, conteudo)
                        VALUES (%s, %s, %s, %s);
                    """, (mensagem_id, arquivo.filename, arquivo.content_type, psycopg2.Binary(conteudo)))

        conn.commit()

    detalhes = f"Acompanhamento ID {acompanhamento_id} | Categoria: {categoria}"
    if encaminhamento_oficial:
        detalhes += f" | Encaminhamento oficial para: {encaminhado_para}"
    registrar_log(usuario_resp, "Mensagem de Acompanhamento", detalhes)
    return {"status": "sucesso", "id": mensagem_id}


@api_router.post("/acompanhamentos/{acompanhamento_id}/fechar")
def fechar_acompanhamento(
    acompanhamento_id: int,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT arquivado, sigiloso FROM acompanhamentos WHERE id = %s;", (acompanhamento_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Acompanhamento não encontrado.")
            if row["sigiloso"] and not pode_ver_sigiloso(usuario["perfil"]):
                raise HTTPException(status_code=403, detail="Sem permissão para encerrar este acompanhamento sigiloso.")
            if row["arquivado"]:
                raise HTTPException(status_code=400, detail="Este acompanhamento pertence a um ano letivo encerrado e está em modo somente leitura.")

            cur.execute(
                "UPDATE acompanhamentos SET status = 'fechado', fechado_por = %s, fechado_em = %s WHERE id = %s AND status = 'aberto';",
                (usuario_resp, agora_sistema(cur), acompanhamento_id)
            )
        conn.commit()

    registrar_log(usuario_resp, "Fechamento de Acompanhamento", f"Acompanhamento ID {acompanhamento_id}")
    return {"status": "sucesso"}


@api_router.post("/acompanhamentos/{acompanhamento_id}/reabrir")
def reabrir_acompanhamento(
    acompanhamento_id: int,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    perfil = usuario["perfil"]
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT sigiloso, aluno_id, arquivado FROM acompanhamentos WHERE id = %s;", (acompanhamento_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Acompanhamento não encontrado.")
            if row["arquivado"]:
                raise HTTPException(status_code=400, detail="Este acompanhamento pertence a um ano letivo encerrado e está em modo somente leitura.")
            if not pode_reabrir(perfil, row["sigiloso"]):
                raise HTTPException(status_code=403, detail="Sem permissão para reabrir este acompanhamento.")

            cur.execute("SELECT id FROM acompanhamentos WHERE aluno_id = %s AND status = 'aberto' AND arquivado = FALSE AND id != %s;",
                        (row["aluno_id"], acompanhamento_id))
            if cur.fetchone():
                raise HTTPException(status_code=400, detail="Este aluno já possui outro acompanhamento em aberto.")

            cur.execute(
                "UPDATE acompanhamentos SET status = 'aberto', reaberto_por = %s, reaberto_em = %s WHERE id = %s;",
                (usuario_resp, agora_sistema(cur), acompanhamento_id)
            )
        conn.commit()

    registrar_log(usuario_resp, "Reabertura de Acompanhamento", f"Acompanhamento ID {acompanhamento_id}")
    return {"status": "sucesso"}


def _t(valor):
    """Escapa texto digitado por usuários antes de colocá-lo em um Paragraph do ReportLab
    (que interpreta marcação como <b>, <font> e <img src=...>)."""
    return _xml_escape("" if valor is None else str(valor))


def _obter_textos_pdf():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT cabecalho_pdf_texto, rodape_pdf_texto, logo_pdf_base64, tamanho_logo_pdf FROM configuracoes_sistema WHERE id = 1;")
            row = cur.fetchone()

    cabecalho = (row["cabecalho_pdf_texto"] or "").strip() if row else ""
    rodape = (row["rodape_pdf_texto"] or "").strip() if row else ""
    _, logo_bytes = _decodificar_data_uri(row["logo_pdf_base64"] if row else None)
    tamanho_logo = (row["tamanho_logo_pdf"] if row and row["tamanho_logo_pdf"] else 60)
    return cabecalho, rodape, logo_bytes, tamanho_logo


def _callback_cabecalho_rodape(cabecalho_texto, rodape_texto, logo_bytes=None, tamanho_logo=60):
    def _desenhar(canvas_obj, doc):
        largura, altura = doc.pagesize
        linha_y = altura - max(52, tamanho_logo + 20)
        if logo_bytes:
            try:
                canvas_obj.saveState()
                img_reader = ImageReader(io.BytesIO(logo_bytes))
                iw, ih = img_reader.getSize()
                largura_img = tamanho_logo * (iw / ih) if ih else tamanho_logo
                canvas_obj.drawImage(
                    img_reader, doc.leftMargin, altura - tamanho_logo - 12,
                    width=largura_img, height=tamanho_logo, preserveAspectRatio=True, mask='auto'
                )
                canvas_obj.restoreState()
            except Exception:
                pass
        if cabecalho_texto:
            canvas_obj.saveState()
            canvas_obj.setFont("Helvetica", 8)
            canvas_obj.setFillColor(colors.HexColor("#64748B"))
            canvas_obj.drawCentredString(largura / 2, altura - 24, cabecalho_texto)
            canvas_obj.setStrokeColor(colors.HexColor("#E2E8F0"))
            canvas_obj.line(doc.leftMargin, linha_y, largura - doc.rightMargin, linha_y)
            canvas_obj.restoreState()
        elif logo_bytes:
            canvas_obj.saveState()
            canvas_obj.setStrokeColor(colors.HexColor("#E2E8F0"))
            canvas_obj.line(doc.leftMargin, linha_y, largura - doc.rightMargin, linha_y)
            canvas_obj.restoreState()
        if rodape_texto:
            canvas_obj.saveState()
            canvas_obj.setFont("Helvetica", 8)
            canvas_obj.setFillColor(colors.HexColor("#94A3B8"))
            canvas_obj.setStrokeColor(colors.HexColor("#E2E8F0"))
            canvas_obj.line(doc.leftMargin, 34, largura - doc.rightMargin, 34)
            canvas_obj.drawCentredString(largura / 2, 20, f"{rodape_texto} — Página {doc.page}")
            canvas_obj.restoreState()
    return _desenhar


# ---------------------------------------------------------
# RELATÓRIO DO ACOMPANHAMENTO (dados, textos e página HTML)
# ---------------------------------------------------------
_TEXTOS_FINALIDADE = [
    "Este relatório tem por finalidade registrar e sistematizar as providências adotadas pela Secretaria de Educação e Inovação Pedagógica, em articulação com a unidade escolar, para o acompanhamento da frequência escolar do(a) estudante, a verificação dos motivos das faltas e o registro das justificativas apresentadas pela família ou responsável legal.",
    "O procedimento busca documentar as ações realizadas para a identificação e o acompanhamento de situações de faltas injustificadas, infrequência escolar ou possível evasão, bem como os contatos e as providências adotadas junto à família, à unidade escolar e aos demais órgãos integrantes da rede de proteção.",
    "Quando, após a adoção das medidas de acompanhamento e das providências cabíveis no âmbito escolar, permanecer situação que demande atuação da rede de proteção, as informações registradas neste relatório poderão subsidiar o encaminhamento ao Conselho Tutelar, para conhecimento, acompanhamento e adoção das medidas que entender cabíveis, observadas as competências legais de cada órgão.",
    "O presente relatório constitui instrumento de registro, acompanhamento e documentação das providências realizadas pela Secretaria de Educação e Inovação Pedagógica, não substituindo os registros de frequência e demais documentos de responsabilidade da unidade escolar.",
]
_FUNDAMENTO_LEGAL = [
    ("7.1. Lei Federal nº 9.394/1996 – Lei de Diretrizes e Bases da Educação Nacional (LDB)",
     "O art. 12, inciso VIII, estabelece como incumbência dos estabelecimentos de ensino a notificação ao Conselho Tutelar do Município da relação dos alunos que apresentem quantidade de faltas acima do percentual permitido em lei."),
    ("7.2. Lei Federal nº 8.069/1990 – Estatuto da Criança e do Adolescente (ECA)",
     "O art. 56, inciso II, estabelece que os dirigentes de estabelecimentos de ensino fundamental devem comunicar ao Conselho Tutelar os casos de reiteração de faltas injustificadas e de evasão escolar, esgotados os recursos escolares."),
    ("7.3. Aplicação institucional",
     "Considerando as competências legais dos diferentes órgãos envolvidos, este relatório possui caráter de registro, acompanhamento, sistematização e documentação das providências realizadas, podendo subsidiar os encaminhamentos necessários à rede de proteção, sem substituir os documentos e procedimentos próprios da unidade escolar ou dos demais órgãos competentes."),
]


def _carregar_dados_relatorio_caso(acompanhamento_id: int, usuario: dict):
    """Carrega o caso, o aluno e as mensagens (com a lista de anexos), aplicando a regra de sigilo."""
    perfil = usuario["perfil"]
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ac.*, al.nome AS aluno_nome, al.cpf, al.data_nasc, al.escola_origem, al.turma, al.endereco,
                       al.tipo_busca, al.observacoes AS aluno_observacoes
                FROM acompanhamentos ac JOIN alunos al ON al.id = ac.aluno_id
                WHERE ac.id = %s;
            """, (acompanhamento_id,))
            caso = cur.fetchone()
            if not caso:
                raise HTTPException(status_code=404, detail="Acompanhamento não encontrado.")
            if caso["sigiloso"] and not pode_ver_sigiloso(perfil):
                raise HTTPException(status_code=403, detail="Sem permissão para gerar relatório deste caso sigiloso.")

            cur.execute("SELECT * FROM acompanhamento_mensagens WHERE acompanhamento_id = %s ORDER BY data_hora ASC, id ASC;", (acompanhamento_id,))
            mensagens = cur.fetchall()
            for m in mensagens:
                cur.execute("SELECT id, nome_arquivo, tipo_mime FROM anexos_mensagem WHERE mensagem_id = %s ORDER BY id;", (m["id"],))
                m["anexos"] = cur.fetchall()
    return caso, mensagens


def _numero_relatorio(caso, agora):
    return f"REL-{(caso['criado_em'] or agora).year}-{str(caso['id']).zfill(4)}"


@api_router.get("/acompanhamentos/{acompanhamento_id}/relatorio-pdf")
def relatorio_pdf_caso(
    acompanhamento_id: int,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    caso, mensagens = _carregar_dados_relatorio_caso(acompanhamento_id, usuario)

    cabecalho_cfg, rodape_cfg, logo_pdf, tamanho_logo_pdf = _obter_textos_pdf()
    agora = datetime.now(FUSO_RECIFE)
    NAVY = colors.HexColor("#1E3A5F")
    CINZA_BORDA = colors.HexColor("#CBD5E1")
    ZEBRA = colors.HexColor("#F8FAFC")
    numero = _numero_relatorio(caso, agora)
    nome_aluno = str(caso["aluno_nome"] or "")
    emitido_por = str(usuario["nome"] or "")

    def _data(v):
        return v.strftime("%d/%m/%Y") if v else "—"

    def _hora(v):
        return v.strftime("%H:%M") if v else "—"

    def _data_hora_seg(v):
        return v.strftime("%d/%m/%Y, %H:%M:%S") if v else "—"

    def _sem_login(v):
        return _t(str(v or "").split(" (")[0]) or "—"

    def _selo(texto, fundo, cor):
        return f'<font backColor="{fundo}" color="{cor}">&nbsp;<b>{_t(texto)}</b>&nbsp;</font>'

    urg = str(caso["urgencia"] or "").lower()
    selo_urgencia = {
        "alta": _selo("ALTA", "#FEE2E2", "#991B1B"),
        "media": _selo("MÉDIA", "#FEF3C7", "#92400E"),
        "baixa": _selo("BAIXA", "#D1FAE5", "#065F46"),
    }.get(urg, _selo(urg.upper() or "—", "#E2E8F0", "#334155"))
    if caso.get("arquivado"):
        situacao_txt, selo_situacao = "ARQUIVADO (ANO LETIVO ENCERRADO)", _selo("ARQUIVADO", "#EDE9FE", "#5B21B6")
    elif caso["status"] == "aberto":
        situacao_txt, selo_situacao = "EM ANDAMENTO", _selo("EM ANDAMENTO", "#DCFCE7", "#166534")
    else:
        situacao_txt, selo_situacao = "CONCLUÍDO", _selo("CONCLUÍDO", "#E2E8F0", "#334155")

    styles = getSampleStyleSheet()
    est = lambda nome, **kw: ParagraphStyle(nome, parent=styles['Normal'], **kw)
    s_inst1 = est('inst1', fontName='Helvetica-Bold', fontSize=15, leading=18, textColor=NAVY)
    s_inst2 = est('inst2', fontName='Helvetica-Bold', fontSize=10.5, leading=13, textColor=colors.HexColor("#334155"))
    s_inst3 = est('inst3', fontSize=9, leading=11, textColor=colors.HexColor("#64748B"))
    s_titulo = est('titulo', fontName='Helvetica-Bold', fontSize=18, leading=22, textColor=NAVY, alignment=1, spaceBefore=8, spaceAfter=8)
    s_info = est('info', fontSize=9.5, leading=15)
    s_secao = est('secao', fontName='Helvetica-Bold', fontSize=11, leading=14, textColor=colors.HexColor("#1E293B"))
    s_sub = est('sub', fontName='Helvetica-Bold', fontSize=10, leading=13, spaceBefore=8, spaceAfter=4, textColor=colors.HexColor("#1E293B"))
    s_texto = est('texto', fontSize=9.5, leading=13, spaceAfter=6)
    s_lbl = est('lbl', fontName='Helvetica-Bold', fontSize=9.5, leading=12)
    s_val = est('val', fontSize=9.5, leading=12)
    s_head = est('head', fontName='Helvetica-Bold', fontSize=9, leading=11, textColor=colors.white)
    s_cel = est('cel', fontSize=8.5, leading=10.5)
    s_peq = est('peq', fontSize=8.5, leading=11, textColor=colors.HexColor("#475569"))

    def secao(titulo):
        return [Spacer(1, 10), Paragraph(titulo, s_secao),
                HRFlowable(width="100%", thickness=2, color=NAVY, spaceBefore=1, spaceAfter=6)]

    def tabela(cabecalho, linhas, larguras, estilo_cel=s_cel, rotulo_negrito=False, pad=6):
        dados = [[Paragraph(c, s_head) for c in cabecalho]]
        for linha in linhas:
            dados.append([Paragraph(str(c), (s_lbl if (rotulo_negrito and i == 0) else estilo_cel)) for i, c in enumerate(linha)])
        t = Table(dados, colWidths=larguras, repeatRows=1)
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), NAVY),
            ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, ZEBRA]),
            ('GRID', (0, 0), (-1, -1), 0.4, CINZA_BORDA),
            ('VALIGN', (0, 0), (-1, -1), 'TOP'),
            ('TOPPADDING', (0, 0), (-1, -1), 4), ('BOTTOMPADDING', (0, 0), (-1, -1), 4),
            ('LEFTPADDING', (0, 0), (-1, -1), pad), ('RIGHTPADDING', (0, 0), (-1, -1), pad),
        ]))
        return t

    def tabela_campos(linhas):
        return tabela(["Campo", "Informação"], linhas, [165, 350], estilo_cel=s_val, rotulo_negrito=True)

    elements = []

    # ---------- cabeçalho institucional ----------
    textos_cab = [Paragraph("PREFEITURA MUNICIPAL DE GOIANA", s_inst1),
                  Paragraph("SECRETARIA DE EDUCAÇÃO E INOVAÇÃO PEDAGÓGICA", s_inst2),
                  Paragraph(_t(cabecalho_cfg) if cabecalho_cfg else "Coordenação de Acompanhamento e Busca Ativa Escolar", s_inst3)]
    imagem_logo = None
    if logo_pdf:
        try:
            leitor = ImageReader(io.BytesIO(logo_pdf))
            iw, ih = leitor.getSize()
            alt = max(24, min(float(tamanho_logo_pdf or 60), 120)) * 0.75
            imagem_logo = RLImage(io.BytesIO(logo_pdf), width=alt * iw / ih, height=alt)
        except Exception:
            imagem_logo = None
    if imagem_logo:
        larg_logo = imagem_logo.drawWidth + 14
        cab = Table([[imagem_logo, textos_cab]], colWidths=[larg_logo, 515 - larg_logo])
        cab.setStyle(TableStyle([('VALIGN', (0, 0), (-1, -1), 'MIDDLE'), ('LEFTPADDING', (0, 0), (-1, -1), 0), ('RIGHTPADDING', (0, 0), (-1, -1), 0)]))
    else:
        cab = Table([[textos_cab]], colWidths=[515])
        cab.setStyle(TableStyle([('LEFTPADDING', (0, 0), (-1, -1), 0)]))
    elements += [cab, Spacer(1, 6), HRFlowable(width="100%", thickness=3, color=NAVY, spaceAfter=4)]
    elements.append(Paragraph("RELATÓRIO DE ACOMPANHAMENTO ESCOLAR", s_titulo))

    linha_info2 = f"<b>Status:</b> {selo_situacao} &nbsp;&nbsp;&nbsp; <b>Urgência:</b> {selo_urgencia}"
    if caso["sigiloso"]:
        linha_info2 += f" &nbsp;&nbsp;&nbsp; <b>Classificação:</b> {_selo('SIGILOSO', '#EDE9FE', '#5B21B6')}"
    caixa = Table([[Paragraph(f"<b>Nº do Relatório:</b> {_t(numero)} &nbsp;&nbsp;&nbsp; <b>Data de emissão:</b> {_data(agora)} &nbsp;&nbsp;&nbsp; <b>Emitido por:</b> {_t(emitido_por)}", s_info)],
                   [Paragraph(linha_info2, s_info)]], colWidths=[515])
    caixa.setStyle(TableStyle([('BACKGROUND', (0, 0), (-1, -1), ZEBRA), ('BOX', (0, 0), (-1, -1), 0.6, CINZA_BORDA),
                               ('LEFTPADDING', (0, 0), (-1, -1), 10), ('TOPPADDING', (0, 0), (-1, -1), 4), ('BOTTOMPADDING', (0, 0), (-1, -1), 4)]))
    elements.append(caixa)

    # ---------- 1. identificação ----------
    elements += secao("1. IDENTIFICAÇÃO DO(A) ESTUDANTE")
    elements.append(tabela_campos([
        ("Nome do(a) estudante", _t(nome_aluno)),
        ("CPF", _t(caso["cpf"]) or "—"),
        ("Data de nascimento", _data(caso["data_nasc"])),
        ("Unidade escolar", _t(caso["escola_origem"]) or "—"),
        ("Ano/Série — Turma", _t(caso["turma"]) or "—"),
        ("Turno", "Não informado"),
        ("Tipo de busca ativa", _t(caso.get("tipo_busca")) or "—"),
        ("Endereço", _t(caso["endereco"]) or "—"),
    ]))

    # ---------- 2. caracterização ----------
    linhas = [
        ("Motivo do acompanhamento", _t(caso["motivo"]) or "—"),
        ("Categoria do motivo", _t(caso["categoria_motivo"]) or "—"),
        ("Data de abertura do caso", _data(caso["criado_em"])),
        ("Responsável pela abertura", _sem_login(caso["criado_por"])),
        ("Urgência", selo_urgencia),
        ("Situação atual", selo_situacao),
    ]
    if caso.get("data_prevista_retorno"):
        linhas.append(("Data prevista de retorno", _data(caso["data_prevista_retorno"])))
    if caso.get("fechado_em"):
        linhas.append(("Data de conclusão/fechamento", _data(caso["fechado_em"])))
        linhas.append(("Encerrado por", _sem_login(caso["fechado_por"])))
    if caso.get("reaberto_em"):
        linhas.append(("Reaberto em / por", f"{_data(caso['reaberto_em'])} — {_sem_login(caso['reaberto_por'])}"))
    linhas.append(("Total de registros no histórico", f"{len(mensagens)} ocorrência(s)"))
    elements += secao("2. CARACTERIZAÇÃO DA SITUAÇÃO")
    elements.append(tabela_campos(linhas))
    elements.append(Paragraph("2.1. Descrição inicial da situação", s_sub))
    desc = Table([[Paragraph(_t(caso["motivo"]) or "—", s_val)]], colWidths=[515])
    desc.setStyle(TableStyle([('BACKGROUND', (0, 0), (-1, -1), ZEBRA), ('BOX', (0, 0), (-1, -1), 0.4, CINZA_BORDA),
                              ('LINEBEFORE', (0, 0), (0, -1), 3, NAVY), ('LEFTPADDING', (0, 0), (-1, -1), 10),
                              ('TOPPADDING', (0, 0), (-1, -1), 6), ('BOTTOMPADDING', (0, 0), (-1, -1), 6)]))
    elements.append(desc)

    # ---------- 3. providências ----------
    encaminhamentos = [m for m in mensagens if m["encaminhamento_oficial"]]
    tipos = list(dict.fromkeys(str(m["categoria"] or "—") for m in mensagens))
    elements += secao("3. PROVIDÊNCIAS ADOTADAS")
    if mensagens:
        elements.append(Paragraph("Registra-se abaixo o resumo das providências adotadas no âmbito deste acompanhamento. "
                                  "Cada providência está registrada de forma individualizada no histórico constante da seção 4.", s_texto))
        for tp in tipos:
            elements.append(Paragraph(f"•&nbsp;&nbsp;{_t(tp)}", s_val))
        elements.append(Spacer(1, 4))
        elements.append(Paragraph(f"<b>Total de ocorrências registradas:</b> {len(mensagens)} — <b>Encaminhamentos oficiais:</b> {len(encaminhamentos)}", s_val))
    else:
        elements.append(Paragraph("Nenhuma providência registrada até o momento.", s_texto))

    # ---------- 4. histórico ----------
    elements += secao("4. HISTÓRICO DE ACOMPANHAMENTO")
    elements.append(Paragraph("Registro cronológico de todas as ocorrências, providências e ações realizadas no âmbito deste acompanhamento.", s_texto))
    if mensagens:
        elements.append(tabela(
            ["Data", "Horário", "Tipo de ação", "Responsável", "Registro / Resultado", "Encaminhamento"],
            [(_data(m["data_hora"]), _hora(m["data_hora"]), _t(m["categoria"]) or "—", _sem_login(m["usuario_responsavel"]),
              _t(m["texto"]).replace("\n", "<br/>"),
              (_t(m["encaminhado_para"]) + (" (Art. 56 do ECA)" if m["encaminhado_para"] == "Conselho Tutelar" else "")) if m["encaminhamento_oficial"] else "—")
             for m in mensagens],
            [58, 46, 62, 70, 182, 97], pad=4))
    else:
        elements.append(Paragraph("Nenhuma ocorrência registrada até o momento.", s_texto))

    # ---------- 5. situação atual e encaminhamentos ----------
    ultima = mensagens[-1] if mensagens else None
    datas_ref = [d for d in [ultima["data_hora"] if ultima else None, caso.get("fechado_em"), caso.get("reaberto_em"), caso.get("criado_em")] if d]
    ultima_prov = _t(ultima["texto"])[:220] if ultima else "—"
    elements += secao("5. SITUAÇÃO ATUAL E ENCAMINHAMENTOS")
    elements.append(Paragraph("5.1. Situação atual", s_sub))
    elements.append(tabela_campos([
        ("Situação", selo_situacao),
        ("Última atualização", _data_hora_seg(max(datas_ref)) if datas_ref else "—"),
        ("Última providência realizada", ultima_prov or "—"),
    ]))
    elements.append(Paragraph("5.2. Encaminhamentos realizados", s_sub))
    if encaminhamentos:
        elements.append(tabela(
            ["Data", "Órgão / Setor", "Motivo", "Providência / Registro", "Responsável", "Situação"],
            [(_data(m["data_hora"]),
              _t(m["encaminhado_para"]) + (" (Art. 56 do ECA)" if m["encaminhado_para"] == "Conselho Tutelar" else ""),
              _t(caso["motivo"]), _t(m["texto"]).replace("\n", "<br/>"), _sem_login(m["usuario_responsavel"]), "Encaminhado")
             for m in encaminhamentos],
            [58, 84, 84, 150, 70, 69], pad=4))
    else:
        elements.append(Paragraph("Nenhum encaminhamento oficial registrado.", s_texto))
    elements.append(Paragraph("5.3. Próximas providências", s_sub))
    if caso.get("arquivado"):
        proximas = "Acompanhamento arquivado em razão do encerramento do ano letivo. Registro mantido somente para consulta."
    elif caso["status"] == "aberto":
        retorno = f" Retorno previsto para {_data(caso['data_prevista_retorno'])}." if caso.get("data_prevista_retorno") else ""
        proximas = "Acompanhamento em andamento. Manter o monitoramento da frequência do(a) estudante e registrar as novas providências neste sistema." + retorno
    else:
        proximas = "Acompanhamento concluído. As providências previstas foram finalizadas."
    elements.append(Paragraph(proximas, s_texto))

    # ---------- 6 e 7. finalidade e fundamento legal ----------
    elements += secao("6. FINALIDADE DO PROCEDIMENTO")
    for par in _TEXTOS_FINALIDADE:
        elements.append(Paragraph(_t(par), s_texto))
    elements += secao("7. FUNDAMENTO LEGAL")
    for titulo_leg, texto_leg in _FUNDAMENTO_LEGAL:
        elements.append(Paragraph(_t(titulo_leg), s_sub))
        elements.append(Paragraph(_t(texto_leg), s_texto))

    # ---------- 8. anexos ----------
    docs = []
    for m in mensagens:
        for a in m["anexos"]:
            docs.append((_t(a["nome_arquivo"]), _data(m["data_hora"]), _sem_login(m["usuario_responsavel"])))
    elements += secao("8. DOCUMENTOS E COMPROVAÇÕES ANEXAS")
    if docs:
        elements.append(tabela(["Nº", "Documento", "Data", "Origem", "Anexo"],
                               [(str(i).zfill(2), d[0], d[1], d[2], "Sim") for i, d in enumerate(docs, 1)],
                               [32, 245, 68, 110, 60]))
    else:
        elements.append(Paragraph("Nenhum documento anexado.", s_texto))

    # ---------- 9. observações ----------
    elements += secao("9. OBSERVAÇÕES")
    obs = str(caso.get("aluno_observacoes") or "").strip()
    elements.append(Paragraph(_t(obs).replace("\n", "<br/>") if obs else "Nenhuma observação registrada.", s_texto))

    # ---------- 10. responsabilidade ----------
    elements += secao("10. RESPONSABILIDADE PELO REGISTRO")
    elements.append(Paragraph("<b>Órgão responsável pelo acompanhamento:</b><br/>Secretaria de Educação e Inovação Pedagógica — Prefeitura Municipal de Goiana", s_texto))
    elements.append(Paragraph("<b>Unidade/Setor responsável:</b><br/>Coordenação de Acompanhamento e Busca Ativa Escolar", s_texto))
    elements.append(Paragraph("<b>Servidor(a) responsável pelo registro:</b>", s_texto))
    assin = Table([[Paragraph(f"<b>{_t(emitido_por)}</b>", s_val), Paragraph(f"Data de emissão: {_data(agora)}", s_val)]], colWidths=[300, 215])
    assin.setStyle(TableStyle([('LINEBELOW', (0, 0), (0, 0), 0.8, colors.HexColor("#334155")), ('TOPPADDING', (0, 0), (-1, -1), 22),
                               ('VALIGN', (0, 0), (-1, -1), 'BOTTOM'), ('LEFTPADDING', (0, 0), (-1, -1), 0)]))
    elements.append(assin)

    # ---------- rodapé de todas as páginas ----------
    rodape3 = rodape_cfg or "Relatório de Acompanhamento Escolar — Documento de uso institucional"
    def _rodape(canvas_obj, doc):
        largura, _ = doc.pagesize
        canvas_obj.saveState()
        canvas_obj.setStrokeColor(CINZA_BORDA)
        canvas_obj.line(doc.leftMargin, 62, largura - doc.rightMargin, 62)
        canvas_obj.setFillColor(colors.HexColor("#64748B"))
        canvas_obj.setFont("Helvetica", 7.5)
        for i, txt in enumerate(["Prefeitura Municipal de Goiana", "Secretaria de Educação e Inovação Pedagógica", rodape3[:110]]):
            canvas_obj.drawString(doc.leftMargin, 52 - i * 10, txt)
        for i, txt in enumerate([f"{numero} — Emitido em {_data_hora_seg(agora)}", nome_aluno[:60], f"Pág. {doc.page}"]):
            canvas_obj.drawRightString(largura - doc.rightMargin, 52 - i * 10, txt)
        canvas_obj.restoreState()

    buffer = io.BytesIO()
    doc = SimpleDocTemplate(buffer, pagesize=A4, leftMargin=40, rightMargin=40, topMargin=34, bottomMargin=78,
                            title=f"Relatório de Acompanhamento — {nome_aluno}", author=emitido_por)
    doc.build(elements, onFirstPage=_rodape, onLaterPages=_rodape)
    buffer.seek(0)
    registrar_log(f"{usuario['nome']} ({usuario['usuario']})", "Geração de Relatório", f"Relatório {numero} do acompanhamento {acompanhamento_id}")
    return StreamingResponse(
        buffer, media_type="application/pdf",
        headers={"Content-Disposition": f"attachment; filename={numero}.pdf"}
    )


@api_router.get("/acompanhamentos/anexos/{anexo_id}")
def obter_anexo(
    anexo_id: int,
    usuario: dict = Depends(obter_usuario_atual)
):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ax.nome_arquivo, ax.tipo_mime, ax.conteudo, ac.sigiloso
                FROM anexos_mensagem ax
                JOIN acompanhamento_mensagens am ON am.id = ax.mensagem_id
                JOIN acompanhamentos ac ON ac.id = am.acompanhamento_id
                WHERE ax.id = %s;
            """, (anexo_id,))
            row = cur.fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="Anexo não encontrado.")
    if row["sigiloso"] and not pode_ver_sigiloso(usuario["perfil"]):
        raise HTTPException(status_code=403, detail="Sem permissão para acessar este anexo sigiloso.")

    conteudo = bytes(row["conteudo"])
    return Response(
        content=conteudo,
        media_type=row["tipo_mime"] or "application/octet-stream",
        headers={"Content-Disposition": f'inline; filename="{row["nome_arquivo"]}"'}
    )


@api_router.put("/acompanhamentos/mensagens/{mensagem_id}")
def editar_mensagem(
    mensagem_id: int,
    dados: MensagemUpdateSchema,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    perfil = usuario["perfil"]
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT m.id, a.sigiloso, a.arquivado FROM acompanhamento_mensagens m
                JOIN acompanhamentos a ON a.id = m.acompanhamento_id
                WHERE m.id = %s;
            """, (mensagem_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Mensagem não encontrada.")
            if row["arquivado"]:
                raise HTTPException(status_code=400, detail="Este acompanhamento pertence a um ano letivo encerrado e está em modo somente leitura.")
            if not pode_editar_mensagem(perfil, row["sigiloso"]):
                raise HTTPException(status_code=403, detail="Sem permissão para editar esta mensagem.")

            cur.execute("""
                UPDATE acompanhamento_mensagens SET texto = %s, categoria = %s, editado_por = %s, editado_em = %s
                WHERE id = %s;
            """, (dados.texto, dados.categoria, usuario_resp, agora_sistema(cur), mensagem_id))
        conn.commit()

    registrar_log(usuario_resp, "Edição de Mensagem de Acompanhamento", f"Mensagem ID {mensagem_id}")
    return {"status": "sucesso"}


@api_router.delete("/acompanhamentos/mensagens/{mensagem_id}")
def apagar_mensagem(
    mensagem_id: int,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    perfil = usuario["perfil"]
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT m.id, a.sigiloso, a.arquivado FROM acompanhamento_mensagens m
                JOIN acompanhamentos a ON a.id = m.acompanhamento_id
                WHERE m.id = %s;
            """, (mensagem_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Mensagem não encontrada.")
            if row["arquivado"]:
                raise HTTPException(status_code=400, detail="Este acompanhamento pertence a um ano letivo encerrado e está em modo somente leitura.")
            if not pode_editar_mensagem(perfil, row["sigiloso"]):
                raise HTTPException(status_code=403, detail="Sem permissão para apagar esta mensagem.")

            cur.execute("DELETE FROM anexos_mensagem WHERE mensagem_id = %s;", (mensagem_id,))
            cur.execute("DELETE FROM acompanhamento_mensagens WHERE id = %s;", (mensagem_id,))
        conn.commit()

    registrar_log(usuario_resp, "Exclusão de Mensagem de Acompanhamento", f"Mensagem ID {mensagem_id}")
    return {"status": "sucesso"}


# ---------------------------------------------------------
# LOGS DE AUDITORIA
# ---------------------------------------------------------
@api_router.get("/logs")
def listar_logs(
    data_inicio: str | None = Query(None),
    data_fim: str | None = Query(None),
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            condicoes = []
            parametros = []
            if data_inicio:
                condicoes.append("data_hora >= %s")
                parametros.append(f"{_validar_data_iso(data_inicio)} 00:00:00")
            if data_fim:
                condicoes.append("data_hora <= %s")
                parametros.append(f"{_validar_data_iso(data_fim)} 23:59:59")

            where_clause = f"WHERE {' AND '.join(condicoes)}" if condicoes else ""
            cur.execute(f"SELECT * FROM logs_auditoria {where_clause} ORDER BY id DESC LIMIT 500;", parametros)
            return cur.fetchall()


def _validar_data_iso(valor) -> str:
    """Garante que o período recebido na URL é uma data AAAA-MM-DD (evita erro 500 e entradas estranhas)."""
    try:
        datetime.strptime(str(valor), "%Y-%m-%d")
    except ValueError:
        raise HTTPException(status_code=400, detail="Data inválida. Use o formato AAAA-MM-DD.")
    return str(valor)


def _buscar_logs_periodo(data_inicio, data_fim):
    data_inicio = _validar_data_iso(data_inicio)
    data_fim = _validar_data_iso(data_fim)
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT * FROM logs_auditoria
                WHERE data_hora >= %s AND data_hora <= %s
                ORDER BY id DESC;
            """, (f"{data_inicio} 00:00:00", f"{data_fim} 23:59:59"))
            return cur.fetchall()


@api_router.get("/logs/csv")
def exportar_logs_csv(
    data_inicio: str,
    data_fim: str,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    logs = _buscar_logs_periodo(data_inicio, data_fim)
    df = pd.DataFrame(logs)
    for coluna in df.columns:
        df[coluna] = df[coluna].map(lambda v: "'" + v if isinstance(v, str) and v[:1] in ("=", "+", "-", "@", "\t", "\r") else v)
    buffer = io.StringIO()
    df.to_csv(buffer, index=False)
    buffer.seek(0)
    return StreamingResponse(
        iter([buffer.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename=logs_auditoria_{data_inicio}_{data_fim}.csv"}
    )


@api_router.get("/logs/pdf")
def exportar_logs_pdf(
    data_inicio: str,
    data_fim: str,
    usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))
):
    usuario_solicitante = f"{usuario['nome']} ({usuario['usuario']})"
    logs = _buscar_logs_periodo(data_inicio, data_fim)
    cabecalho_pdf, rodape_pdf, logo_pdf, tamanho_logo_pdf = _obter_textos_pdf()

    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer, pagesize=landscape(letter),
        rightMargin=30, leftMargin=30,
        topMargin=max(55, tamanho_logo_pdf + 30) if (cabecalho_pdf or logo_pdf) else 30,
        bottomMargin=45 if rodape_pdf else 30
    )
    elements = []
    styles = getSampleStyleSheet()

    title_style = ParagraphStyle('DocTitle', parent=styles['Heading1'], fontName='Helvetica-Bold',
                                  fontSize=18, textColor=colors.HexColor("#4F46E5"), spaceAfter=6)
    subtitle_style = ParagraphStyle('DocSubtitle', parent=styles['Normal'], fontName='Helvetica',
                                     fontSize=9, textColor=colors.HexColor("#475569"), spaceAfter=15)
    style_cell = ParagraphStyle('CellText', parent=styles['Normal'], fontSize=8, fontName='Helvetica', leading=10)
    style_header = ParagraphStyle('HeaderStyle', parent=styles['Normal'], fontSize=9,
                                   fontName='Helvetica-Bold', textColor=colors.white)

    elements.append(Paragraph("Busca Ativa Escolar - Relatório de Auditoria", title_style))
    periodo_str = f"<b>Período:</b> {_t(data_inicio)} até {_t(data_fim)}"
    emissao_str = f"<b>Emissão:</b> {datetime.now(FUSO_RECIFE).strftime('%d/%m/%Y %H:%M:%S')} por {_t(usuario_solicitante)}"
    elements.append(Paragraph(f"{periodo_str} | {emissao_str}", subtitle_style))

    data = [["Data/Hora", "Usuário Responsável", "Ação / Evento", "Detalhes do Registro"]]
    data[0] = [Paragraph(col, style_header) for col in data[0]]

    for row in logs:
        data_hora_fmt = row["data_hora"].strftime("%d/%m/%Y %H:%M:%S") if row.get("data_hora") else ""
        data.append([
            Paragraph(data_hora_fmt, style_cell),
            Paragraph(_t(row.get("usuario", "")), style_cell),
            Paragraph(_t(row.get("acao", "")), style_cell),
            Paragraph(_t(row.get("detalhes", "")), style_cell),
        ])

    tabela = Table(data, colWidths=[110, 140, 150, 332], repeatRows=1)
    tabela.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor("#4F46E5")),
        ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
        ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
        ('VALIGN', (0, 0), (-1, -1), 'TOP'),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 5),
        ('TOPPADDING', (0, 0), (-1, -1), 5),
        ('GRID', (0, 0), (-1, -1), 0.5, colors.HexColor("#CBD5E1")),
        ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, colors.HexColor("#F8FAFC")]),
    ]))
    elements.append(tabela)
    callback_pagina = _callback_cabecalho_rodape(cabecalho_pdf, rodape_pdf, logo_pdf, tamanho_logo_pdf)
    doc.build(elements, onFirstPage=callback_pagina, onLaterPages=callback_pagina)
    buffer.seek(0)

    return StreamingResponse(
        buffer, media_type="application/pdf",
        headers={"Content-Disposition": f"attachment; filename=relatorio_auditoria_{data_inicio}_{data_fim}.pdf"}
    )


@api_router.delete("/logs")
def limpar_logs(usuario: dict = Depends(exigir_perfil("Administrador"))):
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM logs_auditoria;")
        conn.commit()
    return {"status": "sucesso"}


# ---------------------------------------------------------
# CONFIGURAÇÕES DO SISTEMA (WHITE-LABEL)
# ---------------------------------------------------------
def _cor_hex(valor, padrao):
    """Aceita apenas cores no formato #RRGGBB; qualquer outra coisa volta para o padrão."""
    v = str(valor or "").strip()
    return v if len(v) == 7 and v[0] == "#" and all(c in "0123456789abcdefABCDEF" for c in v[1:]) else padrao


def _decodificar_data_uri(data_uri):
    if not data_uri or "," not in data_uri:
        return None, None
    header, b64data = data_uri.split(",", 1)
    mime = "image/png"
    if header.startswith("data:") and ";base64" in header:
        mime = header[5:].split(";")[0] or "image/png"
    try:
        raw = base64.b64decode(b64data)
    except Exception:
        return None, None
    return mime, raw


@api_router.get("/config")
def obter_config():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id, titulo_login, subtitulo_login, titulo_interno,
                       cor_cabecalho, cor_menu, cor_texto_cabecalho, cor_destaque,
                       chat_bg_color, chat_bubble_sent, chat_bubble_received, chat_header_color,
                       rel_finalidade, rel_fund_ldb, rel_fund_eca, rel_fund_aplicacao, rel_prox_aberto,
                       rel_prox_fechado, rel_prox_arquivado, rel_orgao_resp, rel_unidade_resp,
                       (chat_bg_image IS NOT NULL) AS tem_chat_bg_image,
                       rodape_texto, modo_ordenacao_escolas,
                       cabecalho_pdf_texto, rodape_pdf_texto, tamanho_logo_pdf, modo_hora, data_hora_manual,
                       (logo_base64 IS NOT NULL) AS tem_logo,
                       (logo_pdf_base64 IS NOT NULL) AS tem_logo_pdf,
                       (imagem_fundo_login IS NOT NULL) AS tem_fundo_login
                FROM configuracoes_sistema WHERE id = 1;
            """)
            config = cur.fetchone()
            if config:
                config["agora_sistema"] = agora_sistema(cur).isoformat(timespec="seconds")
            return config


@api_router.get("/config/logo")
def obter_logo():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT logo_base64 FROM configuracoes_sistema WHERE id = 1;")
            row = cur.fetchone()

    mime, raw = _decodificar_data_uri(row["logo_base64"] if row else None)
    if not raw:
        raise HTTPException(status_code=404, detail="Logo não configurado.")
    return Response(content=raw, media_type=mime, headers={"Cache-Control": "public, max-age=3600"})


@api_router.get("/config/logo-pdf")
def obter_logo_pdf():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT logo_pdf_base64 FROM configuracoes_sistema WHERE id = 1;")
            row = cur.fetchone()

    mime, raw = _decodificar_data_uri(row["logo_pdf_base64"] if row else None)
    if not raw:
        raise HTTPException(status_code=404, detail="Logo do PDF não configurado.")
    return Response(content=raw, media_type=mime, headers={"Cache-Control": "public, max-age=3600"})


@api_router.get("/config/chat-bg")
def obter_chat_bg():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT chat_bg_image FROM configuracoes_sistema WHERE id = 1;")
            row = cur.fetchone()
    mime, raw = _decodificar_data_uri(row["chat_bg_image"] if row else None)
    if not raw:
        raise HTTPException(status_code=404, detail="Imagem de fundo do chat não configurada.")
    return Response(content=raw, media_type=mime, headers={"Cache-Control": "public, max-age=3600"})


@api_router.get("/config/fundo-login")
def obter_fundo_login():
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT imagem_fundo_login FROM configuracoes_sistema WHERE id = 1;")
            row = cur.fetchone()

    mime, raw = _decodificar_data_uri(row["imagem_fundo_login"] if row else None)
    if not raw:
        raise HTTPException(status_code=404, detail="Imagem de fundo não configurada.")
    return Response(content=raw, media_type=mime, headers={"Cache-Control": "public, max-age=3600"})


@api_router.post("/config")
def salvar_config(
    dados: ConfigSchema,
    usuario: dict = Depends(exigir_perfil("Administrador"))
):
    modo_hora = dados.modo_hora if dados.modo_hora in ("automatico", "manual") else "automatico"
    hora_manual, hora_manual_ref = None, None
    if modo_hora == "manual":
        hora_manual = _para_naive_recife(dados.data_hora_manual)
        if hora_manual is None:
            raise HTTPException(status_code=400, detail="Data/hora manual inválida.")
        hora_manual_ref = _agora_recife()

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE configuracoes_sistema
                SET titulo_login = %s, subtitulo_login = %s, titulo_interno = %s,
                    cor_cabecalho = %s, cor_menu = %s, cor_texto_cabecalho = %s, cor_destaque = %s,
                    chat_bg_color = %s, chat_bubble_sent = %s, chat_bubble_received = %s, chat_header_color = %s,
                    rel_finalidade = %s, rel_fund_ldb = %s, rel_fund_eca = %s, rel_fund_aplicacao = %s,
                    rel_prox_aberto = %s, rel_prox_fechado = %s, rel_prox_arquivado = %s,
                    rel_orgao_resp = %s, rel_unidade_resp = %s,
                    rodape_texto = %s, cabecalho_pdf_texto = %s, rodape_pdf_texto = %s,
                    tamanho_logo_pdf = %s, modo_hora = %s, data_hora_manual = %s, data_hora_manual_ref = %s
                WHERE id = 1;
            """, (dados.titulo_login, dados.subtitulo_login, dados.titulo_interno,
                  dados.cor_cabecalho, dados.cor_menu, dados.cor_texto_cabecalho, dados.cor_destaque,
                  _cor_hex(dados.chat_bg_color, "#e5ddd5"), _cor_hex(dados.chat_bubble_sent, "#dcf8c6"),
                  _cor_hex(dados.chat_bubble_received, "#ffffff"), _cor_hex(dados.chat_header_color, "#075e54"),
                  dados.rel_finalidade, dados.rel_fund_ldb, dados.rel_fund_eca, dados.rel_fund_aplicacao,
                  dados.rel_prox_aberto, dados.rel_prox_fechado, dados.rel_prox_arquivado,
                  dados.rel_orgao_resp, dados.rel_unidade_resp,
                  dados.rodape_texto, dados.cabecalho_pdf_texto, dados.rodape_pdf_texto,
                  dados.tamanho_logo_pdf, modo_hora, hora_manual, hora_manual_ref))

            if dados.logo_base64:
                cur.execute("UPDATE configuracoes_sistema SET logo_base64 = %s WHERE id = 1;", (dados.logo_base64,))
            if dados.logo_pdf_base64:
                cur.execute("UPDATE configuracoes_sistema SET logo_pdf_base64 = %s WHERE id = 1;", (dados.logo_pdf_base64,))
            if dados.imagem_fundo_login:
                cur.execute("UPDATE configuracoes_sistema SET imagem_fundo_login = %s WHERE id = 1;", (dados.imagem_fundo_login,))
            if dados.chat_bg_image_remover:
                cur.execute("UPDATE configuracoes_sistema SET chat_bg_image = NULL WHERE id = 1;")
            elif dados.chat_bg_image_base64:
                if not dados.chat_bg_image_base64.startswith("data:image/") or len(dados.chat_bg_image_base64) > 4_000_000:
                    raise HTTPException(status_code=400, detail="A imagem de fundo do chat deve ser uma imagem de até 3 MB.")
                cur.execute("UPDATE configuracoes_sistema SET chat_bg_image = %s WHERE id = 1;", (dados.chat_bg_image_base64,))

        conn.commit()
    return {"status": "sucesso"}


# ---------------------------------------------------------
# ANO LETIVO (ENCERRAMENTO E SNAPSHOT)
# ---------------------------------------------------------
@api_router.get("/ano-letivo/arquivados")
def listar_anos_arquivados(usuario: dict = Depends(exigir_perfil("Gestor / Visualizador", "Coordenador de Acompanhamento", "Administrador"))):
    perfil = usuario["perfil"]
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT ano, fechado_em, fechado_por, casos_snapshot FROM anos_letivos ORDER BY ano DESC;")
            anos = cur.fetchall()

    ver_sigilosos = pode_ver_sigiloso(perfil)
    resultado = []
    for a in anos:
        casos = a["casos_snapshot"] or []
        if not ver_sigilosos:
            casos = [c for c in casos if not c.get("sigiloso")]
        resultado.append({
            "ano": a["ano"],
            "fechado_em": a["fechado_em"],
            "fechado_por": a["fechado_por"],
            "casos_snapshot": casos
        })
    return resultado


@api_router.post("/ano-letivo/fechar")
def fechar_ano_letivo(
    dados: FecharAnoLetivoSchema,
    usuario: dict = Depends(exigir_perfil("Administrador"))
):
    usuario_resp = f"{usuario['nome']} ({usuario['usuario']})"

    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM anos_letivos WHERE ano = %s;", (dados.ano,))
            if cur.fetchone():
                raise HTTPException(status_code=400, detail=f"O ano letivo {dados.ano} já foi encerrado anteriormente.")

            cur.execute("""
                SELECT ac.id, ac.motivo, ac.status, ac.sigiloso, ac.criado_em, ac.fechado_em,
                       al.nome AS aluno_nome, al.escola_origem, (al.foto IS NOT NULL) AS aluno_tem_foto,
                       (SELECT COUNT(*) FROM acompanhamento_mensagens m WHERE m.acompanhamento_id = ac.id) AS total_mensagens
                FROM acompanhamentos ac
                JOIN alunos al ON al.id = ac.aluno_id
                WHERE EXTRACT(YEAR FROM ac.criado_em) = %s AND ac.arquivado = FALSE;
            """, (dados.ano,))
            casos = cur.fetchall()

            ids = [c["id"] for c in casos]
            casos_snapshot = [{
                "id": c["id"],
                "aluno_nome": c["aluno_nome"],
                "escola_origem": c["escola_origem"],
                "motivo": c["motivo"],
                "status": c["status"],
                "sigiloso": c["sigiloso"],
                "criado_em": c["criado_em"].isoformat() if c["criado_em"] else None,
                "fechado_em": c["fechado_em"].isoformat() if c["fechado_em"] else None,
                "total_mensagens": c["total_mensagens"]
            } for c in casos]

            cur.execute(
                "INSERT INTO anos_letivos (ano, fechado_em, fechado_por, casos_snapshot) VALUES (%s, %s, %s, %s);",
                (dados.ano, agora_sistema(cur), usuario_resp, Json(casos_snapshot))
            )
            if ids:
                cur.execute("UPDATE acompanhamentos SET arquivado = TRUE WHERE id = ANY(%s);", (ids,))

        conn.commit()

    registrar_log(usuario_resp, "Encerramento de Ano Letivo", f"Ano {dados.ano} | {len(ids)} caso(s) arquivado(s).")
    return {"status": "sucesso", "casos_arquivados": len(ids)}


# Registra todas as rotas sob /api E /alunos/api para suporte total a subpaths de proxy reverso
app.include_router(api_router, prefix="/api")
app.include_router(api_router, prefix="/alunos/api")
EOF_BUSCA_ATIVA

echo "  - gravando app_alunos/backend/requirements.txt"
cat > 'app_alunos/backend/requirements.txt' << 'EOF_BUSCA_ATIVA'
fastapi
uvicorn
psycopg2-binary
pydantic
pandas
openpyxl
reportlab
python-multipart
tzdata
EOF_BUSCA_ATIVA

echo "  - gravando app_alunos/backend/Dockerfile"
cat > 'app_alunos/backend/Dockerfile' << 'EOF_BUSCA_ATIVA'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF_BUSCA_ATIVA

echo "  - gravando app_alunos/frontend/index.html"
cat > 'app_alunos/frontend/index.html' << 'EOF_BUSCA_ATIVA'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Busca Ativa Escolar</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.0/chart.umd.min.js"></script>
<link href="https://fonts.googleapis.com/css2?family=Sora:wght@600;700;800&family=Lexend:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
    :root { --accent: #2563eb; --chat-bg: #e5ddd5; --chat-bubble-sent: #dcf8c6; --chat-bubble-received: #ffffff; --chat-header: #075e54; --chat-input-bg: #f0f0f0; }
    * { box-sizing: border-box; font-family: 'Lexend', system-ui, sans-serif; }
    body { background: #e9edf3; margin: 0; color: #1e293b; }

    /* LOGIN */
    #loginScreen { display: flex; justify-content: center; align-items: center; height: 100vh; background: #0f172a; }
    .login-card { background: white; padding: 40px; border-radius: 12px; width: 360px; box-shadow: 0 10px 25px rgba(0,0,0,0.3); }
    .login-card h2 { text-align: center; margin-top: 0; font-family: 'Sora', sans-serif; }
    .login-card p { text-align: center; color: #64748b; font-size: 0.9rem; margin-top: -10px; }
    .login-card .custom-logo { max-height: 80px; max-width: 240px; object-fit: contain; display: block; margin: 0 auto 15px auto; }
    .erro-msg { color: #dc2626; font-size: 0.85rem; text-align: center; margin-top: 10px; }

    /* LAYOUT GERAL */
    header { background: #1e293b; color: white; padding: 15px 30px; display: flex; justify-content: space-between; align-items: center; }
    header .titulo-interno { display: flex; align-items: center; gap: 12px; }
    header .titulo-interno img { max-height: 40px; }
    .user-info { text-align: right; font-size: 0.85rem; }
    .user-info b { display: block; }

    .nav-tabs { display: flex; gap: 4px; background: #0f172a; padding: 0 30px; }
    .nav-tabs button { background: transparent; border: none; color: #94a3b8; padding: 14px 18px; cursor: pointer; font-size: 0.92rem; font-weight: 600; font-family: 'Lexend', sans-serif; border-bottom: 3px solid transparent; display: flex; align-items: center; gap: 8px; }
    .nav-tabs button.active { color: white; border-bottom-color: var(--accent); }
    .nav-tabs button svg { flex-shrink: 0; }

    .tab-content { display: none; padding: 30px; max-width: 1100px; margin: 0 auto; }
    .tab-content.active { display: block; }

    .container { background: white; border: 1px solid #e2e8f0; border-radius: 14px; padding: 32px; box-shadow: 0 1px 2px rgba(15,23,42,0.04), 0 6px 16px rgba(15,23,42,0.05); margin-bottom: 24px; }
    h2 { margin-top: 0; color: #0f172a; font-family: 'Sora', sans-serif; }

    .form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px 20px; }
    .full-width { grid-column: span 2; }
    .form-group { display: flex; flex-direction: column; gap: 6px; }
    label { font-size: 0.9rem; font-weight: 600; color: #334155; }
    input, select, textarea { width: 100%; padding: 10px 12px; border: 1px solid #cbd5e1; border-radius: 6px; font-size: 0.95rem; font-family: 'Lexend', sans-serif; }
    textarea { resize: vertical; min-height: 70px; }

    button.btn-primary { background: var(--accent); color: white; border: none; padding: 12px 20px; border-radius: 8px; font-weight: 600; font-family: 'Lexend', sans-serif; cursor: pointer; }
    button.btn-primary:hover { filter: brightness(0.9); }
    button.btn-danger { background: #dc2626; color: white; border: none; padding: 10px 16px; border-radius: 8px; font-weight: 600; font-family: 'Lexend', sans-serif; cursor: pointer; }
    button.btn-secondary { background: #f1f5f9; color: #1e293b; border: 1px solid #cbd5e1; padding: 10px 16px; border-radius: 8px; font-family: 'Lexend', sans-serif; cursor: pointer; }

    table { width: 100%; border-collapse: collapse; margin-top: 16px; font-size: 0.9rem; }
    th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid #e2e8f0; }
    th { background: #f8fafc; color: #475569; }
    tr:nth-child(even) { background: #f8fafc; }

    .kpi-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin-bottom: 24px; }
    .kpi-card { background: white; border: 1px solid #e2e8f0; border-radius: 14px; padding: 20px; box-shadow: 0 1px 2px rgba(15,23,42,0.04), 0 6px 16px rgba(15,23,42,0.05); display: flex; justify-content: space-between; align-items: center; }
    .kpi-title { font-size: 0.72rem; font-weight: 700; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.03em; }
    .kpi-value { font-size: 1.6rem; font-weight: 800; margin: 4px 0; font-family: 'Sora', sans-serif; color: #0f172a; }
    .kpi-icon { width: 46px; height: 46px; border-radius: 12px; display: flex; align-items: center; justify-content: center; background: #e0e7ff; color: #4f46e5; flex-shrink: 0; }

    .charts-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 24px; }

    .import-card { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 12px; padding: 20px; }
    .step-badge { display: inline-block; background: #e0e7ff; color: #4f46e5; font-size: 0.75rem; font-weight: 700; padding: 4px 10px; border-radius: 20px; margin-bottom: 10px; }

    .subtabs { display: flex; gap: 10px; margin-bottom: 20px; border-bottom: 1px solid #e2e8f0; }
    .subtabs button { background: none; border: none; padding: 10px 4px; margin-right: 20px; cursor: pointer; font-weight: 600; font-family: 'Lexend', sans-serif; color: #64748b; border-bottom: 3px solid transparent; }
    .subtabs button.active { color: var(--accent); border-bottom-color: var(--accent); }
    .subtab-content { display: none; }
    .subtab-content.active { display: block; }

    .alert { padding: 12px 16px; border-radius: 8px; margin-bottom: 16px; font-size: 0.9rem; }
    .alert-success { background: #d1fae5; color: #065f46; }
    .alert-error { background: #fee2e2; color: #991b1b; }
    .alert-warning { background: #fef3c7; color: #92400e; }

    .filtro-row { display: flex; gap: 12px; align-items: end; margin-bottom: 16px; flex-wrap: wrap; }
    .filtro-row .form-group { min-width: 160px; flex: 1; }

    .table-scroll { max-height: 440px; overflow-y: auto; overflow-x: scroll; border: 1px solid #e2e8f0; border-radius: 8px; margin-top: 16px; }
    .table-scroll table { margin-top: 0; min-width: 1000px; }
    .table-scroll thead th { position: sticky; top: 0; z-index: 1; background: #f8fafc; }

    /* CONSULTA E ACOMPANHAMENTO — estilo chamado */
    .ticket-header { background: white; border: 1px solid #e2e8f0; border-radius: 14px; padding: 22px 26px; box-shadow: 0 1px 2px rgba(15,23,42,0.04), 0 6px 16px rgba(15,23,42,0.05); display: flex; align-items: flex-start; justify-content: space-between; gap: 20px; flex-wrap: wrap; margin-bottom: 20px; }
    .ticket-layout { display: flex; gap: 20px; align-items: flex-start; flex-wrap: wrap; }
    .ticket-main { flex: 1; min-width: 320px; background: white; border: 1px solid #e2e8f0; border-radius: 14px; padding: 24px; box-shadow: 0 1px 2px rgba(15,23,42,0.04), 0 6px 16px rgba(15,23,42,0.05); display: flex; flex-direction: column; gap: 16px; }
    .ticket-sidebar { width: 300px; flex-shrink: 0; background: #f3f5f9; border: 1px solid #e2e8f0; border-radius: 14px; padding: 20px 22px; }
    .ticket-field { display: flex; flex-direction: column; gap: 2px; padding: 10px 0; border-bottom: 1px solid #e2e8f0; }
    .ticket-field:last-child { border-bottom: none; }
    .ticket-field-label { font-size: 11px; font-weight: 700; color: #64748b; text-transform: uppercase; letter-spacing: 0.04em; }
    .ticket-field-value { font-size: 13px; font-weight: 600; color: #0f172a; }
    .badge-pill { display: inline-flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 700; padding: 5px 11px; border-radius: 999px; }

    /* ====== MODAIS ====== */
    /* === MODAIS CENTRALIZADOS (Minha Conta, Reset Senha, Caso Arquivado) === */
    .modal-overlay { position: fixed; inset: 0; background: rgba(15,23,42,0.55); display: none; align-items: flex-start; justify-content: center; z-index: 9999; padding: 4vh 12px; overflow-y: auto; }
    .modal-box { background: #fff; border-radius: 16px; max-width: 860px; width: 100%; max-height: 92vh; overflow-y: auto; box-shadow: 0 20px 60px rgba(0,0,0,0.3); }
    .modal-header { padding: 20px 24px; border-bottom: 1px solid #e2e8f0; display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
    .modal-body { padding: 20px 24px 24px; }
    .modal-close-btn { margin-left: auto; background: #f1f5f9; border: none; border-radius: 8px; cursor: pointer; padding: 8px 14px; font-size: 0.85rem; font-weight: 600; color: #475569; }
    .modal-close-btn:hover { background: #e2e8f0; }
    .modal-minha-conta { max-width: 480px; }

    /* === PERFIL INLINE — substituição da view de consulta === */
    #painelConsultaView { display: block; }
    #painelPerfilInline { display: none; }
    .perfil-inline-voltar-bar {
        display: flex; align-items: center; gap: 16px;
        background: #fff; border-bottom: 1px solid #e2e8f0;
        padding: 14px 20px; margin-bottom: 20px;
        border-radius: 12px; box-shadow: 0 1px 4px rgba(15,23,42,0.06);
        flex-wrap: wrap;
    }
    .perfil-inline-info { flex: 1; min-width: 0; }
    .perfil-inline-info h2 { margin: 0; font-size: 1.1rem; font-family: 'Sora', sans-serif; color: #0f172a; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .perfil-inline-info p { margin: 3px 0 0; font-size: 0.82rem; color: #64748b; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .perfil-foto-actions { display: flex; gap: 8px; margin-top: 6px; flex-wrap: wrap; }
    .perfil-voltar-btn {
        flex-shrink: 0; background: #f1f5f9; border: none; border-radius: 8px;
        cursor: pointer; padding: 8px 14px; font-size: 0.85rem; font-weight: 600;
        color: #475569; display: flex; align-items: center; gap: 6px;
    }
    .perfil-voltar-btn:hover { background: #e2e8f0; }
    #painelPerfilAluno { padding: 0 0 32px; }
    .avatar-circle { border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: 700; flex-shrink: 0; }
    #avatarHeader { width: 38px; height: 38px; border-radius: 50%; cursor: pointer; border: 2px solid rgba(255,255,255,0.4); overflow: hidden; display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 14px; background: var(--accent); color: #fff; flex-shrink: 0; }
    #avatarHeader img { width: 100%; height: 100%; object-fit: cover; }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
/* === CHAT ESTILO WHATSAPP === */
.chat-window { display:flex; flex-direction:column; border-radius:14px; overflow:hidden; box-shadow:0 1px 2px rgba(15,23,42,0.04), 0 6px 16px rgba(15,23,42,0.08); min-height:500px; background:var(--chat-bg); flex:1; min-width:320px; }
.chat-header-bar { background:var(--chat-header); color:#fff; padding:10px 16px; display:flex; align-items:center; gap:12px; flex-shrink:0; }
.chat-header-bar .chat-header-info { flex:1; min-width:0; }
.chat-header-bar .chat-header-name { font-weight:700; font-size:1rem; margin:0; }
.chat-header-bar .chat-header-sub { font-size:0.78rem; opacity:0.85; margin:0; }
.chat-messages { flex:1; overflow-y:auto; padding:16px 12px; display:flex; flex-direction:column; gap:4px; background-color:var(--chat-bg); background-attachment:local; min-height:300px; max-height:480px; }
.chat-messages.tem-fundo-imagem { background-size:cover; background-position:center; background-repeat:repeat; }
.chat-date-divider { display:flex; justify-content:center; margin:8px 0; }
.chat-date-divider span { background:rgba(225,245,254,0.92); color:#546e7a; font-size:0.72rem; font-weight:600; padding:3px 10px; border-radius:8px; box-shadow:0 1px 2px rgba(0,0,0,0.1); }
.chat-bubble-wrap { display:flex; align-items:flex-end; gap:6px; margin-bottom:2px; max-width:80%; }
.chat-bubble-wrap.sent { align-self:flex-end; flex-direction:row-reverse; }
.chat-bubble-wrap.received { align-self:flex-start; }
.chat-bubble { padding:8px 10px 22px 10px; border-radius:8px; font-size:0.88rem; line-height:1.45; color:#1e293b; position:relative; box-shadow:0 1px 1px rgba(0,0,0,0.1); word-break:break-word; min-width:80px; }
.chat-bubble-wrap.sent .chat-bubble { background:var(--chat-bubble-sent); border-bottom-right-radius:2px; margin-right:8px; }
.chat-bubble-wrap.received .chat-bubble { background:var(--chat-bubble-received); border-bottom-left-radius:2px; margin-left:8px; }
.chat-bubble-wrap.sent .chat-bubble::after { content:''; position:absolute; bottom:0; right:-8px; border:8px solid transparent; border-left-color:var(--chat-bubble-sent); border-bottom:0; border-right:0; }
.chat-bubble-wrap.received .chat-bubble::after { content:''; position:absolute; bottom:0; left:-8px; border:8px solid transparent; border-right-color:var(--chat-bubble-received); border-bottom:0; border-left:0; }
.chat-bubble .bubble-sender { font-size:0.75rem; font-weight:700; color:#075e54; margin:0 0 3px 0; }
.chat-bubble .bubble-category { font-size:0.72rem; color:#64748b; margin:0 0 4px 0; }
.chat-bubble .bubble-text { margin:0; }
.chat-bubble .bubble-meta { position:absolute; bottom:4px; right:8px; font-size:0.68rem; color:#94a3b8; display:flex; align-items:center; gap:3px; white-space:nowrap; }
.chat-bubble-wrap.sent .bubble-meta { color:#4b6355; }
.bubble-encaminhamento { display:inline-flex; align-items:center; gap:5px; background:#fde68a; color:#92400e; padding:3px 8px; border-radius:6px; font-size:0.72rem; font-weight:700; margin-bottom:6px; }
.bubble-actions { display:none; gap:4px; margin-top:6px; }
.chat-bubble:hover .bubble-actions { display:flex; }
.bubble-actions button { background:rgba(0,0,0,0.06); border:none; border-radius:4px; padding:2px 7px; font-size:0.7rem; cursor:pointer; color:#475569; }
.bubble-actions .btn-del { color:#dc2626; }
.bubble-anexos { margin-top:6px; display:flex; flex-wrap:wrap; gap:4px; }
.bubble-anexos img { max-width:140px; max-height:140px; border-radius:6px; cursor:pointer; }
.chat-composer { background:var(--chat-input-bg); padding:8px 12px; display:flex; flex-direction:column; gap:8px; border-top:1px solid rgba(0,0,0,0.08); flex-shrink:0; }
.chat-composer-selects { display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
.chat-composer-selects select { flex:1; min-width:160px; height:36px; font-size:0.82rem; padding:0 10px; border-radius:20px; border:1px solid #e2e8f0; background:#fff; }
.chat-composer-encaminhamento { display:none; background:#fffbeb; border:1px solid #fde68a; border-radius:12px; padding:8px 12px; gap:8px; flex-direction:column; font-size:0.82rem; }
.chat-composer-encaminhamento select { height:34px; border-radius:20px; border:1px solid #e2e8f0; padding:0 10px; font-size:0.82rem; }
.chat-input-row { display:flex; align-items:flex-end; gap:8px; }
.chat-textarea { flex:1; border:none; border-radius:24px; background:#fff; padding:10px 16px; font-size:0.9rem; font-family:'Lexend', sans-serif; resize:none; min-height:42px; max-height:120px; box-shadow:0 1px 3px rgba(0,0,0,0.1); outline:none; overflow-y:auto; line-height:1.4; }
.chat-send-btn { width:44px; height:44px; border-radius:50%; background:#25d366; border:none; cursor:pointer; display:flex; align-items:center; justify-content:center; flex-shrink:0; box-shadow:0 2px 6px rgba(37,211,102,0.35); transition:background 0.2s; padding:0; }
.chat-send-btn:hover { background:#1da851; }
.chat-send-btn svg { stroke:#fff; }
.chat-file-label { width:36px; height:36px; border-radius:50%; background:rgba(0,0,0,0.07); display:flex; align-items:center; justify-content:center; cursor:pointer; flex-shrink:0; color:#64748b; transition:background 0.2s; margin-bottom:4px; }
.chat-file-label:hover { background:rgba(0,0,0,0.13); }
#novaMsgAnexos { display:none; }
.chat-file-preview { display:flex; flex-wrap:wrap; gap:6px; padding:0 4px; }
.chat-file-preview:empty { display:none; }
.chat-file-preview .file-chip { display:inline-flex; align-items:center; gap:5px; background:rgba(0,0,0,0.06); border-radius:20px; padding:3px 10px; font-size:0.78rem; color:#334155; }
.chat-file-preview .file-chip button { background:none; border:none; cursor:pointer; color:#dc2626; font-size:0.85rem; padding:0 2px; line-height:1; }
.chat-readonly-banner { background:#fef3c7; color:#92400e; text-align:center; font-size:0.82rem; font-weight:600; padding:8px 16px; border-top:1px solid #fde68a; }
/* === FIM CHAT WHATSAPP === */
</style>
</head>
<body>

<!-- ===================== TELA DE LOGIN ===================== -->
<div id="loginScreen" style="display:none;">
    <div class="login-card">
        <img id="logoLogin" class="custom-logo" style="display:none;">
        <div id="iconeLogin" style="text-align:center; font-size:50px;">🏫</div>
        <h2 id="tituloLogin">Sistema de Gestão Escolar</h2>
        <p id="subtituloLogin">Acesse com suas credenciais para continuar</p>
        <div class="form-group">
            <label>Usuário</label>
            <input type="text" id="loginUsuario">
        </div>
        <div class="form-group" style="margin-top:12px;">
            <label>Senha</label>
            <div style="position:relative;">
                <input type="password" id="loginSenha" style="padding-right:40px;">
                <span onclick="toggleSenhaLogin()" style="position:absolute; right:10px; top:50%; transform:translateY(-50%); cursor:pointer; font-size:1.1rem;" title="Mostrar/ocultar senha">👁</span>
            </div>
        </div>
        <button class="btn-primary" style="width:100%; margin-top:20px;" onclick="fazerLogin()">🔒 Entrar no Sistema</button>
        <div class="erro-msg" id="loginErro"></div>
    </div>
</div>

<!-- ===================== APP PRINCIPAL ===================== -->
<div id="appScreen" style="display:none;">
    <header>
        <div class="titulo-interno">
            <img id="logoInterno" style="display:none;">
            <h2 id="tituloInterno" style="margin:0;">Busca Ativa Escolar & Gestão</h2>
        </div>
        <div style="display:flex; align-items:center; gap:12px;">
            <div class="user-info">
                <b id="userNome"></b>
                <span id="userPerfil"></span>
                &nbsp;·&nbsp;<a href="#" onclick="logout()" style="color:#93c5fd;">Sair</a>
            </div>
            <div id="avatarHeader" onclick="abrirMinhaConta()" title="Minha Conta"></div>
        </div>
    </header>

    <div class="nav-tabs" id="navTabs">
        <button data-tab="cadastro" class="active" onclick="mudarTab('cadastro')">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><path d="M14 2v6h6"></path><line x1="8" y1="13" x2="16" y2="13"></line><line x1="8" y1="17" x2="16" y2="17"></line></svg>
            Cadastro de Alunos
        </button>
        <button data-tab="dashboard" id="btnTabDashboard" onclick="mudarTab('dashboard')">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><line x1="12" y1="20" x2="12" y2="10"></line><line x1="18" y1="20" x2="18" y2="4"></line><line x1="6" y1="20" x2="6" y2="16"></line></svg>
            Dashboard Geral
        </button>
        <button data-tab="consulta" id="btnTabConsulta" onclick="mudarTab('consulta')">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
            Consulta e Acompanhamento
        </button>
        <button data-tab="config" id="btnTabConfig" onclick="mudarTab('config')" style="display:none;">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
            Configurações & Usuários
        </button>
    </div>

    <!-- ===== TAB CADASTRO ===== -->
    <div class="tab-content active" id="tab-cadastro">
        <div class="container">
            <h2>📝 Cadastro Individual de Aluno</h2>
            <div id="cadastroAlerta"></div>
            <form id="formAluno" class="form-grid" onsubmit="salvarAluno(event)">
                <div class="form-group">
                    <label>Nome Completo*</label>
                    <input type="text" id="f_nome" required>
                </div>
                <div class="form-group">
                    <label>CPF*</label>
                    <input type="text" id="f_cpf" placeholder="000.000.000-00" required>
                </div>
                <div class="form-group">
                    <label>Data de Nascimento*</label>
                    <input type="date" id="f_data_nasc" required>
                </div>
                <div class="form-group">
                    <label>Tipo de Busca*</label>
                    <select id="f_tipo_busca" required>
                        <option value="Busca Ativa">Busca Ativa</option>
                        <option value="Sistema Presença">Sistema Presença</option>
                    </select>
                </div>
                <div class="form-group">
                    <label>Escola de Origem*</label>
                    <select id="f_escola_origem" required></select>
                </div>
                <div class="form-group">
                    <label>Turma*</label>
                    <input type="text" id="f_turma" placeholder="Ex: 5º Ano A" required>
                </div>
                <div class="form-group full-width">
                    <label>Endereço Completo*</label>
                    <input type="text" id="f_endereco" required>
                </div>
                <div class="form-group full-width">
                    <label>Observações</label>
                    <textarea id="f_observacoes"></textarea>
                </div>
                <button type="submit" class="btn-primary full-width">💾 Salvar Cadastro</button>
            </form>
        </div>

        <div class="container">
            <h2>📥 Importação de Alunos em Lote</h2>
            <div style="display:grid; grid-template-columns:1fr 1fr; gap:20px;">
                <div class="import-card">
                    <span class="step-badge">Passo 1</span>
                    <div style="font-weight:bold;">📄 Baixar Planilha Modelo</div>
                    <p style="color:#64748b; font-size:0.85rem;">Baixe o modelo oficial para preencher as informações.</p>
                    <button class="btn-secondary" style="width:100%;" onclick="baixarArquivo('alunos/modelo')">Baixar Modelo (.xlsx)</button>
                </div>
                <div class="import-card">
                    <span class="step-badge" style="background:#d1fae5; color:#059669;">Passo 2</span>
                    <div style="font-weight:bold;">📤 Upload da Planilha</div>
                    <input type="file" id="arquivoLoteAlunos" accept=".xlsx,.csv" style="margin-top:10px;">
                    <button class="btn-primary" style="width:100%; margin-top:10px;" onclick="importarLoteAlunos()">🚀 Importar Registros</button>
                </div>
            </div>
            <div id="importAlertaAlunos"></div>
        </div>
    </div>

    <!-- ===== TAB DASHBOARD ===== -->
    <div class="tab-content" id="tab-dashboard">
        <div class="kpi-grid">
            <div class="kpi-card"><div><div class="kpi-title">Total de Alunos</div><div class="kpi-value" id="kpiTotal">-</div></div><div class="kpi-icon">👥</div></div>
            <div class="kpi-card"><div><div class="kpi-title">Escolas Ativas</div><div class="kpi-value" id="kpiEscolas">-</div></div><div class="kpi-icon">🏫</div></div>
            <div class="kpi-card"><div><div class="kpi-title">Média de Idade</div><div class="kpi-value" id="kpiIdade">-</div></div><div class="kpi-icon">🎂</div></div>
        </div>

        <div class="charts-grid">
            <div class="container"><canvas id="chartEscolas"></canvas></div>
            <div class="container"><canvas id="chartTipoBusca"></canvas></div>
        </div>

        <div class="container">
            <h2>📋 Painel de Acompanhamento</h2>
            <div class="kpi-grid">
                <div class="kpi-card"><div><div class="kpi-title">Casos Abertos</div><div class="kpi-value" id="kpiCasosAbertos">-</div></div><div class="kpi-icon" style="background:#fee2e2; color:#dc2626;">🔴</div></div>
                <div class="kpi-card"><div><div class="kpi-title">Casos Atrasados</div><div class="kpi-value" id="kpiCasosAtrasados">-</div></div><div class="kpi-icon" style="background:#fef3c7; color:#f59e0b;">⏰</div></div>
                <div class="kpi-card"><div><div class="kpi-title">Tempo Médio p/ Fechar</div><div class="kpi-value" id="kpiTempoMedio">-</div></div><div class="kpi-icon" style="background:#e0e7ff; color:#4f46e5;">⏱️</div></div>
            </div>
            <div style="max-width:460px; margin:0 auto;">
                <canvas id="chartUrgencia"></canvas>
            </div>
        </div>

        <div class="container">
            <h2>📊 Tabela Completa de Alunos</h2>
            <div style="display:flex; gap:10px; margin-bottom:16px;">
                <button class="btn-secondary" onclick="baixarArquivo('alunos/export')">📥 Baixar Base Completa (.xlsx)</button>
                <button class="btn-danger" id="btnAbrirExclusao" onclick="toggleExclusao()">🗑️ Excluir Toda a Base</button>
            </div>
            <div id="painelExclusao" style="display:none;" class="import-card">
                <p style="color:#991b1b;"><b>⚠️ ATENÇÃO:</b> Esta ação é irreversível e excluirá todos os registros!</p>
                <label><input type="checkbox" id="chkEtapa1" onchange="document.getElementById('etapa2').style.display = this.checked ? 'block' : 'none'"> Etapa 1: Entendo os riscos e quero prosseguir</label>
                <div id="etapa2" style="display:none; margin-top:12px;">
                    <label>Etapa 2: Digite "DELETAR" em maiúsculas para confirmar</label>
                    <input type="text" id="txtDeletar" style="max-width:250px;">
                    <button class="btn-danger" style="margin-top:10px;" onclick="excluirTodosAlunos()">💥 Confirmar Exclusão Permanente</button>
                </div>
            </div>
            <div id="dashboardAlerta"></div>
            <div class="table-scroll">
                <table>
                    <thead><tr><th>Nome</th><th>CPF</th><th>Nascimento</th><th>Escola</th><th>Turma</th><th>Tipo</th><th>Endereço</th><th>Observações</th><th></th></tr></thead>
                    <tbody id="tabelaAlunosDashboard"></tbody>
                </table>
            </div>
        </div>

        <div class="container" id="cardLogsAuditoria">
            <h2>🛡️ Histórico e Logs de Auditoria</h2>
            <div class="filtro-row">
                <div class="form-group"><label>Data Inicial</label><input type="date" id="logDataInicio"></div>
                <div class="form-group"><label>Data Final</label><input type="date" id="logDataFim"></div>
                <button class="btn-secondary" onclick="carregarLogs()">Filtrar</button>
            </div>
            <div class="table-scroll">
                <table>
                    <thead><tr><th>Data/Hora</th><th>Usuário</th><th>Ação</th><th>Detalhes</th></tr></thead>
                    <tbody id="tabelaLogs"></tbody>
                </table>
            </div>
            <div style="display:flex; gap:10px; margin-top:16px;">
                <button class="btn-secondary" onclick="exportarLogsPdf()">📄 Baixar PDF</button>
                <button class="btn-secondary" onclick="exportarLogsCsv()">📥 Exportar CSV</button>
                <button class="btn-danger" id="btnLimparLogs" style="display:none;" onclick="limparLogs()">🗑️ Limpar Logs</button>
            </div>
        </div>
    </div>

    <!-- ===== TAB CONSULTA E ACOMPANHAMENTO ===== -->
    <div class="tab-content" id="tab-consulta">

        <!-- VIEW PADRÃO: KPIs + Busca -->
        <div id="painelConsultaView">
            <div class="container">
                <h2 style="display:flex; align-items:center; gap:10px;">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" width="22" height="22"><circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
                    Consulta e Acompanhamento
                </h2>
                <div style="display:flex; gap:16px; margin-bottom:20px; flex-wrap:wrap; align-items:center;">
                    <div class="kpi-card" style="cursor:pointer; flex:1; min-width:180px;" onclick="abrirPainelAbertos()">
                        <div><div class="kpi-title">Casos Abertos</div><div class="kpi-value" id="qtdAbertos">-</div></div>
                        <div class="kpi-icon" style="background:#fee2e2; color:#dc2626;">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="22" height="22"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="8" x2="12" y2="12"></line><circle cx="12" cy="16" r="0.5" fill="currentColor"></circle></svg>
                        </div>
                    </div>
                    <div class="kpi-card" style="cursor:pointer; flex:1; min-width:180px;" onclick="abrirPainelAtrasados()">
                        <div><div class="kpi-title">Casos Atrasados</div><div class="kpi-value" id="qtdAtrasados">-</div></div>
                        <div class="kpi-icon" style="background:#fef3c7; color:#d97706;">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="22" height="22"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
                        </div>
                    </div>
                    <div class="kpi-card" style="cursor:pointer; flex:1; min-width:180px;" onclick="abrirPainelFechados()">
                        <div><div class="kpi-title">Casos Fechados</div><div class="kpi-value" id="qtdFechados">-</div></div>
                        <div class="kpi-icon" style="background:#d1fae5; color:#059669;">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="22" height="22"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline></svg>
                        </div>
                    </div>
                    <button class="btn-secondary" onclick="exportarCasosAbertos()">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="14" height="14" style="vertical-align:-2px; margin-right:6px;"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
                        Exportar Casos Abertos (.xlsx)
                    </button>
                </div>
            </div>

            <div class="container">
                <h2 style="display:flex; align-items:center; gap:10px; font-size:1.15rem;">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" width="20" height="20"><circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
                    Buscar Aluno
                </h2>
                <div class="form-group full-width">
                    <label>Nome ou CPF</label>
                    <input type="text" id="buscaAlunoInput" placeholder="Digite pelo menos 2 letras..." oninput="buscarAlunos(this.value)">
                </div>
                <div id="resultadoBuscaAlunos" style="margin-top:10px;"></div>
            </div>

            <div class="container" id="painelListaCasos" style="display:none;">
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:16px;">
                    <h2 id="tituloListaCasos" style="margin:0;">Casos Abertos</h2>
                    <button class="btn-secondary" onclick="fecharPainelListaCasos()">Fechar</button>
                </div>
                <div id="listaCasosCards" style="display:flex; flex-direction:column; gap:10px;"></div>
            </div>
        </div><!-- fim #painelConsultaView -->

        <!-- VIEW PERFIL DO ALUNO (inline, substitui a view de consulta) -->
        <div id="painelPerfilInline" style="display:none;">
            <!-- Barra de cabeçalho com Voltar + foto + nome -->
            <div class="perfil-inline-voltar-bar">
                <button class="perfil-voltar-btn" onclick="fecharPainelPerfilAluno()">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" width="16" height="16"><line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/></svg>
                    Voltar
                </button>
                <div style="position:relative; flex-shrink:0;">
                    <img id="fotoAlunoPerfil" style="width:60px; height:60px; border-radius:50%; object-fit:cover; display:none;">
                    <div id="iconeAlunoPerfil" style="width:60px; height:60px; border-radius:50%; background:#e2e8f0; display:flex; align-items:center; justify-content:center; color:#94a3b8;">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" width="28" height="28"><circle cx="12" cy="8" r="4"></circle><path d="M4 20c0-4.4 3.6-8 8-8s8 3.6 8 8"></path></svg>
                    </div>
                </div>
                <div class="perfil-inline-info">
                    <h2 id="nomeAlunoPerfil"></h2>
                    <p id="infoAlunoPerfil"></p>
                    <div class="perfil-foto-actions">
                        <label class="btn-secondary" style="display:inline-flex; align-items:center; gap:5px; padding:5px 12px; font-size:0.78rem; cursor:pointer;">
                            📷 Trocar Foto
                            <input type="file" id="inputFotoAluno" accept="image/*" style="display:none;" onchange="enviarFotoAluno()">
                        </label>
                        <button id="btnExcluirFoto" class="btn-danger" style="padding:5px 12px; font-size:0.78rem; display:none;" onclick="excluirFotoAluno()">Excluir Foto</button>
                    </div>
                </div>
            </div>
            <!-- Corpo do perfil -->
            <div id="painelPerfilAluno">
                <div id="alertaPerfilAluno"></div>
                <div id="casoAtualContainer"></div>
                <div id="historicoCasosContainer" style="margin-top:24px;"></div>
            </div>
        </div><!-- fim #painelPerfilInline -->

    </div>

    <!-- ===== TAB CONFIG & USUÁRIOS ===== -->
    <div class="tab-content" id="tab-config">
        <div class="subtabs">
            <button class="active" data-sub="usuarios" onclick="mudarSubtab('usuarios')">👥 Usuários</button>
            <button data-sub="visual" onclick="mudarSubtab('visual')">🎨 Personalização</button>
            <button data-sub="anoletivo" onclick="mudarSubtab('anoletivo')">📅 Ano Letivo</button>
        </div>

        <div class="subtab-content active" id="sub-usuarios">
            <div class="container">
                <h2>➕ Cadastrar Novo Usuário</h2>
                <div id="usuarioAlerta"></div>
                <div class="form-grid">
                    <div class="form-group"><label>Nome Completo</label><input type="text" id="u_nome"></div>
                    <div class="form-group"><label>Nome de Usuário (Login)</label><input type="text" id="u_usuario"></div>
                    <div class="form-group"><label>Senha</label><input type="password" id="u_senha"></div>
                    <div class="form-group">
                        <label>Perfil de Acesso</label>
                        <select id="u_perfil">
                            <option>Usuário Comum</option>
                            <option>Gestor / Visualizador</option>
                            <option>Coordenador de Acompanhamento</option>
                            <option>Administrador</option>
                        </select>
                    </div>
                </div>
                <button class="btn-primary" style="margin-top:16px;" onclick="criarUsuario()">💾 Cadastrar Usuário</button>
            </div>

            <div class="container">
                <h2>👥 Usuários Cadastrados</h2>
                <table>
                    <thead><tr><th>Usuário</th><th>Nome</th><th>Perfil</th><th>Ações</th></tr></thead>
                    <tbody id="tabelaUsuarios"></tbody>
                </table>
            </div>

            <div class="container">
                <h2>📥 Importar Usuários em Lote</h2>
                <button class="btn-secondary" onclick="baixarArquivo('usuarios/modelo')">Baixar Modelo (.xlsx)</button>
                <input type="file" id="arquivoLoteUsuarios" accept=".xlsx,.csv" style="margin-top:10px; display:block;">
                <button class="btn-primary" style="margin-top:10px;" onclick="importarLoteUsuarios()">🚀 Confirmar Importação</button>
                <div id="importAlertaUsuarios"></div>
            </div>
        </div>

        <div class="subtab-content" id="sub-visual">
            <div class="container">
                <h2>🎨 Alterar Títulos e Logotipo</h2>
                <div id="configAlerta"></div>
                <div class="form-grid">
                    <div class="form-group"><label>Título da Tela de Login</label><input type="text" id="c_titulo_login"></div>
                    <div class="form-group"><label>Subtítulo da Tela de Login</label><input type="text" id="c_subtitulo_login"></div>
                    <div class="form-group full-width"><label>Título do Cabeçalho Interno</label><input type="text" id="c_titulo_interno"></div>
                    <div class="form-group full-width"><label>Logotipo (PNG/JPG)</label><input type="file" id="c_logo" accept="image/*"></div>
                    <div class="form-group"><label>Cor do Cabeçalho</label><input type="color" id="c_cor_cabecalho" style="height:42px; padding:4px;"></div>
                    <div class="form-group"><label>Cor do Menu</label><input type="color" id="c_cor_menu" style="height:42px; padding:4px;"></div>
                    <div class="form-group"><label>Cor do Texto do Cabeçalho</label><input type="color" id="c_cor_texto_cabecalho" style="height:42px; padding:4px;"></div>
                    <div class="form-group"><label>Cor de Destaque (botões e aba ativa)</label><input type="color" id="c_cor_destaque" style="height:42px; padding:4px;"></div>
                    <div class="form-group full-width" style="border-top:1px solid #e2e8f0; padding-top:12px; margin-top:4px;">
                        <label style="font-weight:700; color:#475569; font-size:0.8rem; letter-spacing:0.05em; text-transform:uppercase;">🕐 Data e Hora</label>
                    </div>
                    <div class="form-group full-width">
                        <label>Modo de Data e Hora</label>
                        <div style="display:flex; gap:12px; flex-wrap:wrap; align-items:center; margin-top:4px;">
                            <label style="display:flex; align-items:center; gap:6px; font-weight:400; cursor:pointer;">
                                <input type="radio" name="modoHora" id="c_hora_auto" value="automatico" onchange="toggleModoHora()" style="width:auto;" checked> Automático (relógio do sistema)
                            </label>
                            <label style="display:flex; align-items:center; gap:6px; font-weight:400; cursor:pointer;">
                                <input type="radio" name="modoHora" id="c_hora_manual" value="manual" onchange="toggleModoHora()" style="width:auto;"> Definir manualmente
                            </label>
                        </div>
                    </div>
                    <div class="form-group full-width" id="painelHoraManual" style="display:none;">
                        <label>Data e Hora Manual</label>
                        <div style="display:flex; gap:8px; flex-wrap:wrap; align-items:center; margin-top:4px;">
                            <div style="display:flex; flex-direction:column; gap:3px; align-items:center;"><span style="font-size:0.72rem; color:#64748b;">Dia</span><input type="number" id="c_hora_dia" min="1" max="31" placeholder="DD" style="width:64px; text-align:center; padding:8px 4px;"></div>
                            <span style="font-size:1.2rem; font-weight:700; color:#94a3b8; margin-top:18px;">/</span>
                            <div style="display:flex; flex-direction:column; gap:3px; align-items:center;"><span style="font-size:0.72rem; color:#64748b;">Mês</span><input type="number" id="c_hora_mes" min="1" max="12" placeholder="MM" style="width:64px; text-align:center; padding:8px 4px;"></div>
                            <span style="font-size:1.2rem; font-weight:700; color:#94a3b8; margin-top:18px;">/</span>
                            <div style="display:flex; flex-direction:column; gap:3px; align-items:center;"><span style="font-size:0.72rem; color:#64748b;">Ano</span><input type="number" id="c_hora_ano" min="2020" max="2099" placeholder="AAAA" style="width:86px; text-align:center; padding:8px 4px;"></div>
                            <span style="width:12px;"></span>
                            <div style="display:flex; flex-direction:column; gap:3px; align-items:center;"><span style="font-size:0.72rem; color:#64748b;">Hora</span><input type="number" id="c_hora_hh" min="0" max="23" placeholder="HH" style="width:64px; text-align:center; padding:8px 4px;"></div>
                            <span style="font-size:1.2rem; font-weight:700; color:#94a3b8; margin-top:18px;">:</span>
                            <div style="display:flex; flex-direction:column; gap:3px; align-items:center;"><span style="font-size:0.72rem; color:#64748b;">Minuto</span><input type="number" id="c_hora_mm" min="0" max="59" placeholder="MM" style="width:64px; text-align:center; padding:8px 4px;"></div>
                        </div>
                        <p style="margin:8px 0 0; font-size:0.8rem; color:#64748b;">⚡ Novos registros (mensagens, casos, fechamento de ano) usarão esta data/hora como referência.</p>
                    </div>
                    <div class="form-group full-width"><label>Imagem de Fundo da Tela de Login</label><input type="file" id="c_fundo_login" accept="image/*"></div>
                    <div class="form-group full-width"><label>Texto do Rodapé (uma linha por parágrafo)</label><textarea id="c_rodape_texto" rows="3"></textarea></div>
                </div>
                <button class="btn-primary" style="margin-top:16px;" onclick="salvarConfig()">💾 Salvar Personalização</button>
            </div>

            <div class="container">
                <h2>📄 Personalizar Relatórios em PDF</h2>
                <p style="color:#64748b; font-size:0.85rem; margin-top:-8px;">Esse texto aparece no topo e no rodapé de todo relatório em PDF gerado pelo sistema (acompanhamento e auditoria). Deixe em branco para não exibir.</p>
                <div class="form-grid">
                    <div class="form-group"><label>Logotipo para o PDF (PNG/JPG)</label><input type="file" id="c_logo_pdf" accept="image/*" onchange="previewLogoPdf(this)"></div>
                    <div class="form-group"><label>Tamanho da Imagem no Cabeçalho</label>
                        <select id="c_tamanho_logo_pdf" style="height:42px;">
                            <option value="40">Pequeno (40px)</option>
                            <option value="60" selected>Médio (60px)</option>
                            <option value="90">Grande (90px)</option>
                            <option value="120">Muito Grande (120px)</option>
                        </select>
                    </div>
                    <div class="form-group full-width" id="previewLogoPdfBox" style="display:none;">
                        <label>Pré-visualização</label>
                        <img id="previewLogoPdf" style="max-height:120px; max-width:300px; object-fit:contain; border:1px solid #e2e8f0; border-radius:8px; padding:4px;">
                    </div>
                    <div class="form-group full-width"><label>Cabeçalho do Relatório PDF</label><input type="text" id="c_cabecalho_pdf_texto" placeholder="Ex: Secretaria de Educação de Goiana - PE — Documento Confidencial"></div>
                    <div class="form-group full-width"><label>Rodapé do Relatório PDF</label><input type="text" id="c_rodape_pdf_texto" placeholder="Ex: Gerado pelo Sistema de Busca Ativa Escolar"></div>
                </div>
                <button class="btn-primary" style="margin-top:16px;" onclick="salvarConfig()">💾 Salvar Personalização</button>
            </div>

            <div class="container">
                <h2>📝 Modelo do Relatório de Acompanhamento</h2>
                <p style="color:#64748b; font-size:0.85rem; margin-top:-8px;">Edite os textos institucionais que aparecem no corpo do relatório PDF. Deixe em branco para usar o texto padrão do sistema.</p>
                <div id="modeloRelatorioAlerta"></div>

                <div style="border-top:2px solid #e2e8f0; margin:16px 0 10px; padding-top:10px;">
                    <p style="font-weight:700; color:#1e3a5f; margin:0 0 12px;">📌 Seção 6 — Finalidade do Procedimento</p>
                    <p style="color:#64748b; font-size:0.78rem; margin:-8px 0 8px;">Separe parágrafos com uma linha em branco. O texto será exibido no relatório conforme digitado.</p>
                    <div class="form-group full-width"><textarea id="c_rel_finalidade" rows="8" style="font-size:0.83rem; line-height:1.5;"></textarea></div>
                </div>

                <div style="border-top:1px solid #e2e8f0; margin:10px 0; padding-top:10px;">
                    <p style="font-weight:700; color:#1e3a5f; margin:0 0 10px;">⚖️ Seção 7 — Fundamento Legal</p>
                    <div class="form-grid">
                        <div class="form-group full-width"><label>7.1 – Lei nº 9.394/1996 (LDB — Art. 12, VIII)</label><textarea id="c_rel_fund_ldb" rows="3" style="font-size:0.83rem;"></textarea></div>
                        <div class="form-group full-width"><label>7.2 – Lei nº 8.069/1990 (ECA — Art. 56, II)</label><textarea id="c_rel_fund_eca" rows="3" style="font-size:0.83rem;"></textarea></div>
                        <div class="form-group full-width"><label>7.3 – Aplicação Institucional</label><textarea id="c_rel_fund_aplicacao" rows="3" style="font-size:0.83rem;"></textarea></div>
                    </div>
                </div>

                <div style="border-top:1px solid #e2e8f0; margin:10px 0; padding-top:10px;">
                    <p style="font-weight:700; color:#1e3a5f; margin:0 0 10px;">🔜 Seção 5.3 — Próximas Providências</p>
                    <div class="form-grid">
                        <div class="form-group full-width"><label>Texto quando o caso está <b>em aberto</b></label><input type="text" id="c_rel_prox_aberto"></div>
                        <div class="form-group full-width"><label>Texto quando o caso está <b>concluído (fechado)</b></label><input type="text" id="c_rel_prox_fechado"></div>
                        <div class="form-group full-width"><label>Texto quando o caso está <b>arquivado</b></label><input type="text" id="c_rel_prox_arquivado"></div>
                    </div>
                </div>

                <div style="border-top:1px solid #e2e8f0; margin:10px 0; padding-top:10px;">
                    <p style="font-weight:700; color:#1e3a5f; margin:0 0 10px;">🏛️ Seção 10 — Responsabilidade pelo Registro</p>
                    <div class="form-grid">
                        <div class="form-group full-width"><label>Órgão responsável pelo acompanhamento</label><input type="text" id="c_rel_orgao_resp" placeholder="Ex: Secretaria de Educação — Prefeitura Municipal de Goiana"></div>
                        <div class="form-group full-width"><label>Unidade / Setor responsável</label><input type="text" id="c_rel_unidade_resp" placeholder="Ex: Coordenação de Acompanhamento e Busca Ativa Escolar"></div>
                    </div>
                </div>

                <button class="btn-primary" style="margin-top:16px;" onclick="salvarConfig()">💾 Salvar Modelo do Relatório</button>
            </div>

            <div class="container">
                <h2>💬 Personalizar Chat de Acompanhamento</h2>
                <p style="color:#64748b; font-size:0.85rem; margin-top:-8px;">Personalize o visual do chat de acompanhamento de casos. As mudanças são salvas junto com a personalização do sistema.</p>
                <div class="form-grid">
                    <div class="form-group">
                        <label>Cor de Fundo do Chat</label>
                        <input type="color" id="c_chat_bg_color" value="#e5ddd5" style="height:42px; padding:4px;">
                    </div>
                    <div class="form-group">
                        <label>Cor das Mensagens Enviadas</label>
                        <input type="color" id="c_chat_bubble_sent" value="#dcf8c6" style="height:42px; padding:4px;">
                    </div>
                    <div class="form-group">
                        <label>Cor das Mensagens Recebidas</label>
                        <input type="color" id="c_chat_bubble_received" value="#ffffff" style="height:42px; padding:4px;">
                    </div>
                    <div class="form-group">
                        <label>Cor da Barra de Cabeçalho do Chat</label>
                        <input type="color" id="c_chat_header_color" value="#075e54" style="height:42px; padding:4px;">
                    </div>
                    <div class="form-group full-width">
                        <label>Imagem de Fundo do Chat (PNG/JPG)</label>
                        <input type="file" id="c_chat_bg_image" accept="image/*" onchange="previewChatBg(this)">
                    </div>
                    <div class="form-group full-width" id="previewChatBgBox" style="display:none;">
                        <label>Pré-visualização da imagem de fundo</label>
                        <img id="previewChatBgImg" style="max-height:120px; max-width:300px; object-fit:cover; border:1px solid #e2e8f0; border-radius:8px;">
                    </div>
                    <div class="form-group full-width">
                        <label style="display:flex; align-items:center; gap:8px;">
                            <input type="checkbox" id="c_chat_bg_image_remover" style="width:auto;"> Remover imagem de fundo atual do chat
                        </label>
                    </div>
                </div>
                <div style="margin-top:12px;">
                    <div style="border-radius:14px; overflow:hidden; max-width:460px; box-shadow:0 2px 8px rgba(0,0,0,0.12);">
                        <div id="chatPreviewHeader" style="background:#075e54; color:#fff; padding:10px 16px; font-weight:700; font-size:0.9rem;">💬 Pré-visualização do Chat</div>
                        <div id="chatPreviewArea" style="background:#e5ddd5; background-size:cover; background-position:center; padding:16px; display:flex; flex-direction:column; gap:8px; min-height:120px;">
                            <div id="chatPreviewRecebida" style="align-self:flex-start; background:#fff; border-radius:8px; border-bottom-left-radius:2px; padding:8px 12px 22px; font-size:0.85rem; position:relative; box-shadow:0 1px 1px rgba(0,0,0,0.1); max-width:80%;">
                                Olá! Como posso ajudar?
                                <span style="position:absolute; bottom:4px; right:8px; font-size:0.68rem; color:#94a3b8;">09:00</span>
                            </div>
                            <div id="chatPreviewEnviada" style="align-self:flex-end; background:#dcf8c6; border-radius:8px; border-bottom-right-radius:2px; padding:8px 12px 22px; font-size:0.85rem; position:relative; box-shadow:0 1px 1px rgba(0,0,0,0.1); max-width:80%;">
                                Visita domiciliar realizada com sucesso.
                                <span style="position:absolute; bottom:4px; right:8px; font-size:0.68rem; color:#4b6355;">09:15 ✓✓</span>
                            </div>
                        </div>
                    </div>
                </div>
                <button class="btn-primary" style="margin-top:16px;" onclick="salvarConfig()">💾 Salvar Personalização do Chat</button>
            </div>

            <div class="container">
                <h2>🏫 Gerenciar Escolas da Rede</h2>
                <div id="escolasAlerta"></div>
                <div style="display:flex; gap:10px; margin-bottom:16px;">
                    <button class="btn-primary" id="btnModoAlfabetica" onclick="definirModoOrdenacao('alfabetica')">🔤 Ordem Alfabética</button>
                    <button class="btn-secondary" id="btnModoManual" onclick="definirModoOrdenacao('manual')">✋ Ordem Manual</button>
                </div>
                <p id="dicaOrdemManual" style="display:none; color:#64748b; font-size:0.85rem; margin-top:-8px;">Arraste as escolas pela lista para reorganizar a ordem.</p>
                <div style="display:flex; gap:10px; margin-bottom:16px;">
                    <input type="text" id="novaEscolaNome" placeholder="Nome da nova escola" style="flex:1;">
                    <button class="btn-primary" onclick="adicionarEscola()">➕ Adicionar</button>
                </div>
                <div id="listaEscolas" style="max-height:400px; overflow-y:auto; border:1px solid #e2e8f0; border-radius:8px;"></div>
            </div>
        </div>

        <!-- ===== SUBTAB ANO LETIVO ===== -->
        <div class="subtab-content" id="sub-anoletivo">
            <div class="container">
                <h2>📅 Encerramento do Ano Letivo</h2>
                <p style="color:#64748b; font-size:0.93rem; max-width:680px; line-height:1.6;">
                    Ao fechar o ano letivo, todos os casos registrados no ano são <strong>arquivados</strong> em modo somente leitura.
                    Os dados ficam disponíveis para consulta histórica, mas não podem ser editados (exceto pelo Administrador).
                    Novos casos poderão ser abertos normalmente no ano seguinte.
                </p>
                <div id="alertaAnoLetivo"></div>
                <div style="background:#fef9c3; border:1px solid #fde68a; border-radius:8px; padding:14px 18px; margin:16px 0;">
                    <strong>⚠️ Ação irreversível.</strong> Confira se todos os acompanhamentos do ano foram devidamente registrados antes de encerrar.
                </div>
                <div style="display:flex; align-items:center; gap:14px; flex-wrap:wrap;">
                    <div>
                        <label style="font-weight:600; display:block; margin-bottom:6px;">Ano a encerrar</label>
                        <select id="anoLetivoSelect" style="width:140px;"></select>
                    </div>
                    <button class="btn-danger" id="btnFecharAnoLetivo" style="margin-top:20px;" onclick="confirmarFecharAnoLetivo()">🔒 Fechar Ano Letivo</button>
                </div>
            </div>

            <div class="container" id="anosArquivadosContainer">
                <h2>📦 Anos Letivos Arquivados</h2>
                <div id="listaAnosArquivados"><p style="color:#64748b;">Carregando...</p></div>
            </div>
        </div>
    </div>

    <div class="footer" id="footerTexto" style="margin-top:30px; padding:20px; text-align:center; font-size:0.85rem; color:#64748b; line-height:1.5; border-top:1px solid #e2e8f0;">
        © 2026 Secretaria de Educação e Inovação Pedagógica de Goiana - PE<br>
        Desenvolvimento: Coordenação de Tecnologia<br>
        Todos os direitos reservados.
    </div>
</div>

<!-- ====== MODAL MINHA CONTA ====== -->
<div id="modalMinhaConta" class="modal-overlay" onclick="fecharModalSeClicouFora(event)">
    <div class="modal-box modal-minha-conta">
        <div class="modal-header">
            <div style="display:flex; align-items:center; gap:14px;">
                <div id="avatarMinhaConta" class="avatar-circle" style="width:56px; height:56px; background:var(--accent); color:white; font-size:20px; overflow:hidden;"></div>
                <div>
                    <h2 style="margin:0; font-size:1.2rem;" id="nomeMinhaConta"></h2>
                    <p style="margin:4px 0 0; color:#64748b; font-size:0.85rem;" id="perfilMinhaConta"></p>
                </div>
            </div>
            <button class="modal-close-btn" onclick="fecharMinhaConta()">✕ Fechar</button>
        </div>
        <div class="modal-body">
            <div id="alertaMinhaConta"></div>
            <p style="font-weight:600; margin:0 0 10px;">📷 Foto de Perfil</p>
            <p style="color:#64748b; font-size:0.85rem; margin:0 0 12px;">Sua foto aparecerá no cabeçalho e nos avatares das suas mensagens de acompanhamento (armazenada apenas nesta sessão do navegador).</p>
            <label class="btn-primary" style="display:inline-block; cursor:pointer; font-size:0.85rem; padding:10px 18px; background:var(--accent); color:#fff; border-radius:8px;">
                📁 Selecionar Foto
                <input type="file" id="inputFotoUsuario" accept="image/*" style="display:none;" onchange="salvarFotoUsuario(this)">
            </label>
            <button id="btnRemoverFotoUsuario" class="btn-secondary" style="margin-left:8px; display:none;" onclick="removerFotoUsuario()">Remover Foto</button>
            <div id="previewFotoUsuarioBox" style="margin-top:14px; display:none;">
                <img id="previewFotoUsuarioImg" style="width:80px; height:80px; border-radius:50%; object-fit:cover; border:2px solid #e2e8f0;">
            </div>
        </div>
    </div>
</div>

<!-- ====== MODAL CASO ARQUIVADO (somente leitura) ====== -->
<div id="modalCasoArquivado" class="modal-overlay" onclick="if(event.target===this) fecharCasoArquivado()">
    <div class="modal-box">
        <div class="modal-header">
            <h2 style="margin:0; font-size:1.1rem;">📦 Consulta de Caso Arquivado</h2>
            <button class="modal-close-btn" onclick="fecharCasoArquivado()">✕ Fechar</button>
        </div>
        <div class="modal-body" id="casoArquivadoConteudo"></div>
    </div>
</div>

<!-- ====== MODAL RESETAR SENHA ====== -->
<div id="modalResetSenha" class="modal-overlay" onclick="if(event.target===this) fecharResetSenha()">
    <div class="modal-box" style="max-width:420px;">
        <div class="modal-header">
            <div>
                <h2 style="margin:0; font-size:1.1rem;">🔑 Redefinir Senha</h2>
                <p style="margin:4px 0 0; color:#64748b; font-size:0.85rem;" id="resetSenhaUsuarioNome"></p>
            </div>
            <button class="modal-close-btn" onclick="fecharResetSenha()">✕ Fechar</button>
        </div>
        <div class="modal-body">
            <div id="alertaResetSenha" style="margin-bottom:10px;"></div>
            <div class="form-group" style="margin-bottom:12px;">
                <label>Nova Senha</label>
                <input type="password" id="resetSenhaNova" placeholder="Mínimo 4 caracteres" autocomplete="new-password">
            </div>
            <div class="form-group" style="margin-bottom:16px;">
                <label>Confirmar Nova Senha</label>
                <input type="password" id="resetSenhaConfirma" placeholder="Repita a nova senha" autocomplete="new-password">
            </div>
            <button class="btn-primary" id="btnConfirmarResetSenha" onclick="confirmarResetSenha()">💾 Salvar Nova Senha</button>
        </div>
    </div>
</div>

<script>
const API = '/alunos/api';
let currentUser = JSON.parse(sessionStorage.getItem('usuario_logado') || 'null');

// ---------------- SEGURANÇA: requisições com token, escape de HTML e fotos protegidas ----------------
function esc(v) {
    return String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

async function fetchComAuth(endpoint, options = {}) {
    const url = endpoint.startsWith('http') || endpoint.startsWith('/') ? endpoint : `${API}/${endpoint}`;
    options.headers = options.headers || {};
    if (currentUser && currentUser.token) {
        if (options.headers instanceof Headers) options.headers.set('Authorization', `Bearer ${currentUser.token}`);
        else options.headers['Authorization'] = `Bearer ${currentUser.token}`;
    }
    const res = await fetch(url, options);
    if (res.status === 401 && currentUser) {
        alert('Sua sessão expirou ou é inválida. Por favor, faça login novamente.');
        logout();
        throw new Error('Sessão expirada');
    }
    return res;
}

function baixarArquivo(caminho) {
    const token = currentUser ? encodeURIComponent(currentUser.token || '') : '';
    const separador = caminho.includes('?') ? '&' : '?';
    baixarArquivo(`${caminho}${separador}token=${token}`);
}

function urlAnexo(id) {
    const token = currentUser && currentUser.token ? `?token=${encodeURIComponent(currentUser.token)}` : '';
    return `${API}/acompanhamentos/anexos/${id}${token}`;
}

// Fotos de alunos exigem login: são buscadas com o token (nunca na URL) e guardadas em memória
const cacheFotosAutenticadas = new Map();
function carregarImagemAutenticada(url) {
    if (!cacheFotosAutenticadas.has(url)) {
        cacheFotosAutenticadas.set(url, (async () => {
            try {
                const res = await fetchComAuth(url);
                if (!res.ok) return null;
                return URL.createObjectURL(await res.blob());
            } catch (e) { return null; }
        })());
    }
    return cacheFotosAutenticadas.get(url);
}
function invalidarCacheFotoAluno(alunoId) {
    const url = `${API}/alunos/${alunoId}/foto`;
    const p = cacheFotosAutenticadas.get(url);
    if (p) p.then(b => { if (b) URL.revokeObjectURL(b); });
    cacheFotosAutenticadas.delete(url);
}
function limparCacheFotos() {
    cacheFotosAutenticadas.forEach(p => p.then(b => { if (b) URL.revokeObjectURL(b); }));
    cacheFotosAutenticadas.clear();
}
function hidratarImagensAutenticadas(raiz) {
    const imgs = [];
    if (raiz.matches && raiz.matches('img[data-auth-src]')) imgs.push(raiz);
    if (raiz.querySelectorAll) imgs.push(...raiz.querySelectorAll('img[data-auth-src]'));
    imgs.forEach(img => {
        const url = img.getAttribute('data-auth-src');
        img.removeAttribute('data-auth-src');
        carregarImagemAutenticada(url).then(blobUrl => {
            if (!img.isConnected) return;
            if (blobUrl) img.src = blobUrl;
            else img.dispatchEvent(new Event('error'));
        });
    });
}
new MutationObserver(muts => muts.forEach(m => m.addedNodes.forEach(n => {
    if (n.nodeType === 1) hidratarImagensAutenticadas(n);
}))).observe(document.documentElement, { childList: true, subtree: true });

const CATEGORIAS_MOTIVO = ["Evasão", "Frequência Irregular", "Vulnerabilidade Social", "Saúde", "Violência/Negligência", "Outro"];
const CATEGORIAS_MENSAGEM = ["Ligação", "Visita Domiciliar", "Reunião", "Contato com Conselho Tutelar", "Contato com CRAS/CREAS", "Contato com Unidade de Saúde", "Outro"];
const DESTINOS_ENCAMINHAMENTO = ["Conselho Tutelar", "CRAS/CREAS", "Unidade de Saúde", "Ministério Público", "Outro"];

let escolasCache = [];
let escolaArrastadaId = null;
let anosArquivados = []; // [{ ano, fechado_em, fechado_por, casos: [...] }]

// ---------------- DATA/HORA (automática ou manual) ----------------
// O relógio oficial é o do SERVIDOR (horário de Recife). No modo manual o servidor parte da data/hora definida
// pelo administrador e continua contando a partir dela. O navegador apenas acompanha essa hora.
let configHora = { modo: 'automatico', dataManual: null };
let relogioOffsetMs = 0;   // diferença entre o relógio do servidor e o do navegador
localStorage.removeItem('config_hora');   // versões antigas guardavam a configuração aqui

// Lê "AAAA-MM-DDTHH:MM:SS" como hora de parede (sem converter fuso)
function parseHoraSemFuso(txt) {
    const m = String(txt || '').match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/);
    return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)) : null;
}

function aplicarConfigHoraDoServidor(cfg) {
    if (!cfg) return;
    configHora = { modo: cfg.modo_hora || 'automatico', dataManual: cfg.data_hora_manual || null };
    const agoraServidor = parseHoraSemFuso(cfg.agora_sistema);
    if (agoraServidor) relogioOffsetMs = agoraServidor.getTime() - Date.now();
    atualizarAvisoRelogio();
}

function getDataHoraAtual() {
    return new Date(Date.now() + relogioOffsetMs);
}

// Data/hora atual em formato ISO local (sem fuso)
function getDataHoraAtualIso() {
    const d = getDataHoraAtual();
    const p = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

async function sincronizarRelogio() {
    try {
        const res = await fetch(`${API}/config`);
        if (res.ok) aplicarConfigHoraDoServidor(await res.json());
    } catch (e) { /* mantém a última hora conhecida */ }
}
setInterval(() => { if (currentUser) sincronizarRelogio(); }, 300000);

// Aviso no cabeçalho enquanto o relógio estiver em modo manual
function atualizarAvisoRelogio() {
    let aviso = document.getElementById('avisoRelogio');
    if (!aviso) {
        const cab = document.querySelector('header > div:last-child');
        if (!cab) return;
        aviso = document.createElement('span');
        aviso.id = 'avisoRelogio';
        aviso.setAttribute('style', 'display:none; background:#fef3c7; color:#92400e; font-size:0.72rem; font-weight:700; padding:4px 10px; border-radius:12px; white-space:nowrap;');
        cab.insertBefore(aviso, cab.firstChild);
    }
    if (configHora.modo === 'manual') {
        aviso.textContent = `🕐 Relógio manual: ${getDataHoraAtual().toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;
        aviso.title = 'O administrador definiu a data e a hora do sistema manualmente (Configurações → Personalização → Data e Hora).';
        aviso.style.display = 'inline-block';
    } else {
        aviso.style.display = 'none';
    }
}
setInterval(atualizarAvisoRelogio, 30000);

function toggleModoHora() {
    const modo = document.querySelector('input[name="modoHora"]:checked').value;
    document.getElementById('painelHoraManual').style.display = modo === 'manual' ? 'block' : 'none';
    if (modo === 'manual' && !document.getElementById('c_hora_dia').value) {
        preencherCamposHora(getDataHoraAtual());
    }
}

function preencherCamposHora(d) {
    document.getElementById('c_hora_dia').value = d.getDate();
    document.getElementById('c_hora_mes').value = d.getMonth() + 1;
    document.getElementById('c_hora_ano').value = d.getFullYear();
    document.getElementById('c_hora_hh').value = d.getHours();
    document.getElementById('c_hora_mm').value = d.getMinutes();
}

// Lê os campos de hora manual; retorna "AAAA-MM-DDTHH:MM:00" (hora digitada, sem conversão de fuso) ou null se inválido
function lerCamposHoraManual() {
    const v = id => parseInt(document.getElementById(id).value, 10);
    const dia = v('c_hora_dia'), mes = v('c_hora_mes'), ano = v('c_hora_ano');
    const hh = v('c_hora_hh') || 0, mm = v('c_hora_mm') || 0;
    if (!dia || !mes || !ano) return null;
    const d = new Date(ano, mes - 1, dia, hh, mm, 0);
    if (isNaN(d.getTime()) || d.getDate() !== dia || d.getMonth() !== mes - 1 || hh > 23 || mm > 59) return null;
    const p = n => String(n).padStart(2, '0');
    return `${ano}-${p(mes)}-${p(dia)}T${p(hh)}:${p(mm)}:00`;
}

// ---------------- AVATARES ----------------
function avatarHtml(nome, fotoUrl, tamanho = 44, estilo = '') {
    const ini = esc(iniciaisNome(nome) || '?');
    const fs = Math.round(tamanho * 0.36);
    const fallback = `<div class="avatar-circle" style="width:${tamanho}px;height:${tamanho}px;background:var(--accent);color:white;font-size:${fs}px;${estilo}">${ini}</div>`;
    if (fotoUrl) {
        // Se a imagem falhar ao carregar, troca pelas iniciais
        const fb = fallback.replace(/"/g, '&quot;');
        const atributoSrc = fotoUrl.startsWith(`${API}/`) ? `data-auth-src="${fotoUrl}"` : `src="${fotoUrl}"`;
        return `<img ${atributoSrc} alt="${ini}" onerror="this.outerHTML='${fb.replace(/'/g, "\\'")}'" style="width:${tamanho}px;height:${tamanho}px;border-radius:50%;object-fit:cover;flex-shrink:0;${estilo}">`;
    }
    return fallback;
}

// Foto do usuário logado (armazenada no sessionStorage)
function chaveFotoUsuario(usuario) { return `foto_usuario_${usuario}`; }
function fotoUsuarioLogado() {
    return currentUser ? sessionStorage.getItem(chaveFotoUsuario(currentUser.usuario)) : null;
}
// Retorna a foto do autor de uma mensagem ("Nome (usuario)") se for o usuário logado
function fotoDeUsuario(identificador) {
    const m = identificador ? identificador.match(/\(([^)]+)\)\s*$/) : null;
    if (!m) return null;
    return sessionStorage.getItem(chaveFotoUsuario(m[1]));
}

async function carregarEscolas() {
    const res = await fetchComAuth(`escolas`);
    const data = await res.json();
    escolasCache = data.escolas;
    window._modoOrdenacao = data.modo;
    preencherSelectEscolas();
    renderizarListaEscolas();
    atualizarBotoesModo();
}

function atualizarBotoesModo() {
    const btnAlfa = document.getElementById('btnModoAlfabetica');
    const btnManual = document.getElementById('btnModoManual');
    const dica = document.getElementById('dicaOrdemManual');
    if (!btnAlfa || !btnManual) return;
    const manual = window._modoOrdenacao === 'manual';
    btnAlfa.className = manual ? 'btn-secondary' : 'btn-primary';
    btnManual.className = manual ? 'btn-primary' : 'btn-secondary';
    if (dica) dica.style.display = manual ? 'block' : 'none';
}

async function definirModoOrdenacao(modo) {
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    await fetchComAuth(`escolas/modo`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ modo })
    });
    carregarEscolas();
}

function preencherSelectEscolas() {
    const sel = document.getElementById('f_escola_origem');
    sel.innerHTML = '<option value="">Selecione a Escola</option>' +
        escolasCache.map(e => `<option value="${esc(e.nome)}">${esc(e.nome)}</option>`).join('');
}

function renderizarListaEscolas() {
    const container = document.getElementById('listaEscolas');
    if (!container) return;
    const manual = window._modoOrdenacao === 'manual';
    container.innerHTML = escolasCache.map(e => `
        <div draggable="${manual}"
             ondragstart="escolaArrastadaId = ${e.id};"
             ondragover="event.preventDefault();"
             ondrop="moverEscola(${e.id})"
             style="display:flex; justify-content:space-between; align-items:center; padding:8px 12px; border-bottom:1px solid #e2e8f0; ${manual ? 'cursor:grab; background:#f8fafc;' : ''}">
            <span>${manual ? '⠿ ' : ''}${esc(e.nome)}</span>
            <button class="btn-danger" style="padding:4px 10px; font-size:0.8rem;" data-n="${esc(e.nome)}" onclick="removerEscola(${e.id}, this.dataset.n)">Remover</button>
        </div>`).join('');
}

function moverEscola(alvoId) {
    if (escolaArrastadaId === null || escolaArrastadaId === alvoId) return;
    const origemIdx = escolasCache.findIndex(e => e.id === escolaArrastadaId);
    const destinoIdx = escolasCache.findIndex(e => e.id === alvoId);
    if (origemIdx === -1 || destinoIdx === -1) return;
    const [item] = escolasCache.splice(origemIdx, 1);
    escolasCache.splice(destinoIdx, 0, item);
    escolaArrastadaId = null;
    renderizarListaEscolas();
    salvarOrdemEscolas();
}

async function salvarOrdemEscolas() {
    const ordem = escolasCache.map(e => e.id);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    await fetchComAuth(`escolas/ordem`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ordem })
    });
}

async function adicionarEscola() {
    const input = document.getElementById('novaEscolaNome');
    const nome = input.value.trim();
    if (!nome) { alerta('escolasAlerta', 'warning', 'Digite o nome da escola.'); return; }
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`escolas`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ nome })
    });
    if (res.ok) {
        input.value = '';
        alerta('escolasAlerta', 'success', `Escola "${nome}" adicionada!`);
        carregarEscolas();
    } else {
        const err = await res.json();
        alerta('escolasAlerta', 'error', err.detail || 'Erro ao adicionar escola.');
    }
}

async function removerEscola(id, nome) {
    if (!confirm(`Remover a escola "${nome}" da lista?`)) return;
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    await fetchComAuth(`escolas/${id}`, { method: 'DELETE' });
    carregarEscolas();
}

function toggleSenhaLogin() {
    const campo = document.getElementById('loginSenha');
    campo.type = campo.type === 'password' ? 'text' : 'password';
}

function alerta(containerId, tipo, mensagem) {
    document.getElementById(containerId).innerHTML = `<div class="alert alert-${esc(tipo)}">${esc(mensagem)}</div>`;
    setTimeout(() => { document.getElementById(containerId).innerHTML = ''; }, 6000);
}

// ---------------- LOGIN / LOGOUT ----------------
async function carregarConfigVisual(forcarAtualizacao = false) {
    try {
        const res = await fetch(`${API}/config`);
        const cfg = await res.json();
        const buster = forcarAtualizacao ? `?v=${Date.now()}` : '';
        if (cfg) {
            document.getElementById('tituloLogin').innerText = cfg.titulo_login || 'Sistema de Gestão Escolar';
            document.getElementById('subtituloLogin').innerText = cfg.subtitulo_login || '';
            document.getElementById('tituloInterno').innerText = cfg.titulo_interno || 'Busca Ativa Escolar & Gestão';
            document.title = cfg.titulo_interno || 'Busca Ativa Escolar';
            if (cfg.rodape_texto) {
                document.getElementById('footerTexto').innerHTML = cfg.rodape_texto
                    .split('\n')
                    .map(linha => esc(linha.trim()))
                    .filter(linha => linha.length > 0)
                    .join('<br>');
            }

            const promessasImagens = [];

            if (cfg.tem_logo) {
                const logoUrl = `${API}/config/logo${buster}`;
                promessasImagens.push(new Promise(resolve => {
                    const img = new Image();
                    img.onload = () => {
                        document.getElementById('logoLogin').src = logoUrl;
                        document.getElementById('logoLogin').style.display = 'block';
                        document.getElementById('iconeLogin').style.display = 'none';
                        document.getElementById('logoInterno').src = logoUrl;
                        document.getElementById('logoInterno').style.display = 'block';
                        resolve();
                    };
                    img.onerror = resolve;
                    img.src = logoUrl;
                }));
            }

            document.querySelector('header').style.backgroundColor = cfg.cor_cabecalho || '#1e293b';
            document.querySelector('header').style.color = cfg.cor_texto_cabecalho || '#ffffff';
            document.querySelector('.nav-tabs').style.backgroundColor = cfg.cor_menu || '#0f172a';
            document.documentElement.style.setProperty('--accent', cfg.cor_destaque || '#2563eb');

            if (cfg.tem_fundo_login) {
                const fundoUrl = `${API}/config/fundo-login${buster}`;
                promessasImagens.push(new Promise(resolve => {
                    const img = new Image();
                    img.onload = () => {
                        const loginScreen = document.getElementById('loginScreen');
                        loginScreen.style.backgroundImage = `url('${fundoUrl}')`;
                        loginScreen.style.backgroundSize = 'cover';
                        loginScreen.style.backgroundPosition = 'center';
                        resolve();
                    };
                    img.onerror = resolve;
                    img.src = fundoUrl;
                }));
            }

            await Promise.all(promessasImagens);
            aplicarConfigHoraDoServidor(cfg);
            window._configAtual = cfg;
            window._configChat = montarConfigChat(cfg, buster);
            aplicarConfigChat();
        }
    } catch (e) {
        console.error(e);
    } finally {
        if (!currentUser) {
            document.getElementById('loginScreen').style.display = 'flex';
        }
    }
}

async function fazerLogin() {
    const usuario = document.getElementById('loginUsuario').value;
    const senha = document.getElementById('loginSenha').value;
    document.getElementById('loginErro').innerText = '';

    try {
        const res = await fetch(`${API}/login`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ usuario, senha })
        });
        if (res.status === 429) {
            const err = await res.json().catch(() => ({}));
            document.getElementById('loginErro').innerText = '⛔ ' + (err.detail || 'Muitas tentativas incorretas. Acesso bloqueado temporariamente.');
            return;
        }
        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            document.getElementById('loginErro').innerText = '⚠️ ' + (err.detail || 'Usuário ou senha incorretos.');
            return;
        }
        currentUser = await res.json();
        sessionStorage.setItem('usuario_logado', JSON.stringify(currentUser));
        entrarNoSistema();
    } catch (e) {
        document.getElementById('loginErro').innerText = 'Erro ao conectar com o servidor.';
    }
}

function logout() {
    sessionStorage.removeItem('usuario_logado');
    limparCacheFotos();
    currentUser = null;
    document.getElementById('appScreen').style.display = 'none';
    document.getElementById('loginScreen').style.display = 'flex';
}

function entrarNoSistema() {
    sincronizarRelogio();
    document.getElementById('loginScreen').style.display = 'none';
    document.getElementById('appScreen').style.display = 'block';
    document.getElementById('userNome').innerText = currentUser.nome;
    document.getElementById('userPerfil').innerText = currentUser.perfil;
    atualizarAvatarHeader();

    const ehUsuarioComum = currentUser.perfil === 'Usuário Comum';

    document.getElementById('btnTabConfig').style.display = currentUser.perfil === 'Administrador' ? 'inline-block' : 'none';
    document.getElementById('btnTabDashboard').style.display = ehUsuarioComum ? 'none' : 'inline-block';
    document.getElementById('btnTabConsulta').style.display = ehUsuarioComum ? 'none' : 'inline-block';
    document.getElementById('btnLimparLogs').style.display = currentUser.perfil === 'Administrador' ? 'inline-block' : 'none';
    document.getElementById('btnAbrirExclusao').style.display = currentUser.perfil === 'Administrador' ? 'inline-block' : 'none';
    document.getElementById('cardLogsAuditoria').style.display = ehUsuarioComum ? 'none' : 'block';

    if (ehUsuarioComum) {
        mudarTab('cadastro');
    }

    carregarEscolas();
    carregarAlunosDashboard();
    carregarDashboardStats();
    const hoje = getDataHoraAtualIso().slice(0, 10);
    const inicioMes = hoje.slice(0, 8) + '01';
    document.getElementById('logDataInicio').value = inicioMes;
    document.getElementById('logDataFim').value = hoje;
    carregarLogs();
    if (!ehUsuarioComum) {
        carregarEstatisticasAcompanhamento();
        carregarPainelConsulta();
    }
    if (currentUser.perfil === 'Administrador') {
        carregarUsuarios();
        carregarConfigForm();
    }
}

// ---------------- NAVEGAÇÃO ----------------
function mudarTab(tab) {
    document.querySelectorAll('.nav-tabs button').forEach(b => b.classList.remove('active'));
    document.querySelector(`.nav-tabs button[data-tab="${tab}"]`).classList.add('active');
    document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
    document.getElementById(`tab-${tab}`).classList.add('active');

    if (tab === 'consulta') {
        carregarPainelConsulta();
        document.getElementById('painelListaCasos').style.display = 'none';
        fecharPainelPerfilAluno();
        document.getElementById('resultadoBuscaAlunos').innerHTML = '';
        document.getElementById('buscaAlunoInput').value = '';
    }
}

function mudarSubtab(sub) {
    document.querySelectorAll('.subtabs button').forEach(b => b.classList.remove('active'));
    document.querySelector(`.subtabs button[data-sub="${sub}"]`).classList.add('active');
    document.querySelectorAll('.subtab-content').forEach(c => c.classList.remove('active'));
    document.getElementById(`sub-${sub}`).classList.add('active');
    if (sub === 'visual') {
        carregarConfigForm();
        carregarEscolas();
    }
    if (sub === 'anoletivo') {
        carregarSubtabAnoLetivo();
    }
}

// ---------------- CADASTRO DE ALUNOS ----------------
async function salvarAluno(e) {
    e.preventDefault();
    const dados = {
        nome: document.getElementById('f_nome').value,
        cpf: document.getElementById('f_cpf').value,
        data_nasc: document.getElementById('f_data_nasc').value,
        tipo_busca: document.getElementById('f_tipo_busca').value,
        escola_origem: document.getElementById('f_escola_origem').value,
        turma: document.getElementById('f_turma').value,
        endereco: document.getElementById('f_endereco').value,
        observacoes: document.getElementById('f_observacoes').value
    };
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`alunos`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(dados)
    });
    if (res.ok) {
        alerta('cadastroAlerta', 'success', `✅ Aluno(a) ${dados.nome} salvo com sucesso!`);
        document.getElementById('formAluno').reset();
        carregarAlunosDashboard();
        carregarDashboardStats();
    } else {
        alerta('cadastroAlerta', 'error', '❌ Erro ao salvar o cadastro.');
    }
}

async function importarLoteAlunos() {
    const arquivo = document.getElementById('arquivoLoteAlunos').files[0];
    if (!arquivo) { alerta('importAlertaAlunos', 'warning', 'Selecione um arquivo primeiro.'); return; }
    const formData = new FormData();
    formData.append('arquivo', arquivo);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`alunos/lote`, { method: 'POST', body: formData });
    if (res.ok) {
        const data = await res.json();
        alerta('importAlertaAlunos', 'success', `🎉 ${data.total_importado} alunos importados com sucesso!`);
        carregarAlunosDashboard();
        carregarDashboardStats();
    } else {
        alerta('importAlertaAlunos', 'error', '❌ Erro ao importar a planilha.');
    }
}

// ---------------- DASHBOARD ----------------
let chartEscolasRef = null;
let chartTipoBuscaRef = null;
let chartUrgenciaRef = null;

async function carregarDashboardStats() {
    const res = await fetchComAuth(`dashboard`);
    const stats = await res.json();

    document.getElementById('kpiTotal').innerText = stats.total_alunos;
    document.getElementById('kpiEscolas').innerText = stats.escolas_ativas;
    document.getElementById('kpiIdade').innerText = stats.media_idade + ' anos';

    const ctxEscolas = document.getElementById('chartEscolas');
    if (chartEscolasRef) chartEscolasRef.destroy();
    chartEscolasRef = new Chart(ctxEscolas, {
        type: 'bar',
        data: {
            labels: stats.por_escola.map(r => r.escola_origem),
            datasets: [{ label: 'Alunos', data: stats.por_escola.map(r => r.quantidade), backgroundColor: '#4f46e5' }]
        },
        options: { indexAxis: 'y', plugins: { title: { display: true, text: 'Top 10 Escolas' } } }
    });

    const ctxTipo = document.getElementById('chartTipoBusca');
    if (chartTipoBuscaRef) chartTipoBuscaRef.destroy();
    chartTipoBuscaRef = new Chart(ctxTipo, {
        type: 'pie',
        data: {
            labels: stats.por_tipo_busca.map(r => r.tipo_busca),
            datasets: [{ data: stats.por_tipo_busca.map(r => r.quantidade), backgroundColor: ['#4f46e5', '#06b6d4'] }]
        },
        options: { plugins: { title: { display: true, text: 'Distribuição por Tipo de Busca' } } }
    });
}

async function carregarEstatisticasAcompanhamento() {
    const res = await fetchComAuth(`acompanhamentos/estatisticas`);
    const stats = await res.json();
    document.getElementById('kpiCasosAbertos').innerText = stats.total_abertos;
    document.getElementById('kpiCasosAtrasados').innerText = stats.total_atrasados;
    document.getElementById('kpiTempoMedio').innerText = stats.tempo_medio_dias > 0 ? `${stats.tempo_medio_dias} dias` : '—';

    const cores = { alta: '#dc2626', media: '#f59e0b', baixa: '#10b981' };
    const ctx = document.getElementById('chartUrgencia');
    if (chartUrgenciaRef) chartUrgenciaRef.destroy();
    if (stats.por_urgencia.length === 0) return;
    chartUrgenciaRef = new Chart(ctx, {
        type: 'pie',
        data: {
            labels: stats.por_urgencia.map(r => r.urgencia.toUpperCase()),
            datasets: [{ data: stats.por_urgencia.map(r => r.quantidade), backgroundColor: stats.por_urgencia.map(r => cores[r.urgencia] || '#64748b') }]
        },
        options: { plugins: { title: { display: true, text: 'Casos Abertos por Urgência' } } }
    });
}

async function carregarAlunosDashboard() {
    const res = await fetchComAuth(`alunos`);
    const alunos = await res.json();
    const tbody = document.getElementById('tabelaAlunosDashboard');
    tbody.innerHTML = alunos.map(a => `
        <tr>
            <td>${esc(a.nome)}</td><td>${esc(a.cpf)}</td>
            <td>${a.data_nasc ? new Date(a.data_nasc).toLocaleDateString('pt-BR') : ''}</td>
            <td>${esc(a.escola_origem)}</td><td>${esc(a.turma)}</td><td>${esc(a.tipo_busca)}</td>
            <td>${esc(a.endereco || '')}</td><td>${esc(a.observacoes || '')}</td>
            <td>${currentUser.perfil === 'Usuário Comum' ? '' : `<button class="btn-secondary" style="padding:4px 10px; font-size:0.8rem;" onclick="irParaConsultaAluno(${a.id})">👁 Consulta</button>`}</td>
        </tr>`).join('');
}

function irParaConsultaAluno(alunoId) {
    mudarTab('consulta');
    abrirPerfilAlunoPorId(alunoId);
}

function toggleExclusao() {
    const p = document.getElementById('painelExclusao');
    p.style.display = p.style.display === 'none' ? 'block' : 'none';
}

async function excluirTodosAlunos() {
    const confirmacao = document.getElementById('txtDeletar').value;
    const usuarioResp = `${currentUser.nome} (${currentUser.usuario})`;
    const res = await fetchComAuth(`alunos/excluir-tudo`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ confirmacao, usuario_responsavel: usuarioResp })
    });
    if (res.ok) {
        alerta('dashboardAlerta', 'success', '✅ Base de alunos excluída com sucesso!');
        document.getElementById('painelExclusao').style.display = 'none';
        carregarAlunosDashboard();
        carregarDashboardStats();
        carregarEstatisticasAcompanhamento();
    } else {
        const err = await res.json();
        alerta('dashboardAlerta', 'error', `❌ ${err.detail || 'Erro ao excluir.'}`);
    }
}

// ---------------- LOGS ----------------
async function carregarLogs() {
    const ini = document.getElementById('logDataInicio').value;
    const fim = document.getElementById('logDataFim').value;
    const res = await fetchComAuth(`logs?data_inicio=${ini}&data_fim=${fim}`);
    const logs = await res.json();
    document.getElementById('tabelaLogs').innerHTML = logs.map(l => `
        <tr>
            <td>${l.data_hora ? new Date(l.data_hora).toLocaleString('pt-BR') : ''}</td>
            <td>${esc(l.usuario || '')}</td><td>${esc(l.acao || '')}</td><td>${esc(l.detalhes || '')}</td>
        </tr>`).join('');
}

function exportarLogsPdf() {
    const ini = document.getElementById('logDataInicio').value;
    const fim = document.getElementById('logDataFim').value;
    const usr = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    baixarArquivo(`logs/pdf?data_inicio=${ini}&data_fim=${fim}`);
}

function exportarLogsCsv() {
    const ini = document.getElementById('logDataInicio').value;
    const fim = document.getElementById('logDataFim').value;
    baixarArquivo(`logs/csv?data_inicio=${ini}&data_fim=${fim}`);
}

async function limparLogs() {
    if (!confirm('Tem certeza que deseja apagar todos os logs?')) return;
    await fetchComAuth(`logs`, { method: 'DELETE' });
    carregarLogs();
}

// ---------------- USUÁRIOS ----------------
async function carregarUsuarios() {
    const res = await fetchComAuth(`usuarios`);
    const usuarios = await res.json();
    document.getElementById('tabelaUsuarios').innerHTML = usuarios.map(u => `
        <tr>
            <td>${esc(u.usuario)}</td><td>${esc(u.nome)}</td>
            <td>
                <select data-u="${esc(u.usuario)}" onchange="atualizarPerfilUsuario(this.dataset.u, this.value)">
                    <option ${u.perfil === 'Usuário Comum' ? 'selected' : ''}>Usuário Comum</option>
                    <option ${u.perfil === 'Gestor / Visualizador' ? 'selected' : ''}>Gestor / Visualizador</option>
                    <option ${u.perfil === 'Coordenador de Acompanhamento' ? 'selected' : ''}>Coordenador de Acompanhamento</option>
                    <option ${u.perfil === 'Administrador' ? 'selected' : ''}>Administrador</option>
                </select>
            </td>
            <td style="white-space:nowrap;">${u.usuario === 'admin' ? '' : `
                <button class="btn-secondary" style="padding:8px 12px; font-size:0.82rem;" data-u="${esc(u.usuario)}" data-n="${esc(u.nome || '')}" onclick="resetarSenhaUsuario(this.dataset.u, this.dataset.n)">🔑 Resetar Senha</button>
                <button class="btn-danger" data-u="${esc(u.usuario)}" onclick="removerUsuario(this.dataset.u)">Remover</button>`}</td>
        </tr>`).join('');
}

function resetarSenhaUsuario(usuario, nome) {
    const modal = document.getElementById('modalResetSenha');
    document.getElementById('resetSenhaUsuarioNome').innerText = nome ? `${nome} (${usuario})` : usuario;
    document.getElementById('resetSenhaNova').value = '';
    document.getElementById('resetSenhaConfirma').value = '';
    document.getElementById('alertaResetSenha').innerHTML = '';
    document.getElementById('btnConfirmarResetSenha').disabled = false;
    modal.dataset.usuario = usuario;
    modal.style.display = 'flex';
    document.body.style.overflow = 'hidden';
    setTimeout(() => document.getElementById('resetSenhaNova').focus(), 50);
}

async function confirmarResetSenha() {
    const modal = document.getElementById('modalResetSenha');
    const usuario = modal.dataset.usuario;
    const nova = document.getElementById('resetSenhaNova').value;
    const confirma = document.getElementById('resetSenhaConfirma').value;
    const caixaAlerta = document.getElementById('alertaResetSenha');
    if (!nova || nova.length < 4) {
        caixaAlerta.innerHTML = '<div class="alert alert-error">A senha deve ter no mínimo 4 caracteres.</div>';
        return;
    }
    if (nova !== confirma) {
        caixaAlerta.innerHTML = '<div class="alert alert-error">As senhas não coincidem.</div>';
        return;
    }
    const btn = document.getElementById('btnConfirmarResetSenha');
    btn.disabled = true;
    try {
        const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
        const res = await fetchComAuth(`usuarios/${encodeURIComponent(usuario)}/resetar-senha`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ nova_senha: nova })
        });
        if (res.ok) {
            caixaAlerta.innerHTML = '<div class="alert alert-success">✅ Senha redefinida com sucesso!</div>';
            setTimeout(fecharResetSenha, 1500);
        } else {
            let msg = 'Erro ao redefinir a senha.';
            try { const err = await res.json(); msg = err.detail || msg; } catch (e) {}
            caixaAlerta.innerHTML = `<div class="alert alert-error">❌ ${msg}</div>`;
            btn.disabled = false;
        }
    } catch (e) {
        caixaAlerta.innerHTML = '<div class="alert alert-error">❌ Erro ao conectar com o servidor.</div>';
        btn.disabled = false;
    }
}

function fecharResetSenha() {
    document.getElementById('modalResetSenha').style.display = 'none';
    document.body.style.overflow = '';
}

async function criarUsuario() {
    const dados = {
        usuario: document.getElementById('u_usuario').value,
        senha: document.getElementById('u_senha').value,
        nome: document.getElementById('u_nome').value,
        perfil: document.getElementById('u_perfil').value
    };
    if (!dados.usuario || !dados.senha || !dados.nome) {
        alerta('usuarioAlerta', 'warning', 'Preencha todos os campos.');
        return;
    }
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`usuarios`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(dados)
    });
    if (res.ok) {
        alerta('usuarioAlerta', 'success', `Usuário ${dados.usuario} criado!`);
        document.getElementById('u_usuario').value = '';
        document.getElementById('u_senha').value = '';
        document.getElementById('u_nome').value = '';
        carregarUsuarios();
    } else {
        const err = await res.json();
        alerta('usuarioAlerta', 'error', err.detail || 'Erro ao criar usuário.');
    }
}

async function atualizarPerfilUsuario(usuario, novoPerfil) {
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    await fetchComAuth(`usuarios/${usuario}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ perfil: novoPerfil })
    });
}

async function removerUsuario(usuario) {
    if (!confirm(`Remover o usuário ${usuario}?`)) return;
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    await fetchComAuth(`usuarios/${usuario}`, { method: 'DELETE' });
    carregarUsuarios();
}

async function importarLoteUsuarios() {
    const arquivo = document.getElementById('arquivoLoteUsuarios').files[0];
    if (!arquivo) { alerta('importAlertaUsuarios', 'warning', 'Selecione um arquivo primeiro.'); return; }
    const formData = new FormData();
    formData.append('arquivo', arquivo);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`usuarios/lote`, { method: 'POST', body: formData });
    if (res.ok) {
        const data = await res.json();
        alerta('importAlertaUsuarios', 'success', `${data.total_importado} usuários importados!`);
        carregarUsuarios();
    } else {
        alerta('importAlertaUsuarios', 'error', 'Erro ao importar usuários.');
    }
}

// ---------------- PERSONALIZAÇÃO ----------------
async function carregarConfigForm() {
    let cfg = {};
    try {
        const res = await fetch(`${API}/config`);
        cfg = await res.json();
        if (!cfg) cfg = {};
    } catch (e) {
        cfg = window._configAtual || {};
    }
    document.getElementById('c_titulo_login').value = cfg.titulo_login || '';
    document.getElementById('c_subtitulo_login').value = cfg.subtitulo_login || '';
    document.getElementById('c_titulo_interno').value = cfg.titulo_interno || '';
    document.getElementById('c_cor_cabecalho').value = cfg.cor_cabecalho || '#1e293b';
    document.getElementById('c_cor_menu').value = cfg.cor_menu || '#0f172a';
    document.getElementById('c_cor_texto_cabecalho').value = cfg.cor_texto_cabecalho || '#ffffff';
    document.getElementById('c_cor_destaque').value = cfg.cor_destaque || '#2563eb';
    document.getElementById('c_rodape_texto').value = cfg.rodape_texto || '';
    document.getElementById('c_cabecalho_pdf_texto').value = cfg.cabecalho_pdf_texto || '';
    document.getElementById('c_rodape_pdf_texto').value = cfg.rodape_pdf_texto || '';

    // Logo e tamanho do PDF
    document.getElementById('c_logo_pdf').value = '';
    document.getElementById('c_tamanho_logo_pdf').value = String(cfg.tamanho_logo_pdf || 60);
    if (!document.getElementById('c_tamanho_logo_pdf').value) document.getElementById('c_tamanho_logo_pdf').value = '60';
    if (cfg.tem_logo_pdf) {
        document.getElementById('previewLogoPdf').src = `${API}/config/logo-pdf?v=${Date.now()}`;
        document.getElementById('previewLogoPdfBox').style.display = 'block';
    } else {
        document.getElementById('previewLogoPdfBox').style.display = 'none';
    }

    // Data/hora
    aplicarConfigHoraDoServidor(cfg);
    if (configHora.modo === 'manual') {
        document.getElementById('c_hora_manual').checked = true;
        document.getElementById('painelHoraManual').style.display = 'block';
        preencherCamposHora(getDataHoraAtual());
    } else {
        document.getElementById('c_hora_auto').checked = true;
        document.getElementById('painelHoraManual').style.display = 'none';
    }

    // Personalização do chat
    document.getElementById('c_chat_bg_color').value = cfg.chat_bg_color || '#e5ddd5';
    document.getElementById('c_chat_bubble_sent').value = cfg.chat_bubble_sent || '#dcf8c6';
    document.getElementById('c_chat_bubble_received').value = cfg.chat_bubble_received || '#ffffff';
    document.getElementById('c_chat_header_color').value = cfg.chat_header_color || '#075e54';
    document.getElementById('c_chat_bg_image').value = '';
    document.getElementById('c_chat_bg_image_remover').checked = false;
    window._configChat = montarConfigChat(cfg, `?v=${Date.now()}`);
    if (window._configChat.chat_bg_image_url) {
        document.getElementById('previewChatBgImg').src = window._configChat.chat_bg_image_url;
        document.getElementById('previewChatBgBox').style.display = 'block';
    } else {
        document.getElementById('previewChatBgBox').style.display = 'none';
    }
    aplicarConfigChat();
    atualizarPreviewChatAoVivo();
    // Modelo do relatório
    const defFinalidade = `Este relatório tem por finalidade registrar e sistematizar as providências adotadas pela Secretaria de Educação e Inovação Pedagógica, em articulação com a unidade escolar, para o acompanhamento da frequência escolar do(a) estudante, a verificação dos motivos das faltas e o registro das justificativas apresentadas pela família ou responsável legal.\n\nO procedimento busca documentar as ações realizadas para a identificação e o acompanhamento de situações de faltas injustificadas, infrequência escolar ou possível evasão, bem como os contatos e as providências adotadas junto à família, à unidade escolar e aos demais órgãos integrantes da rede de proteção.\n\nQuando, após a adoção das medidas de acompanhamento e das providências cabíveis no âmbito escolar, permanecer situação que demande atuação da rede de proteção, as informações registradas neste relatório poderão subsidiar o encaminhamento ao Conselho Tutelar, para conhecimento, acompanhamento e adoção das medidas que entender cabíveis, observadas as competências legais de cada órgão.\n\nO presente relatório constitui instrumento de registro, acompanhamento e documentação das providências realizadas pela Secretaria de Educação e Inovação Pedagógica, não substituindo os registros de frequência e demais documentos de responsabilidade da unidade escolar.`;
    const defFundLDB = `O art. 12, inciso VIII, estabelece como incumbência dos estabelecimentos de ensino a notificação ao Conselho Tutelar do Município da relação dos alunos que apresentem quantidade de faltas acima do percentual permitido em lei.`;
    const defFundECA = `O art. 56, inciso II, estabelece que os dirigentes de estabelecimentos de ensino fundamental devem comunicar ao Conselho Tutelar os casos de reiteração de faltas injustificadas e de evasão escolar, esgotados os recursos escolares.`;
    const defFundAplicacao = `Considerando as competências legais dos diferentes órgãos envolvidos, este relatório possui caráter de registro, acompanhamento, sistematização e documentação das providências realizadas, podendo subsidiar os encaminhamentos necessários à rede de proteção, sem substituir os documentos e procedimentos próprios da unidade escolar ou dos demais órgãos competentes.`;
    document.getElementById('c_rel_finalidade').value = cfg.rel_finalidade || defFinalidade;
    document.getElementById('c_rel_fund_ldb').value = cfg.rel_fund_ldb || defFundLDB;
    document.getElementById('c_rel_fund_eca').value = cfg.rel_fund_eca || defFundECA;
    document.getElementById('c_rel_fund_aplicacao').value = cfg.rel_fund_aplicacao || defFundAplicacao;
    document.getElementById('c_rel_prox_aberto').value = cfg.rel_prox_aberto || 'Caso em andamento. Aguardar novas providências a serem registradas conforme o desenvolvimento do acompanhamento.';
    document.getElementById('c_rel_prox_fechado').value = cfg.rel_prox_fechado || 'Acompanhamento concluído. As providências previstas foram finalizadas.';
    document.getElementById('c_rel_prox_arquivado').value = cfg.rel_prox_arquivado || 'Caso arquivado. Mantido para fins de registro e consulta.';
    document.getElementById('c_rel_orgao_resp').value = cfg.rel_orgao_resp || 'Secretaria de Educação e Inovação Pedagógica — Prefeitura Municipal de Goiana';
    document.getElementById('c_rel_unidade_resp').value = cfg.rel_unidade_resp || 'Coordenação de Acompanhamento e Busca Ativa Escolar';
    window._configAtual = cfg;
}

// ---------------- PERSONALIZAÇÃO DO CHAT ----------------
function montarConfigChat(cfg, buster = '') {
    cfg = cfg || {};
    return {
        chat_bg_color: cfg.chat_bg_color || '#e5ddd5',
        chat_bubble_sent: cfg.chat_bubble_sent || '#dcf8c6',
        chat_bubble_received: cfg.chat_bubble_received || '#ffffff',
        chat_header_color: cfg.chat_header_color || '#075e54',
        chat_bg_image_url: cfg.tem_chat_bg_image ? `${API}/config/chat-bg${buster}` : null
    };
}

function aplicarConfigChat() {
    const c = window._configChat || montarConfigChat({});
    const root = document.documentElement.style;
    root.setProperty('--chat-bg', c.chat_bg_color);
    root.setProperty('--chat-bubble-sent', c.chat_bubble_sent);
    root.setProperty('--chat-bubble-received', c.chat_bubble_received);
    root.setProperty('--chat-header', c.chat_header_color);
    const chatMsgs = document.getElementById('timelineMensagens');
    if (chatMsgs) {
        chatMsgs.style.backgroundImage = c.chat_bg_image_url ? `url('${c.chat_bg_image_url}')` : '';
        chatMsgs.classList.toggle('tem-fundo-imagem', !!c.chat_bg_image_url);
    }
}

function previewChatBg(input) {
    const file = input.files && input.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = e => {
        document.getElementById('previewChatBgImg').src = e.target.result;
        document.getElementById('previewChatBgBox').style.display = 'block';
        document.getElementById('c_chat_bg_image_remover').checked = false;
        atualizarPreviewChatAoVivo();
    };
    reader.readAsDataURL(file);
}

function atualizarPreviewChatAoVivo() {
    const val = (id, padrao) => (document.getElementById(id) || {}).value || padrao;
    const pa = document.getElementById('chatPreviewArea');
    const ph = document.getElementById('chatPreviewHeader');
    if (pa) {
        pa.style.backgroundColor = val('c_chat_bg_color', '#e5ddd5');
        const remover = document.getElementById('c_chat_bg_image_remover').checked;
        const box = document.getElementById('previewChatBgBox');
        const img = document.getElementById('previewChatBgImg');
        pa.style.backgroundImage = (!remover && box.style.display !== 'none' && img.src) ? `url('${img.src}')` : '';
        document.getElementById('chatPreviewRecebida').style.background = val('c_chat_bubble_received', '#ffffff');
        document.getElementById('chatPreviewEnviada').style.background = val('c_chat_bubble_sent', '#dcf8c6');
    }
    if (ph) ph.style.background = val('c_chat_header_color', '#075e54');
}

function previewLogoPdf(input) {
    if (!input.files || !input.files[0]) return;
    const reader = new FileReader();
    reader.onload = e => {
        document.getElementById('previewLogoPdf').src = e.target.result;
        document.getElementById('previewLogoPdfBox').style.display = 'block';
    };
    reader.readAsDataURL(input.files[0]);
}

function lerArquivoComoBase64(arquivo) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(arquivo);
    });
}

async function salvarConfig() {
    const tituloLoginVal = document.getElementById('c_titulo_login').value.trim();
    const tituloInternoVal = document.getElementById('c_titulo_interno').value.trim();
    if (!tituloLoginVal || !tituloInternoVal) {
        alerta('configAlerta', 'warning', '⚠️ Título da Tela de Login e Título do Cabeçalho Interno não podem ficar em branco. Recarregando os valores atuais...');
        carregarConfigForm();
        return;
    }

    const logoFile = document.getElementById('c_logo').files[0];
    let logoBase64 = null;
    if (logoFile) logoBase64 = await lerArquivoComoBase64(logoFile);

    const fundoLoginFile = document.getElementById('c_fundo_login').files[0];
    let fundoLoginBase64 = null;
    if (fundoLoginFile) fundoLoginBase64 = await lerArquivoComoBase64(fundoLoginFile);

    const logoPdfFile = document.getElementById('c_logo_pdf').files[0];
    let logoPdfBase64 = null;
    if (logoPdfFile) logoPdfBase64 = await lerArquivoComoBase64(logoPdfFile);

    const chatBgFile = document.getElementById('c_chat_bg_image').files[0];
    let chatBgBase64 = null;
    if (chatBgFile) chatBgBase64 = await lerArquivoComoBase64(chatBgFile);

    // Data/hora manual
    const modoHora = document.querySelector('input[name="modoHora"]:checked').value;
    let dataHoraManual = null;
    if (modoHora === 'manual') {
        dataHoraManual = lerCamposHoraManual();
        if (!dataHoraManual) {
            alerta('configAlerta', 'warning', '⚠️ Data/hora manual inválida. Verifique dia, mês, ano, hora e minuto.');
            return;
        }
    }

    const dados = {
        titulo_login: document.getElementById('c_titulo_login').value,
        subtitulo_login: document.getElementById('c_subtitulo_login').value,
        titulo_interno: document.getElementById('c_titulo_interno').value,
        logo_base64: logoBase64,
        cor_cabecalho: document.getElementById('c_cor_cabecalho').value,
        cor_menu: document.getElementById('c_cor_menu').value,
        cor_texto_cabecalho: document.getElementById('c_cor_texto_cabecalho').value,
        cor_destaque: document.getElementById('c_cor_destaque').value,
        imagem_fundo_login: fundoLoginBase64,
        rodape_texto: document.getElementById('c_rodape_texto').value,
        cabecalho_pdf_texto: document.getElementById('c_cabecalho_pdf_texto').value,
        rodape_pdf_texto: document.getElementById('c_rodape_pdf_texto').value,
        logo_pdf_base64: logoPdfBase64,
        tamanho_logo_pdf: parseInt(document.getElementById('c_tamanho_logo_pdf').value, 10) || 60,
        modo_hora: modoHora,
        data_hora_manual: dataHoraManual,
        chat_bg_color: document.getElementById('c_chat_bg_color').value || '#e5ddd5',
        chat_bubble_sent: document.getElementById('c_chat_bubble_sent').value || '#dcf8c6',
        chat_bubble_received: document.getElementById('c_chat_bubble_received').value || '#ffffff',
        chat_header_color: document.getElementById('c_chat_header_color').value || '#075e54',
        chat_bg_image_base64: chatBgBase64,
        chat_bg_image_remover: document.getElementById('c_chat_bg_image_remover').checked,
        rel_finalidade: document.getElementById('c_rel_finalidade').value,
        rel_fund_ldb: document.getElementById('c_rel_fund_ldb').value,
        rel_fund_eca: document.getElementById('c_rel_fund_eca').value,
        rel_fund_aplicacao: document.getElementById('c_rel_fund_aplicacao').value,
        rel_prox_aberto: document.getElementById('c_rel_prox_aberto').value,
        rel_prox_fechado: document.getElementById('c_rel_prox_fechado').value,
        rel_prox_arquivado: document.getElementById('c_rel_prox_arquivado').value,
        rel_orgao_resp: document.getElementById('c_rel_orgao_resp').value,
        rel_unidade_resp: document.getElementById('c_rel_unidade_resp').value
    };
    const res = await fetchComAuth(`config`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(dados)
    });
    if (res.ok) {
        alerta('configAlerta', 'success', 'Configurações atualizadas!');
        await sincronizarRelogio();
        const imgAnterior = window._configChat ? window._configChat.chat_bg_image_url : null;
        window._configChat = {
            chat_bg_color: dados.chat_bg_color,
            chat_bubble_sent: dados.chat_bubble_sent,
            chat_bubble_received: dados.chat_bubble_received,
            chat_header_color: dados.chat_header_color,
            chat_bg_image_url: dados.chat_bg_image_remover ? null : (chatBgBase64 || imgAnterior)
        };
        aplicarConfigChat();
        document.getElementById('c_chat_bg_image').value = '';
        if (dados.chat_bg_image_remover) {
            document.getElementById('c_chat_bg_image_remover').checked = false;
            document.getElementById('previewChatBgBox').style.display = 'none';
            atualizarPreviewChatAoVivo();
        }
        carregarConfigVisual(true);
    } else {
        alerta('configAlerta', 'error', 'Erro ao salvar configurações.');
    }
}

// ---------------- CONSULTA E ACOMPANHAMENTO ----------------
let alunoAtualPerfil = null;
let casoAtual = null;

async function carregarPainelConsulta() {
    const res = await fetchComAuth(`acompanhamentos/abertos`);
    const data = await res.json();
    document.getElementById('qtdAbertos').innerText = data.total;
    document.getElementById('qtdAtrasados').innerText = data.atrasados;
    window._casosAbertosCache = data.casos;

    const resEst = await fetchComAuth(`acompanhamentos/estatisticas`);
    const est = await resEst.json();
    document.getElementById('qtdFechados').innerText = est.total_fechados;
}

function abrirPainelAbertos() {
    renderizarListaCasos(window._casosAbertosCache || [], 'Casos Abertos', 'aberto');
}

function abrirPainelAtrasados() {
    const atrasados = (window._casosAbertosCache || []).filter(c => c.atrasado);
    renderizarListaCasos(atrasados, 'Casos Atrasados', 'aberto');
}

async function abrirPainelFechados() {
    const res = await fetchComAuth(`acompanhamentos/fechados`);
    const data = await res.json();
    renderizarListaCasos(data.casos, 'Casos Fechados', 'fechado');
}

function renderizarListaCasos(casos, titulo, modo) {
    document.getElementById('tituloListaCasos').innerText = titulo;
    const corTexto = { alta: '#b91c1c', media: '#92400e', baixa: '#047857' };
    const corFundo = { alta: '#fee2e2', media: '#fef3c7', baixa: '#d1fae5' };

    document.getElementById('listaCasosCards').innerHTML = casos.map(c => {
        const infoExtra = modo === 'fechado'
            ? `Fechado em ${c.fechado_em ? new Date(c.fechado_em).toLocaleDateString('pt-BR') : '—'} · ${c.dias_duracao ?? '—'} dia(s) de duração`
            : `${c.dias_aberto} dia(s) em aberto${c.atrasado ? ' · ⏰ atrasado' : ''}`;
        return `
        <div style="display:flex; align-items:center; gap:16px; background:#FFFFFF; border:1px solid #e2e8f0; border-radius:12px; padding:14px 18px; cursor:pointer;" onclick="abrirPerfilAlunoPorId(${c.aluno_id})">
            ${avatarHtml(c.aluno_nome, c.aluno_tem_foto ? `${API}/alunos/${c.aluno_id}/foto` : null, 44)}
            <div style="flex:1; min-width:0;">
                <p style="font-size:15px; font-weight:700; color:#0f172a; margin:0 0 2px 0;">${esc(c.aluno_nome)}${c.sigiloso ? ' 🔒' : ''}</p>
                <p style="font-size:13px; color:#64748b; margin:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;">${esc(c.escola_origem)} — ${esc(c.motivo)}</p>
                <p style="font-size:12px; color:#94a3b8; margin:4px 0 0 0;">${infoExtra}</p>
            </div>
            <span style="background:${corFundo[c.urgencia] || '#f1f5f9'}; color:${corTexto[c.urgencia] || '#64748b'}; font-size:11px; font-weight:700; padding:5px 11px; border-radius:999px; white-space:nowrap; flex-shrink:0;">${esc(String(c.urgencia).toUpperCase())}</span>
            <button class="btn-secondary" style="flex-shrink:0;" onclick="event.stopPropagation(); abrirPerfilAlunoPorId(${c.aluno_id})">Ver</button>
        </div>`;
    }).join('') || '<p style="text-align:center; color:#64748b; padding:20px 0;">Nenhum caso encontrado.</p>';

    document.getElementById('painelListaCasos').style.display = 'block';
}

function fecharPainelListaCasos() {
    document.getElementById('painelListaCasos').style.display = 'none';
}

function exportarCasosAbertos() {
    baixarArquivo(`acompanhamentos/exportar`);
}

let buscaAlunosTimeout = null;
function buscarAlunos(valor) {
    clearTimeout(buscaAlunosTimeout);
    if (!valor || valor.trim().length < 2) {
        document.getElementById('resultadoBuscaAlunos').innerHTML = '';
        return;
    }
    buscaAlunosTimeout = setTimeout(async () => {
        const res = await fetchComAuth(`alunos/busca?q=${encodeURIComponent(valor)}`);
        const resultados = await res.json();
        document.getElementById('resultadoBuscaAlunos').innerHTML = resultados.map(a => `
            <div style="display:flex; align-items:center; gap:12px; padding:10px 14px; border-bottom:1px solid #e2e8f0; cursor:pointer;" onclick="abrirPerfilAlunoPorId(${a.id})">
                ${avatarHtml(a.nome, a.tem_foto ? `${API}/alunos/${a.id}/foto` : null, 36)}
                <div style="flex:1; min-width:0;">
                    <b>${esc(a.nome)}</b><br>
                    <span style="color:#64748b; font-size:0.85rem;">${esc(a.cpf)} — ${esc(a.escola_origem)} — ${esc(a.turma)}</span>
                </div>
                ${a.tem_caso_aberto ? '<span style="color:#dc2626; font-weight:600; font-size:0.8rem; white-space:nowrap;">🔴 Caso Aberto</span>' : ''}
            </div>`).join('') || '<p style="color:#64748b;">Nenhum aluno encontrado.</p>';
    }, 300);
}

async function abrirPerfilAlunoPorId(alunoId) {
    document.getElementById('painelListaCasos').style.display = 'none';
    const res = await fetchComAuth(`alunos/${alunoId}/perfil`);
    if (!res.ok) { alert('Erro ao carregar perfil do aluno.'); return; }
    alunoAtualPerfil = await res.json();
    // Troca a view: esconde consulta e mostra perfil inline
    document.getElementById('painelConsultaView').style.display = 'none';
    document.getElementById('painelPerfilInline').style.display = 'block';
    document.getElementById('painelPerfilAluno').scrollTop = 0;
    await renderizarPerfilAluno();
}

function fecharPainelPerfilAluno() {
    document.getElementById('painelPerfilInline').style.display = 'none';
    document.getElementById('painelConsultaView').style.display = 'block';
    alunoAtualPerfil = null;
    casoAtual = null;
}

function fecharModalSeClicouFora(e) {
    if (e.target === document.getElementById('modalMinhaConta')) fecharMinhaConta();
}

document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    if (document.getElementById('modalResetSenha').style.display === 'flex') return fecharResetSenha();
    if (document.getElementById('modalCasoArquivado').style.display === 'flex') return fecharCasoArquivado();
    if (document.getElementById('modalMinhaConta').style.display === 'flex') return fecharMinhaConta();
    if (document.getElementById('painelPerfilInline').style.display !== 'none') return fecharPainelPerfilAluno();
});

async function carregarDetalheCaso(casoId) {
    const res = await fetchComAuth(`acompanhamentos/${casoId}`);
    if (!res.ok) return null;
    return await res.json();
}

async function renderizarPerfilAluno() {
    const a = alunoAtualPerfil;
    document.getElementById('nomeAlunoPerfil').innerText = a.nome;
    document.getElementById('infoAlunoPerfil').innerText = `CPF: ${a.cpf} — ${a.escola_origem} — Turma: ${a.turma}`;

    if (a.tem_foto) {
        const imgPerfil = document.getElementById('fotoAlunoPerfil');
        imgPerfil.style.display = 'none';
        document.getElementById('iconeAlunoPerfil').style.display = 'flex';
        document.getElementById('btnExcluirFoto').style.display = 'inline-block';
        carregarImagemAutenticada(`${API}/alunos/${a.id}/foto`).then(blobUrl => {
            if (!blobUrl || !alunoAtualPerfil || alunoAtualPerfil.id !== a.id) return;
            imgPerfil.src = blobUrl;
            imgPerfil.style.display = 'block';
            document.getElementById('iconeAlunoPerfil').style.display = 'none';
        });
    } else {
        document.getElementById('fotoAlunoPerfil').removeAttribute('src');
        document.getElementById('fotoAlunoPerfil').style.display = 'none';
        document.getElementById('iconeAlunoPerfil').style.display = 'flex';
        document.getElementById('btnExcluirFoto').style.display = 'none';
    }

    const casoAbertoResumo = a.casos.find(c => c.status === 'aberto');
    if (casoAbertoResumo) {
        const detalhe = await carregarDetalheCaso(casoAbertoResumo.id);
        renderizarCasoAtual(detalhe);
    } else {
        renderizarCasoAtual(null);
    }
    renderizarHistoricoCasos(a.casos.filter(c => !casoAbertoResumo || c.id !== casoAbertoResumo.id));
}

async function enviarFotoAluno() {
    const arquivo = document.getElementById('inputFotoAluno').files[0];
    if (!arquivo) return;
    const base64 = await lerArquivoComoBase64(arquivo);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`alunos/${alunoAtualPerfil.id}/foto`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ foto: base64 })
    });
    if (res.ok) {
        alunoAtualPerfil.tem_foto = true;
        const idFoto = alunoAtualPerfil.id;
        invalidarCacheFotoAluno(idFoto);
        const urlFoto = `${API}/alunos/${idFoto}/foto`;
        carregarImagemAutenticada(urlFoto).then(blobUrl => {
            if (!blobUrl || !alunoAtualPerfil || alunoAtualPerfil.id !== idFoto) return;
            document.getElementById('fotoAlunoPerfil').src = blobUrl;
            document.getElementById('fotoAlunoPerfil').style.display = 'block';
            document.getElementById('iconeAlunoPerfil').style.display = 'none';
        });
        document.getElementById('btnExcluirFoto').style.display = 'inline-block';
    } else {
        alerta('alertaPerfilAluno', 'error', 'Erro ao enviar a foto.');
    }
}

async function excluirFotoAluno() {
    if (!confirm('Remover a foto deste aluno?')) return;
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`alunos/${alunoAtualPerfil.id}/foto`, { method: 'DELETE' });
    if (res.ok) {
        alunoAtualPerfil.tem_foto = false;
        invalidarCacheFotoAluno(alunoAtualPerfil.id);
        document.getElementById('fotoAlunoPerfil').removeAttribute('src');
        document.getElementById('fotoAlunoPerfil').style.display = 'none';
        document.getElementById('iconeAlunoPerfil').style.display = 'flex';
        document.getElementById('btnExcluirFoto').style.display = 'none';
    } else {
        alerta('alertaPerfilAluno', 'error', 'Erro ao remover a foto.');
    }
}

const ICONE_CADEADO = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" width="11" height="11"><rect x="5" y="11" width="14" height="9" rx="2"></rect><path d="M8 11V7a4 4 0 0 1 8 0v4"></path></svg>';
const ICONE_BANDEIRA = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" width="12" height="12"><path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"></path><line x1="4" y1="22" x2="4" y2="15"></line></svg>';
const ICONE_PDF = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="15" height="15" style="vertical-align:-2px; margin-right:6px;"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><path d="M14 2v6h6"></path></svg>';
const ICONE_ENVIAR = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="14" height="14" style="vertical-align:-2px; margin-right:6px;"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg>';

function iniciaisNome(nome) {
    return (nome || '')
        .split('(')[0]
        .trim()
        .split(' ')
        .filter(Boolean)
        .slice(0, 2)
        .map(p => p[0])
        .join('')
        .toUpperCase();
}

function renderizarCasoAtual(caso) {
    casoAtual = caso;
    const container = document.getElementById('casoAtualContainer');

    if (!caso) {
        container.innerHTML = `
            <div class="import-card">
                <h2 style="margin-top:0;">Nenhum acompanhamento aberto</h2>
                <div class="form-grid">
                    <div class="form-group full-width">
                        <label>Motivo</label>
                        <input type="text" id="novoMotivo" placeholder="Descreva brevemente o motivo">
                    </div>
                    <div class="form-group">
                        <label>Categoria do Motivo</label>
                        <select id="novaCategoriaMotivo">${CATEGORIAS_MOTIVO.map(c => `<option>${c}</option>`).join('')}</select>
                    </div>
                    <div class="form-group">
                        <label>Urgência</label>
                        <select id="novaUrgencia">
                            <option value="baixa">Baixa</option>
                            <option value="media" selected>Média</option>
                            <option value="alta">Alta</option>
                        </select>
                    </div>
                    <div class="form-group full-width">
                        <label>Data Prevista de Retorno (opcional)</label>
                        <input type="date" id="novaDataRetorno">
                    </div>
                </div>
                <p style="color:#64748b; font-size:0.8rem;">⚠️ Motivos "Saúde" e "Violência/Negligência" tornam o caso automaticamente sigiloso, visível apenas ao Coordenador de Acompanhamento e ao Administrador.</p>
                <button class="btn-primary" style="margin-top:12px;" onclick="abrirNovoAcompanhamento()">📂 Abrir Acompanhamento</button>
            </div>`;
        return;
    }

    const badgeCor = { alta: '#b91c1c', media: '#92400e', baixa: '#047857' };
    const badgeBg = { alta: '#fee2e2', media: '#fef3c7', baixa: '#d1fae5' };
    // Casos de ano letivo encerrado ficam somente-leitura (exceto para o Administrador)
    const casoArquivado = !!(caso.arquivado || caso.status === 'arquivado');
    const somenteLeitura = casoArquivado && currentUser.perfil !== 'Administrador';
    const podeEditar = caso.pode_editar && !somenteLeitura;
    const podeReabrir = caso.pode_reabrir && !somenteLeitura;
    const numero = String(caso.id).padStart(4, '0');

    let acoes = `<button class="btn-secondary" onclick="gerarRelatorioPdfCaso(${caso.id})">${ICONE_PDF}Gerar Relatório PDF</button>`;
    if (somenteLeitura) {
        acoes += `<span class="badge-pill" style="background:#fef9c3; color:#92400e;">🔒 Ano letivo encerrado — somente leitura</span>`;
    } else if (caso.status === 'aberto') {
        acoes += `<button class="btn-danger" onclick="fecharAcompanhamento(${caso.id})">Fechar Acompanhamento</button>`;
    } else if (podeReabrir) {
        acoes += `<button class="btn-primary" onclick="reabrirAcompanhamento(${caso.id})">Reabrir Acompanhamento</button>`;
    }

    const ticketHeader = `
        <div class="ticket-header">
            <div>
                <p style="font-family:'JetBrains Mono', monospace; font-size:12px; color:#94a3b8; margin:0 0 6px 0; letter-spacing:0.02em;">ACOMPANHAMENTO Nº ${numero}</p>
                <h3 style="font-family:'Sora',sans-serif; font-size:19px; font-weight:700; margin:0 0 10px 0; color:#0f172a;">${esc(caso.motivo)}</h3>
                <div style="display:flex; gap:6px; flex-wrap:wrap;">
                    <span class="badge-pill" style="background:${caso.status === 'aberto' ? '#d1fae5' : '#e2e8f0'}; color:${caso.status === 'aberto' ? '#047857' : '#475569'};">${caso.status === 'aberto' ? 'ABERTO' : (caso.status === 'arquivado' ? 'ARQUIVADO' : 'FECHADO')}</span>
                    ${casoArquivado ? `<span class="badge-pill" style="background:#fef9c3; color:#92400e;">📦 ANO LETIVO ${caso.ano_letivo || ''} ARQUIVADO</span>` : ''}
                    <span class="badge-pill" style="background:${badgeBg[caso.urgencia]}; color:${badgeCor[caso.urgencia]};">URGÊNCIA ${esc(String(caso.urgencia).toUpperCase())}</span>
                    ${caso.sigiloso ? `<span class="badge-pill" style="background:#ede9fe; color:#6d28d9;">${ICONE_CADEADO} SIGILOSO</span>` : ''}
                </div>
            </div>
            <div style="display:flex; gap:10px; flex-wrap:wrap;">${acoes}</div>
        </div>`;

    const camposSidebar = `
        <div class="ticket-field"><span class="ticket-field-label">Categoria do motivo</span><span class="ticket-field-value">${esc(caso.categoria_motivo)}</span></div>
        <div class="ticket-field"><span class="ticket-field-label">Urgência</span><span class="ticket-field-value" style="color:${badgeCor[caso.urgencia]};">${esc(caso.urgencia.charAt(0).toUpperCase() + caso.urgencia.slice(1))}</span></div>
        <div class="ticket-field"><span class="ticket-field-label">Aberto por</span><span class="ticket-field-value">${esc(caso.criado_por)}</span></div>
        <div class="ticket-field"><span class="ticket-field-label">Data de abertura</span><span class="ticket-field-value">${new Date(caso.criado_em).toLocaleString('pt-BR')}</span></div>
        ${caso.data_prevista_retorno ? `<div class="ticket-field"><span class="ticket-field-label">Retorno previsto</span><span class="ticket-field-value">${new Date(caso.data_prevista_retorno).toLocaleDateString('pt-BR')}</span></div>` : ''}
        ${caso.fechado_em ? `<div class="ticket-field"><span class="ticket-field-label">Fechado por</span><span class="ticket-field-value">${esc(caso.fechado_por)}</span></div><div class="ticket-field"><span class="ticket-field-label">Data de fechamento</span><span class="ticket-field-value">${new Date(caso.fechado_em).toLocaleString('pt-BR')}</span></div>` : ''}
        ${caso.reaberto_em ? `<div class="ticket-field"><span class="ticket-field-label">Reaberto por</span><span class="ticket-field-value">${esc(caso.reaberto_por)} em ${new Date(caso.reaberto_em).toLocaleDateString('pt-BR')}</span></div>` : ''}
    `;

    let composer;
    if (caso.status === 'aberto' && !somenteLeitura) {
        composer = `
            <div class="chat-composer">
                <div class="chat-composer-selects">
                    <select id="novaMsgCategoria" title="Categoria da mensagem">${CATEGORIAS_MENSAGEM.map(c => `<option>${c}</option>`).join('')}</select>
                    <label style="display:flex; align-items:center; gap:6px; font-size:0.82rem; font-weight:600; color:#334155; white-space:nowrap;">
                        <input type="checkbox" id="novaMsgEncaminhamento" style="width:auto;" onchange="toggleEncaminhamentoWrap(this.checked)">
                        📋 Encaminhamento Oficial
                    </label>
                </div>
                <div class="chat-composer-encaminhamento" id="destinoEncaminhamentoWrap">
                    <label for="novaMsgDestino" style="font-weight:600;">Encaminhar para:</label>
                    <select id="novaMsgDestino">${DESTINOS_ENCAMINHAMENTO.map(d => `<option>${d}</option>`).join('')}</select>
                    <p style="color:#92400e; font-size:0.78rem; margin:0;">Encaminhamentos ao Conselho Tutelar são registrados nos termos do art. 56 do ECA.</p>
                </div>
                <div class="chat-file-preview" id="chatFilePreview"></div>
                <div class="chat-input-row">
                    <label class="chat-file-label" for="novaMsgAnexos" title="Anexar arquivos">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="20" height="20"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>
                    </label>
                    <input type="file" id="novaMsgAnexos" multiple onchange="atualizarPreviewAnexos()">
                    <textarea class="chat-textarea" id="novaMsgTexto" placeholder="Digite uma mensagem... (Enter envia, Shift+Enter quebra linha)" rows="1"
                        onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();enviarMensagemAcompanhamento();}"
                        oninput="this.style.height='auto';this.style.height=Math.min(this.scrollHeight,120)+'px'"></textarea>
                    <button class="chat-send-btn" id="btnEnviarMensagem" onclick="enviarMensagemAcompanhamento()" title="Enviar">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="20" height="20"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>
                    </button>
                </div>
            </div>`;
    } else if (somenteLeitura) {
        composer = `<div class="chat-readonly-banner">📦 Ano letivo arquivado — somente leitura</div>`;
    } else {
        composer = `<div class="chat-readonly-banner">🔒 Acompanhamento fechado — reabra para adicionar mensagens</div>`;
    }

    const mensagens = caso.mensagens || [];
    const msgsHtml = mensagens.length
        ? gerarDivisoresData(mensagens, podeEditar)
        : '<p style="text-align:center; color:#64748b; font-size:0.85rem; padding:24px 0; margin:auto 0;"><span style="background:rgba(255,255,255,0.85); padding:4px 12px; border-radius:8px;">Nenhuma mensagem registrada ainda.</span></p>';
    const nomeAluno = alunoAtualPerfil ? alunoAtualPerfil.nome : (caso.aluno_nome || 'Aluno');
    const fotoAluno = alunoAtualPerfil && alunoAtualPerfil.tem_foto ? `${API}/alunos/${alunoAtualPerfil.id}/foto` : null;
    const escolaAluno = alunoAtualPerfil ? (alunoAtualPerfil.escola_origem || '') : (caso.escola_origem || '');

    const corpo = `
        <div class="ticket-layout">
            <div class="chat-window">
                <div class="chat-header-bar">
                    ${avatarHtml(nomeAluno, fotoAluno, 38, 'border:2px solid rgba(255,255,255,0.5);')}
                    <div class="chat-header-info">
                        <p class="chat-header-name">${esc(nomeAluno)}</p>
                        <p class="chat-header-sub">${escolaAluno ? esc(escolaAluno) + ' · ' : ''}Acompanhamento #${numero} · ${mensagens.length} mensage${mensagens.length === 1 ? 'm' : 'ns'}</p>
                    </div>
                </div>
                <div class="chat-messages" id="timelineMensagens">
                    ${msgsHtml}
                </div>
                ${composer}
            </div>
            <div class="ticket-sidebar">${camposSidebar}</div>
        </div>`;

    container.innerHTML = ticketHeader + corpo;
    aplicarConfigChat();
    rolarChatParaFinal();
}

// Gera as mensagens do chat com separadores de data (estilo WhatsApp)
function gerarDivisoresData(mensagens, podeEditar) {
    let ultimaData = null;
    return mensagens.map(m => {
        const dt = new Date(m.data_hora);
        const d = isNaN(dt.getTime()) ? '' : dt.toLocaleDateString('pt-BR', { day: '2-digit', month: 'long', year: 'numeric' });
        const divisor = d && d !== ultimaData ? `<div class="chat-date-divider"><span>${d}</span></div>` : '';
        ultimaData = d;
        return divisor + renderizarMensagem(m, podeEditar);
    }).join('');
}

function rolarChatParaFinal() {
    const tl = document.getElementById('timelineMensagens');
    if (!tl) return;
    tl.scrollTop = tl.scrollHeight;
    setTimeout(() => { tl.scrollTop = tl.scrollHeight; }, 50);
    // Imagens de anexos carregam depois e aumentam a altura
    tl.querySelectorAll('img').forEach(img => img.addEventListener('load', () => { tl.scrollTop = tl.scrollHeight; }, { once: true }));
}

function toggleEncaminhamentoWrap(checked) {
    const el = document.getElementById('destinoEncaminhamentoWrap');
    if (el) el.style.display = checked ? 'flex' : 'none';
}

function atualizarPreviewAnexos() {
    const input = document.getElementById('novaMsgAnexos');
    const preview = document.getElementById('chatFilePreview');
    if (!input || !preview) return;
    preview.innerHTML = Array.from(input.files).map((f, i) => `
        <div class="file-chip">📎 ${esc(f.name)}
            <button type="button" onclick="removerAnexo(${i})" title="Remover">×</button>
        </div>`).join('');
}

function removerAnexo(idx) {
    const input = document.getElementById('novaMsgAnexos');
    if (!input) return;
    const dt = new DataTransfer();
    Array.from(input.files).forEach((f, i) => { if (i !== idx) dt.items.add(f); });
    input.files = dt.files;
    atualizarPreviewAnexos();
}

// Mensagem do chat no estilo WhatsApp: enviadas (usuário logado) à direita, recebidas à esquerda
function renderizarMensagem(m, podeEditar) {
    const autor = m.usuario_responsavel || '';
    const sou = !!currentUser && autor === `${currentUser.nome} (${currentUser.usuario})`;
    const lado = sou ? 'sent' : 'received';

    const anexosHtml = (m.anexos || []).map(x => {
        const isImg = x.tipo_mime && x.tipo_mime.startsWith('image/');
        return isImg
            ? `<a href="${urlAnexo(x.id)}" target="_blank"><img src="${urlAnexo(x.id)}" alt="${esc(x.nome_arquivo || 'Anexo')}"></a>`
            : `<a href="${urlAnexo(x.id)}" target="_blank" class="btn-secondary" style="display:inline-flex; align-items:center; gap:4px; padding:4px 10px; font-size:0.78rem; text-decoration:none;">📎 ${esc(x.nome_arquivo)}</a>`;
    }).join('');

    const encaminhamentoTag = m.encaminhamento_oficial
        ? `<div class="bubble-encaminhamento">${ICONE_BANDEIRA} Encaminhamento Oficial: ${esc(m.encaminhado_para)}${m.encaminhado_para === 'Conselho Tutelar' ? ' (art. 56 do ECA)' : ''}</div>`
        : '';

    const dt = new Date(m.data_hora);
    const hora = isNaN(dt.getTime()) ? '' : dt.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
    const dataCompleta = isNaN(dt.getTime()) ? '' : dt.toLocaleString('pt-BR');

    const acoes = podeEditar
        ? `<div class="bubble-actions">
                <button onclick="editarMensagem(${m.id})">✏️ Editar</button>
                <button class="btn-del" onclick="apagarMensagem(${m.id})">🗑️ Apagar</button>
           </div>`
        : '';

    const primeiroNome = autor.split(' (')[0].split(' ')[0];
    return `
        <div class="chat-bubble-wrap ${lado}">
            <div style="display:flex;flex-direction:column;align-items:center;gap:2px;flex-shrink:0;">
                ${avatarHtml(autor, fotoDeUsuario(autor), 28, 'flex-shrink:0;')}
                <span style="font-size:0.6rem;color:#64748b;white-space:nowrap;max-width:52px;overflow:hidden;text-overflow:ellipsis;text-align:center;">${esc(primeiroNome)}</span>
            </div>
            <div class="chat-bubble" title="${dataCompleta}">
                ${encaminhamentoTag}
                ${!sou ? `<p class="bubble-sender">${esc(autor.split(' (')[0])}</p>` : ''}
                <p class="bubble-category">${esc(m.categoria || '')}</p>
                <p class="bubble-text">${esc(m.texto || '').replace(/\n/g, '<br>')}</p>
                ${anexosHtml ? `<div class="bubble-anexos">${anexosHtml}</div>` : ''}
                ${acoes}
                <div class="bubble-meta">${m.editado_em ? '✏️ editada · ' : ''}${hora}${sou ? ' <span style="color:#34b7f1;">✓✓</span>' : ''}</div>
            </div>
        </div>`;
}

function renderizarHistoricoCasos(casosAnteriores) {
    const container = document.getElementById('historicoCasosContainer');
    if (!casosAnteriores.length) { container.innerHTML = ''; return; }
    const cards = casosAnteriores.map(c => {
        const statusLabel = c.status === 'aberto' ? '🟡 Em aberto' : (c.status === 'arquivado' ? '📦 Arquivado' : '🔴 Fechado');
        const dataAberto = new Date(c.criado_em).toLocaleDateString('pt-BR');
        const dataFechado = c.fechado_em ? new Date(c.fechado_em).toLocaleDateString('pt-BR') : null;
        return `
        <details style="margin-bottom:10px; border:1px solid #e2e8f0; border-radius:10px; overflow:hidden;" ontoggle="if(this.open) carregarMensagensHistorico(${c.id}, this)">
            <summary style="cursor:pointer; font-weight:600; padding:12px 16px; background:#f8fafc; display:flex; align-items:center; gap:10px; flex-wrap:wrap; list-style:none; user-select:none;">
                <span style="flex:1; min-width:180px;">${c.sigiloso ? '🔒 ' : ''}${esc(c.motivo)}</span>
                <span style="font-size:0.8rem; font-weight:400; color:#64748b;">${statusLabel} · Aberto em ${dataAberto}${dataFechado ? ' · Fechado em ' + dataFechado : ''}</span>
                <span style="color:#94a3b8; font-size:0.85rem; flex-shrink:0;">▼</span>
            </summary>
            <div style="padding:12px 16px;">
                <div style="display:flex; gap:8px; margin-bottom:12px; flex-wrap:wrap;">
                    <button class="btn-secondary" style="font-size:0.8rem; padding:5px 12px;" onclick="verCasoAnterior(${c.id})">🔍 Ver caso completo</button>
                    <button class="btn-secondary" style="font-size:0.8rem; padding:5px 12px;" onclick="gerarRelatorioPdfCaso(${c.id})">📄 Relatório PDF</button>
                </div>
                <div class="historico-mensagens" data-carregado="0"><p style="color:#94a3b8; font-size:0.85rem;">Carregando mensagens...</p></div>
            </div>
        </details>`;
    }).join('');

    container.innerHTML = `
        <h3 style="margin:0 0 12px; font-family:'Sora',sans-serif; font-size:1rem; color:#0f172a;">📁 Histórico de Casos Anteriores (${casosAnteriores.length})</h3>
        ${cards}`;
}

// Renderiza uma mensagem em formato compacto (histórico / casos arquivados — somente leitura)
function renderizarMensagemCompacta(m) {
    const autor = m.usuario_responsavel || '';
    const catBadge = m.categoria ? `<span style="background:#f1f5f9; color:#475569; border-radius:10px; padding:1px 8px; font-size:0.75rem; font-weight:600;">${esc(m.categoria)}</span>` : '';
    const encBadge = m.encaminhamento_oficial
        ? `<span style="background:#fef9c3; color:#92400e; border-radius:10px; padding:1px 8px; font-size:0.75rem; font-weight:600;">📤 ${esc(m.encaminhado_para)}</span>`
        : '';
    const anexos = (m.anexos || []).map(x =>
        `<a href="${urlAnexo(x.id)}" target="_blank" style="font-size:0.78rem; margin-right:8px;">📎 ${esc(x.nome_arquivo)}</a>`).join('');
    return `
        <div style="display:flex; gap:10px; align-items:flex-start; padding:8px 0; border-bottom:1px solid #f1f5f9;">
            ${avatarHtml(autor, fotoDeUsuario(autor), 30)}
            <div style="flex:1; min-width:0;">
                <div style="display:flex; flex-wrap:wrap; align-items:center; gap:6px; margin-bottom:3px;">
                    <span style="font-weight:600; font-size:0.82rem;">${esc(autor.split(' (')[0])}</span>
                    ${catBadge}${encBadge}
                    <span style="color:#94a3b8; font-size:0.78rem; margin-left:auto;">${m.data_hora ? new Date(m.data_hora).toLocaleString('pt-BR') : ''}</span>
                </div>
                <p style="margin:0; font-size:0.88rem; color:#334155; white-space:pre-wrap;">${esc(m.texto || '')}</p>
                ${anexos ? `<div style="margin-top:4px;">${anexos}</div>` : ''}
                ${m.editado_em ? `<span style="font-size:0.73rem; color:#94a3b8;">✏️ editado</span>` : ''}
            </div>
        </div>`;
}

async function carregarMensagensHistorico(casoId, detailsEl) {
    const alvo = detailsEl.querySelector('.historico-mensagens');
    if (!alvo || alvo.dataset.carregado === '1') return;
    alvo.dataset.carregado = '1';
    const caso = await carregarDetalheCaso(casoId);
    if (!caso) {
        alvo.innerHTML = '<p style="color:#dc2626; font-size:0.85rem;">Sem permissão para visualizar as mensagens deste acompanhamento.</p>';
        alvo.dataset.carregado = '0';
        return;
    }
    const msgs = caso.mensagens || [];
    alvo.innerHTML = `<p style="font-weight:600; margin:0 0 6px; font-size:0.85rem; color:#475569;">💬 Mensagens (${msgs.length})</p>` +
        (msgs.map(renderizarMensagemCompacta).join('') || '<p style="color:#94a3b8; font-size:0.85rem; padding:8px 0;">Nenhuma mensagem registrada neste caso.</p>');
}

async function verCasoAnterior(casoId) {
    const caso = await carregarDetalheCaso(casoId);
    if (!caso) { alerta('alertaPerfilAluno', 'error', 'Sem permissão para ver este acompanhamento.'); return; }
    renderizarCasoAtual(caso);
    document.getElementById('casoAtualContainer').scrollIntoView({ behavior: 'smooth' });
}

async function abrirNovoAcompanhamento() {
    const motivo = document.getElementById('novoMotivo').value.trim();
    const categoria_motivo = document.getElementById('novaCategoriaMotivo').value;
    const urgencia = document.getElementById('novaUrgencia').value;
    const data_prevista_retorno = document.getElementById('novaDataRetorno').value || null;
    if (!motivo) { alerta('alertaPerfilAluno', 'warning', 'Descreva o motivo do acompanhamento.'); return; }

    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`acompanhamentos`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ aluno_id: alunoAtualPerfil.id, motivo, categoria_motivo, urgencia, data_prevista_retorno })
    });
    if (res.ok) {
        await abrirPerfilAlunoPorId(alunoAtualPerfil.id);
        carregarPainelConsulta();
        carregarEstatisticasAcompanhamento();
    } else {
        const err = await res.json();
        alerta('alertaPerfilAluno', 'error', err.detail || 'Erro ao abrir acompanhamento.');
    }
}

async function enviarMensagemAcompanhamento() {
    const categoria = document.getElementById('novaMsgCategoria').value;
    const texto = document.getElementById('novaMsgTexto').value.trim();
    const encaminhamento_oficial = document.getElementById('novaMsgEncaminhamento').checked;
    const destino = encaminhamento_oficial ? document.getElementById('novaMsgDestino').value : '';
    const arquivos = document.getElementById('novaMsgAnexos').files;

    if (!texto && arquivos.length === 0) { alerta('alertaPerfilAluno', 'warning', 'Escreva uma mensagem ou anexe um arquivo.'); return; }

    const formData = new FormData();
    formData.append('usuario_responsavel', `${currentUser.nome} (${currentUser.usuario})`);
    formData.append('categoria', categoria);
    formData.append('texto', texto);
    formData.append('encaminhamento_oficial', encaminhamento_oficial);
    formData.append('encaminhado_para', destino);
    for (const arquivo of arquivos) formData.append('arquivos', arquivo);

    const btnEnviar = document.getElementById('btnEnviarMensagem');
    if (btnEnviar) btnEnviar.disabled = true;
    try {
        const res = await fetchComAuth(`acompanhamentos/${casoAtual.id}/mensagens`, { method: 'POST', body: formData });
        if (res.ok) {
            await abrirPerfilAlunoPorId(alunoAtualPerfil.id);
            rolarChatParaFinal();
        } else {
            alerta('alertaPerfilAluno', 'error', 'Erro ao adicionar mensagem.');
        }
    } catch (e) {
        alerta('alertaPerfilAluno', 'error', 'Erro de conexão ao adicionar mensagem.');
    } finally {
        if (btnEnviar && document.body.contains(btnEnviar)) btnEnviar.disabled = false;
    }
}

async function fecharAcompanhamento(casoId) {
    if (!confirm('Fechar este acompanhamento?')) return;
    const perfil = encodeURIComponent(currentUser.perfil);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`acompanhamentos/${casoId}/fechar`, { method: 'POST' });
    if (res.ok) {
        await abrirPerfilAlunoPorId(alunoAtualPerfil.id);
        carregarPainelConsulta();
        carregarEstatisticasAcompanhamento();
    } else {
        alerta('alertaPerfilAluno', 'error', 'Erro ao fechar acompanhamento.');
    }
}

async function reabrirAcompanhamento(casoId) {
    if (!confirm('Reabrir este acompanhamento?')) return;
    const perfil = encodeURIComponent(currentUser.perfil);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`acompanhamentos/${casoId}/reabrir`, { method: 'POST' });
    if (res.ok) {
        await abrirPerfilAlunoPorId(alunoAtualPerfil.id);
        carregarPainelConsulta();
        carregarEstatisticasAcompanhamento();
    } else {
        const err = await res.json();
        alerta('alertaPerfilAluno', 'error', err.detail || 'Erro ao reabrir acompanhamento.');
    }
}

async function editarMensagem(mensagemId) {
    const mensagem = (casoAtual.mensagens || []).find(m => m.id === mensagemId);
    if (!mensagem) return;
    const novoTexto = prompt('Editar mensagem:', mensagem.texto);
    if (novoTexto === null) return;
    const perfil = encodeURIComponent(currentUser.perfil);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`acompanhamentos/mensagens/${mensagemId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ texto: novoTexto, categoria: mensagem.categoria })
    });
    if (res.ok) {
        await abrirPerfilAlunoPorId(alunoAtualPerfil.id);
    } else {
        alerta('alertaPerfilAluno', 'error', 'Erro ao editar mensagem.');
    }
}

async function apagarMensagem(mensagemId) {
    if (!confirm('Apagar esta mensagem permanentemente?')) return;
    const perfil = encodeURIComponent(currentUser.perfil);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetchComAuth(`acompanhamentos/mensagens/${mensagemId}`, { method: 'DELETE' });
    if (res.ok) {
        await abrirPerfilAlunoPorId(alunoAtualPerfil.id);
    } else {
        alerta('alertaPerfilAluno', 'error', 'Erro ao apagar mensagem.');
    }
}

async function gerarRelatorioPdfCaso(casoId) {
    // Busca os dados do caso (usa casoAtual em cache se for o mesmo)
    const casoBruto = (casoAtual && casoAtual.id === casoId)
        ? casoAtual
        : await carregarDetalheCaso(casoId);
    if (!casoBruto) { alert('Não foi possível carregar os dados do caso.'); return; }

    // A página do relatório herda a sessão do sistema: todo texto vindo do servidor é escapado de uma vez
    const escaparDados = (o) => JSON.parse(JSON.stringify(o), (k, v) => typeof v === 'string' ? esc(v) : v);
    const caso = escaparDados(casoBruto);
    const aluno = escaparDados(alunoAtualPerfil || {});
    const cfg = escaparDados(window._configAtual || {});
    const logoUrl = cfg.tem_logo ? `${API}/config/logo` : null;

    // Helpers de formatação
    const fmtData = (d) => {
        if (!d) return '—';
        const dt = new Date(d);
        return isNaN(dt.getTime()) ? d : dt.toLocaleDateString('pt-BR');
    };
    const fmtDataHora = (d) => {
        if (!d) return '—';
        const dt = new Date(d);
        return isNaN(dt.getTime()) ? d : dt.toLocaleString('pt-BR');
    };
    const fmtHora = (d) => {
        if (!d) return '';
        const dt = new Date(d);
        return isNaN(dt.getTime()) ? '' : dt.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
    };
    const hoje = getDataHoraAtual().toLocaleDateString('pt-BR');
    const agora = getDataHoraAtual().toLocaleString('pt-BR');

    const statusLabel = {
        aberto: 'Em acompanhamento',
        fechado: 'Concluído',
        arquivado: 'Arquivado'
    }[caso.status] || caso.status || '—';

    const urgenciaLabel = { baixa: 'Baixa', media: 'Média', alta: 'Alta', prioritaria: 'Prioritária' }[caso.urgencia] || (caso.urgencia || '—');
    const numero = String(caso.id).padStart(4, '0');
    const numRelatorio = `REL-${getDataHoraAtual().getFullYear()}-${numero}`;

    const mensagens = caso.mensagens || [];
    const encaminhamentos = mensagens.filter(m => m.encaminhamento_oficial);
    const todosAnexos = mensagens.flatMap(m => (m.anexos || []).map(a => ({ ...a, msgData: m.data_hora, msgAutor: m.usuario_responsavel })));

    // Agrupa tipos de providências adotadas
    const tiposUsados = [...new Set(mensagens.map(m => m.categoria).filter(Boolean))];

    // Tabela de histórico de mensagens
    const linhasHistorico = mensagens.map((m, i) => {
        const enc = m.encaminhamento_oficial ? `Encaminhado para: ${m.encaminhado_para || '—'}` : '—';
        const nomeAutor = (m.usuario_responsavel || '').split(' (')[0];
        return `<tr>
            <td>${fmtData(m.data_hora)}</td>
            <td>${fmtHora(m.data_hora)}</td>
            <td>${m.categoria || '—'}</td>
            <td>${nomeAutor || '—'}</td>
            <td>${(m.texto || '').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>')}</td>
            <td>${enc}</td>
        </tr>`;
    }).join('');

    // Tabela de encaminhamentos
    const linhasEnc = encaminhamentos.length
        ? encaminhamentos.map(m => `<tr>
            <td>${fmtData(m.data_hora)}</td>
            <td>${m.encaminhado_para || '—'}</td>
            <td>${m.categoria || '—'}</td>
            <td>${(m.texto || '').substring(0, 120).replace(/</g,'&lt;').replace(/>/g,'&gt;')}${m.texto && m.texto.length > 120 ? '...' : ''}</td>
            <td>${(m.usuario_responsavel || '').split(' (')[0]}</td>
            <td>Registrado</td>
        </tr>`).join('')
        : '<tr><td colspan="6" style="text-align:center; color:#666;">Nenhum encaminhamento oficial registrado.</td></tr>';

    // Tabela de anexos/documentos
    const linhasAnexos = todosAnexos.length
        ? todosAnexos.map((a, i) => `<tr>
            <td style="text-align:right;">${String(i+1).padStart(2,'0')}</td>
            <td>${a.nome_arquivo || 'Arquivo'}</td>
            <td>${fmtData(a.msgData)}</td>
            <td>${(a.msgAutor || '').split(' (')[0]}</td>
            <td>Sim</td>
        </tr>`).join('')
        : '<tr><td colspan="5" style="text-align:center; color:#666; font-style:italic;">Não constam documentos anexos a este relatório.</td></tr>';

    // Última mensagem
    const ultimaMensagem = mensagens.length ? mensagens[mensagens.length - 1] : null;
    const ultimaProvidencia = ultimaMensagem ? (ultimaMensagem.texto || '').substring(0, 200) : '—';
    const ultimaAtualizacao = ultimaMensagem ? fmtDataHora(ultimaMensagem.data_hora) : '—';

    // Cabeçalho do PDF configurado
    const cabecalhoPdf = cfg.cabecalho_pdf_texto || '';

    const logoHtml = logoUrl
        ? `<img src="${logoUrl}" style="height:60px; max-width:120px; object-fit:contain;" alt="Logo">`
        : `<div style="width:60px; height:60px; background:#1e3a5f; border-radius:8px; display:flex; align-items:center; justify-content:center; color:white; font-size:24px; font-weight:900;">E</div>`;

    const html = `<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<title>Relatório de Acompanhamento — ${aluno.nome || 'Estudante'}</title>
<style>
  @page { size: A4 portrait; margin: 2.5cm 2cm 2cm 3cm; }
  * { box-sizing: border-box; }
  body { font-family: Arial, sans-serif; font-size: 10.5pt; color: #1a1a1a; background: #fff; line-height: 1.15; margin: 0; padding: 0; }
  h1 { font-size: 16pt; font-weight: 900; text-align: center; text-transform: uppercase; margin: 0 0 4px; letter-spacing: 0.03em; }
  h2.secao { font-size: 11pt; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; color: #1a1a1a; border-bottom: 2px solid #1e3a5f; padding-bottom: 4px; margin: 20px 0 10px; page-break-after: avoid; }
  h3.subsecao { font-size: 10.5pt; font-weight: 700; margin: 14px 0 6px; color: #1a1a1a; }
  p { margin: 0 0 6pt; text-align: justify; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 10px; font-size: 9.5pt; }
  th { background: #1e3a5f; color: #fff; font-weight: 700; padding: 5px 6px; text-align: left; font-size: 9pt; }
  td { border: 1px solid #d1d5db; padding: 4px 6px; vertical-align: top; }
  tr:nth-child(even) td { background: #f8fafc; }
  .cabecalho-inst { display: flex; align-items: center; gap: 20px; border-bottom: 3px solid #1e3a5f; padding-bottom: 12px; margin-bottom: 16px; }
  .cabecalho-inst-texto { flex: 1; }
  .cabecalho-inst-texto .prefeitura { font-size: 11pt; font-weight: 900; text-transform: uppercase; letter-spacing: 0.04em; color: #1e3a5f; margin: 0; }
  .cabecalho-inst-texto .secretaria { font-size: 10pt; font-weight: 700; text-transform: uppercase; color: #374151; margin: 2px 0 0; }
  .cabecalho-inst-texto .setor { font-size: 9pt; color: #6b7280; margin: 2px 0 0; }
  .titulo-relatorio { text-align: center; margin: 14px 0 6px; }
  .titulo-relatorio h1 { color: #1e3a5f; font-size: 15pt; }
  .meta-relatorio { border: 1px solid #d1d5db; border-radius: 6px; padding: 10px 14px; margin-bottom: 14px; display: flex; flex-wrap: wrap; gap: 8px 24px; background: #f9fafb; }
  .meta-relatorio .meta-item { font-size: 9.5pt; }
  .meta-relatorio .meta-label { font-weight: 700; color: #374151; }
  .badge { display: inline-block; font-size: 9pt; font-weight: 700; padding: 2px 8px; border-radius: 4px; text-transform: uppercase; letter-spacing: 0.03em; }
  .badge-aberto { background: #d1fae5; color: #065f46; }
  .badge-fechado { background: #e2e8f0; color: #374151; }
  .badge-arquivado { background: #fef9c3; color: #92400e; }
  .badge-baixa { background: #d1fae5; color: #065f46; }
  .badge-media { background: #fef3c7; color: #92400e; }
  .badge-alta { background: #fee2e2; color: #991b1b; }
  .badge-prioritaria { background: #ede9fe; color: #6d28d9; }
  .destaque-box { border: 1px solid #d1d5db; border-left: 4px solid #1e3a5f; padding: 8px 12px; margin: 10px 0; background: #f8fafc; font-size: 9.5pt; border-radius: 0 6px 6px 0; }
  .assinatura-linha { border-top: 1px solid #374151; width: 220px; margin: 32px 0 4px; }
  .rodape { margin-top: 24px; padding-top: 10px; border-top: 2px solid #1e3a5f; display: flex; justify-content: space-between; align-items: flex-end; font-size: 8pt; color: #6b7280; }
  .rodape-centro { text-align: center; flex: 1; }
  .divisor { border: none; border-top: 1px solid #e5e7eb; margin: 16px 0; }
  ul.providencias { margin: 4px 0 8px 18px; padding: 0; }
  ul.providencias li { margin-bottom: 3px; font-size: 9.5pt; }
  .texto-legal { font-size: 9.5pt; text-align: justify; margin-bottom: 8pt; }
  .sem-quebra { page-break-inside: avoid; }
  @media print {
    body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .no-print { display: none; }
    th { background: #1e3a5f !important; color: #fff !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  }
</style>
</head>
<body>

<!-- CABEÇALHO INSTITUCIONAL -->
<div class="cabecalho-inst">
  ${logoHtml}
  <div class="cabecalho-inst-texto">
    <p class="prefeitura">Prefeitura Municipal de Goiana</p>
    <p class="secretaria">Secretaria de Educação e Inovação Pedagógica</p>
    <p class="setor">Coordenação de Acompanhamento e Busca Ativa Escolar${cabecalhoPdf ? ' — ' + cabecalhoPdf : ''}</p>
  </div>
</div>

<!-- TÍTULO -->
<div class="titulo-relatorio">
  <h1>Relatório de Acompanhamento Escolar</h1>
</div>

<!-- META DO RELATÓRIO -->
<div class="meta-relatorio">
  <div class="meta-item"><span class="meta-label">Nº do Relatório:</span> ${numRelatorio}</div>
  <div class="meta-item"><span class="meta-label">Data de emissão:</span> ${hoje}</div>
  <div class="meta-item"><span class="meta-label">Emitido por:</span> ${currentUser ? esc(currentUser.nome) : '—'}</div>
  <div class="meta-item"><span class="meta-label">Status:</span>
    <span class="badge badge-${caso.status || 'aberto'}">${statusLabel}</span>
  </div>
  <div class="meta-item"><span class="meta-label">Urgência:</span>
    <span class="badge badge-${caso.urgencia || 'baixa'}">${urgenciaLabel}</span>
  </div>
</div>

<hr class="divisor">

<!-- 1. IDENTIFICAÇÃO -->
<h2 class="secao">1. Identificação do(a) Estudante</h2>
<table>
  <tr><th style="width:36%;">Campo</th><th>Informação</th></tr>
  <tr><td><b>Nome do(a) estudante</b></td><td>${aluno.nome || '—'}</td></tr>
  <tr><td><b>CPF</b></td><td>${aluno.cpf || '—'}</td></tr>
  <tr><td><b>Data de nascimento</b></td><td>${aluno.data_nasc ? fmtData(aluno.data_nasc) : (aluno.nascimento ? fmtData(aluno.nascimento) : '—')}</td></tr>
  <tr><td><b>Unidade escolar</b></td><td>${aluno.escola_origem || '—'}</td></tr>
  <tr><td><b>Ano/Série — Turma</b></td><td>${aluno.turma || '—'}</td></tr>
  <tr><td><b>Turno</b></td><td>${aluno.turno || 'Não informado'}</td></tr>
  <tr><td><b>Tipo de busca ativa</b></td><td>${aluno.tipo_busca || '—'}</td></tr>
  <tr><td><b>Endereço</b></td><td>${aluno.endereco || 'Não informado'}</td></tr>

  ${aluno.observacoes ? `<tr><td><b>Observações</b></td><td>${aluno.observacoes}</td></tr>` : ''}
</table>

<hr class="divisor">

<!-- 2. CARACTERIZAÇÃO DA SITUAÇÃO -->
<h2 class="secao">2. Caracterização da Situação</h2>
<table>
  <tr><th style="width:36%;">Campo</th><th>Informação</th></tr>
  <tr><td><b>Motivo do acompanhamento</b></td><td>${caso.motivo || '—'}</td></tr>
  <tr><td><b>Categoria do motivo</b></td><td>${caso.categoria_motivo || '—'}</td></tr>
  <tr><td><b>Data de abertura do caso</b></td><td>${fmtData(caso.criado_em)}</td></tr>
  <tr><td><b>Responsável pela abertura</b></td><td>${(caso.criado_por || '—').split(' (')[0]}</td></tr>
  <tr><td><b>Urgência</b></td><td><span class="badge badge-${caso.urgencia || 'baixa'}">${urgenciaLabel}</span></td></tr>
  <tr><td><b>Situação atual</b></td><td><span class="badge badge-${caso.status || 'aberto'}">${statusLabel}</span></td></tr>
  ${caso.data_prevista_retorno ? `<tr><td><b>Data prevista de retorno</b></td><td>${fmtData(caso.data_prevista_retorno)}</td></tr>` : ''}
  ${caso.fechado_em ? `<tr><td><b>Data de conclusão/fechamento</b></td><td>${fmtData(caso.fechado_em)}</td></tr><tr><td><b>Encerrado por</b></td><td>${(caso.fechado_por || '—').split(' (')[0]}</td></tr>` : ''}
  ${caso.reaberto_em ? `<tr><td><b>Reaberto por</b></td><td>${(caso.reaberto_por || '—').split(' (')[0]} em ${fmtData(caso.reaberto_em)}</td></tr>` : ''}
  ${caso.sigiloso ? `<tr><td><b>Sigilo</b></td><td>🔒 Caso sigiloso — acesso restrito</td></tr>` : ''}
  <tr><td><b>Total de registros no histórico</b></td><td>${mensagens.length} ocorrência(s)</td></tr>
</table>

<h3 class="subsecao">2.1. Descrição inicial da situação</h3>
<div class="destaque-box">
  ${(caso.motivo || 'Não informado').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>')}
</div>

<hr class="divisor">

<!-- 3. PROVIDÊNCIAS ADOTADAS -->
<h2 class="secao">3. Providências Adotadas</h2>
<p class="texto-legal">Registra-se abaixo o resumo das providências adotadas no âmbito deste acompanhamento. Cada providência está registrada de forma individualizada no histórico constante da seção 4.</p>
${tiposUsados.length ? `
<ul class="providencias">
  ${tiposUsados.map(t => `<li>${t}</li>`).join('')}
</ul>
` : '<p style="color:#666; font-size:9.5pt;">Nenhuma providência registrada até o momento.</p>'}
<p style="font-size:9pt; color:#4b5563; margin-top:6px;">Total de ocorrências registradas: <b>${mensagens.length}</b> — Encaminhamentos oficiais: <b>${encaminhamentos.length}</b></p>

<hr class="divisor">

<!-- 4. HISTÓRICO DE ACOMPANHAMENTO -->
<h2 class="secao">4. Histórico de Acompanhamento</h2>
<p class="texto-legal">Registro cronológico de todas as ocorrências, providências e ações realizadas no âmbito deste acompanhamento.</p>
${mensagens.length ? `
<table>
  <tr>
    <th style="width:9%;">Data</th>
    <th style="width:6%;">Horário</th>
    <th style="width:14%;">Tipo de ação</th>
    <th style="width:14%;">Responsável</th>
    <th>Registro / Resultado</th>
    <th style="width:14%;">Encaminhamento</th>
  </tr>
  ${linhasHistorico}
</table>
` : '<p style="color:#666; font-size:9.5pt; font-style:italic;">Nenhuma ocorrência registrada até o momento.</p>'}

<hr class="divisor">

<!-- 5. SITUAÇÃO ATUAL E ENCAMINHAMENTOS -->
<h2 class="secao">5. Situação Atual e Encaminhamentos</h2>

<h3 class="subsecao">5.1. Situação atual</h3>
<table>
  <tr><th style="width:36%;">Campo</th><th>Informação</th></tr>
  <tr><td><b>Situação</b></td><td><span class="badge badge-${caso.status || 'aberto'}">${statusLabel}</span></td></tr>
  <tr><td><b>Última atualização</b></td><td>${ultimaAtualizacao}</td></tr>
  <tr><td><b>Última providência realizada</b></td><td>${ultimaProvidencia.replace(/</g,'&lt;').replace(/>/g,'&gt;')}</td></tr>
</table>

<h3 class="subsecao">5.2. Encaminhamentos realizados</h3>
<table>
  <tr>
    <th style="width:9%;">Data</th>
    <th style="width:18%;">Órgão / Setor</th>
    <th style="width:14%;">Motivo</th>
    <th>Providência / Registro</th>
    <th style="width:14%;">Responsável</th>
    <th style="width:10%;">Situação</th>
  </tr>
  ${linhasEnc}
</table>

<h3 class="subsecao">5.3. Próximas providências</h3>
<div class="destaque-box">
  ${caso.status === 'aberto'
    ? (cfg.rel_prox_aberto || 'Caso em andamento. Aguardar novas providências a serem registradas conforme o desenvolvimento do acompanhamento.')
    : caso.status === 'fechado'
    ? (cfg.rel_prox_fechado || 'Acompanhamento concluído. As providências previstas foram finalizadas.')
    : (cfg.rel_prox_arquivado || 'Caso arquivado. Mantido para fins de registro e consulta.')}
</div>

<hr class="divisor">

<!-- 6. FINALIDADE DO PROCEDIMENTO -->
<h2 class="secao">6. Finalidade do Procedimento</h2>
${(cfg.rel_finalidade || 'Este relatório tem por finalidade registrar e sistematizar as providências adotadas pela Secretaria de Educação e Inovação Pedagógica, em articulação com a unidade escolar, para o acompanhamento da frequência escolar do(a) estudante, a verificação dos motivos das faltas e o registro das justificativas apresentadas pela família ou responsável legal.\n\nO procedimento busca documentar as ações realizadas para a identificação e o acompanhamento de situações de faltas injustificadas, infrequência escolar ou possível evasão, bem como os contatos e as providências adotadas junto à família, à unidade escolar e aos demais órgãos integrantes da rede de proteção.\n\nQuando, após a adoção das medidas de acompanhamento e das providências cabíveis no âmbito escolar, permanecer situação que demande atuação da rede de proteção, as informações registradas neste relatório poderão subsidiar o encaminhamento ao Conselho Tutelar, para conhecimento, acompanhamento e adoção das medidas que entender cabíveis, observadas as competências legais de cada órgão.\n\nO presente relatório constitui instrumento de registro, acompanhamento e documentação das providências realizadas pela Secretaria de Educação e Inovação Pedagógica, não substituindo os registros de frequência e demais documentos de responsabilidade da unidade escolar.').split('\n\n').filter(p => p.trim()).map(p => `<p class="texto-legal">${p.replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>')}</p>`).join('\n')}

<hr class="divisor">

<!-- 7. FUNDAMENTO LEGAL -->
<h2 class="secao">7. Fundamento Legal</h2>

<h3 class="subsecao">7.1. Lei Federal nº 9.394/1996 – Lei de Diretrizes e Bases da Educação Nacional (LDB)</h3>
<p class="texto-legal">${(cfg.rel_fund_ldb || 'O art. 12, inciso VIII, estabelece como incumbência dos estabelecimentos de ensino a notificação ao Conselho Tutelar do Município da relação dos alunos que apresentem quantidade de faltas acima do percentual permitido em lei.').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>')}</p>

<h3 class="subsecao">7.2. Lei Federal nº 8.069/1990 – Estatuto da Criança e do Adolescente (ECA)</h3>
<p class="texto-legal">${(cfg.rel_fund_eca || 'O art. 56, inciso II, estabelece que os dirigentes de estabelecimentos de ensino fundamental devem comunicar ao Conselho Tutelar os casos de reiteração de faltas injustificadas e de evasão escolar, esgotados os recursos escolares.').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>')}</p>

<h3 class="subsecao">7.3. Aplicação institucional</h3>
<p class="texto-legal">${(cfg.rel_fund_aplicacao || 'Considerando as competências legais dos diferentes órgãos envolvidos, este relatório possui caráter de registro, acompanhamento, sistematização e documentação das providências realizadas, podendo subsidiar os encaminhamentos necessários à rede de proteção, sem substituir os documentos e procedimentos próprios da unidade escolar ou dos demais órgãos competentes.').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>')}</p>

<hr class="divisor">

<!-- 8. DOCUMENTOS E COMPROVAÇÕES -->
<h2 class="secao">8. Documentos e Comprovações Anexas</h2>
<table>
  <tr>
    <th style="width:4%; text-align:right;">Nº</th>
    <th>Documento</th>
    <th style="width:10%;">Data</th>
    <th style="width:20%;">Origem</th>
    <th style="width:8%;">Anexo</th>
  </tr>
  ${linhasAnexos}
</table>

<hr class="divisor">

<!-- 9. OBSERVAÇÕES -->
<h2 class="secao">9. Observações</h2>
<div class="destaque-box" style="min-height:40px;">
  ${aluno.observacoes ? aluno.observacoes.replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>') : '<span style="color:#9ca3af; font-style:italic;">Nenhuma observação registrada.</span>'}
</div>

<hr class="divisor">

<!-- 10. RESPONSABILIDADE PELO REGISTRO -->
<h2 class="secao">10. Responsabilidade pelo Registro</h2>
<p class="texto-legal"><b>Órgão responsável pelo acompanhamento:</b><br>${(cfg.rel_orgao_resp || 'Secretaria de Educação e Inovação Pedagógica — Prefeitura Municipal de Goiana').replace(/</g,'&lt;').replace(/>/g,'&gt;')}</p>
<p class="texto-legal"><b>Unidade/Setor responsável:</b><br>${(cfg.rel_unidade_resp || 'Coordenação de Acompanhamento e Busca Ativa Escolar').replace(/</g,'&lt;').replace(/>/g,'&gt;')}</p>
<p class="texto-legal"><b>Servidor(a) responsável pelo registro:</b></p>
<div class="assinatura-linha"></div>
<p style="font-size:9.5pt; margin:0;">${currentUser ? esc(currentUser.nome) : '___________________________________'}</p>
<p style="font-size:9pt; color:#4b5563; margin:2px 0 14px;">${currentUser ? esc(currentUser.perfil) : 'Cargo/Função'}</p>
<p class="texto-legal"><b>Data de emissão:</b> ${hoje}</p>

<hr class="divisor">

<!-- RODAPÉ -->
<div class="rodape">
  <div>Prefeitura Municipal de Goiana<br>Secretaria de Educação e Inovação Pedagógica</div>
  <div class="rodape-centro">Relatório de Acompanhamento Escolar — Documento de uso institucional<br>${numRelatorio} — Emitido em ${agora}</div>
  <div style="text-align:right;">${aluno.nome || 'Estudante'}<br>Pág. 1</div>
</div>

</body>
</html>`;

    const janela = window.open('', '_blank');
    if (!janela) { alert('Permita popups para gerar o relatório em PDF.'); return; }
    janela.document.open();
    janela.document.write(html);
    janela.document.close();
    // Aciona impressão após o conteúdo carregar (sem <script> interno que quebra o parser)
    setTimeout(() => { try { janela.focus(); janela.print(); } catch(e) {} }, 400);
}

// ---------------- MINHA CONTA / FOTO DO USUÁRIO ----------------
function atualizarAvatarHeader() {
    const el = document.getElementById('avatarHeader');
    if (!el || !currentUser) return;
    const foto = fotoUsuarioLogado();
    el.innerHTML = foto ? `<img src="${foto}" alt="Foto">` : iniciaisNome(currentUser.nome);
    el.title = 'Minha Conta';
}

function atualizarPainelMinhaConta() {
    const foto = fotoUsuarioLogado();
    const av = document.getElementById('avatarMinhaConta');
    av.innerHTML = foto ? `<img src="${foto}" style="width:100%; height:100%; object-fit:cover;">` : iniciaisNome(currentUser.nome);
    document.getElementById('nomeMinhaConta').innerText = currentUser.nome;
    document.getElementById('perfilMinhaConta').innerText = `${currentUser.perfil} — usuário: ${currentUser.usuario}`;
    document.getElementById('btnRemoverFotoUsuario').style.display = foto ? 'inline-block' : 'none';
    document.getElementById('previewFotoUsuarioBox').style.display = foto ? 'block' : 'none';
    if (foto) document.getElementById('previewFotoUsuarioImg').src = foto;
}

function abrirMinhaConta() {
    if (!currentUser) return;
    atualizarPainelMinhaConta();
    document.getElementById('modalMinhaConta').style.display = 'flex';
    document.body.style.overflow = 'hidden';
}

function fecharMinhaConta() {
    document.getElementById('modalMinhaConta').style.display = 'none';
    document.body.style.overflow = '';
}

function aposAlterarFotoUsuario() {
    atualizarAvatarHeader();
    atualizarPainelMinhaConta();
    if (casoAtual && document.getElementById('painelPerfilInline').style.display !== 'none') renderizarCasoAtual(casoAtual);
}

async function salvarFotoUsuario(input) {
    const arquivo = input.files && input.files[0];
    if (!arquivo) return;
    if (!arquivo.type.startsWith('image/')) {
        alerta('alertaMinhaConta', 'error', 'Selecione um arquivo de imagem.');
        input.value = '';
        return;
    }
    try {
        const base64 = await lerArquivoComoBase64(arquivo);
        sessionStorage.setItem(chaveFotoUsuario(currentUser.usuario), base64);
        alerta('alertaMinhaConta', 'success', 'Foto de perfil atualizada!');
        aposAlterarFotoUsuario();
    } catch (err) {
        const cota = err && (err.name === 'QuotaExceededError' || err.code === 22);
        alerta('alertaMinhaConta', 'error', cota
            ? 'A imagem é muito grande para ser armazenada no navegador. Escolha uma imagem menor.'
            : 'Não foi possível carregar a imagem.');
    }
    input.value = '';
}

function removerFotoUsuario() {
    sessionStorage.removeItem(chaveFotoUsuario(currentUser.usuario));
    alerta('alertaMinhaConta', 'success', 'Foto de perfil removida.');
    aposAlterarFotoUsuario();
}

// ---------------- ANO LETIVO ----------------
function normalizarAnoArquivado(a) {
    return {
        ano: parseInt(a.ano ?? a.ano_letivo),
        fechado_em: a.fechado_em || a.data_fechamento || null,
        fechado_por: a.fechado_por || a.usuario_responsavel || '',
        casos: a.casos_snapshot || a.casos || []
    };
}

async function carregarSubtabAnoLetivo() {
    const sel = document.getElementById('anoLetivoSelect');
    const anoAtual = getDataHoraAtual().getFullYear();
    sel.innerHTML = [anoAtual, anoAtual - 1].map(a => `<option value="${a}">${a}</option>`).join('');
    document.getElementById('listaAnosArquivados').innerHTML = '<p style="color:#64748b;">Carregando...</p>';
    try {
        const res = await fetchComAuth(`ano-letivo/arquivados`);
        if (!res.ok) throw new Error();
        const data = await res.json();
        const lista = Array.isArray(data) ? data : (data.anos || data.arquivados || []);
        anosArquivados = lista.map(normalizarAnoArquivado).filter(a => !isNaN(a.ano)).sort((x, y) => y.ano - x.ano);
    } catch (e) {
        anosArquivados = [];
        document.getElementById('listaAnosArquivados').innerHTML = '<p style="color:#dc2626;">Erro ao carregar os anos letivos arquivados.</p>';
        return;
    }
    let primeiroLivre = null;
    Array.from(sel.options).forEach(opt => {
        const arquivado = anosArquivados.some(a => a.ano === parseInt(opt.value));
        opt.disabled = arquivado;
        if (arquivado) opt.textContent = `${opt.value} (encerrado)`;
        else if (primeiroLivre === null) primeiroLivre = opt.value;
    });
    if (primeiroLivre !== null) sel.value = primeiroLivre;
    sel.disabled = primeiroLivre === null;
    document.getElementById('btnFecharAnoLetivo').disabled = primeiroLivre === null;
    renderizarAnosArquivados();
}

async function confirmarFecharAnoLetivo() {
    const ano = parseInt(document.getElementById('anoLetivoSelect').value);
    if (isNaN(ano)) return;
    if (anosArquivados.some(a => a.ano === ano)) {
        alerta('alertaAnoLetivo', 'warning', `O ano letivo ${ano} já foi encerrado.`);
        return;
    }
    if (!confirm(`⚠️ Confirma o encerramento do Ano Letivo ${ano}?\n\nTodos os casos do ano serão arquivados em modo somente leitura. Esta ação não pode ser desfeita.`)) return;

    const usuario = `${currentUser.nome} (${currentUser.usuario})`;
    const btn = document.getElementById('btnFecharAnoLetivo');
    btn.disabled = true;
    try {
        const res = await fetchComAuth(`ano-letivo/fechar`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ano })
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) {
            alerta('alertaAnoLetivo', 'error', data.detail || 'Erro ao encerrar o ano letivo.');
            btn.disabled = false;
            return;
        }
        const qtd = data.casos_arquivados ?? data.total ?? null;
        alerta('alertaAnoLetivo', 'success', `✅ Ano Letivo ${ano} encerrado com sucesso!${qtd !== null ? ` ${qtd} caso(s) arquivado(s).` : ''}`);
        await carregarSubtabAnoLetivo();
        carregarPainelConsulta();
        carregarEstatisticasAcompanhamento();
    } catch (e) {
        alerta('alertaAnoLetivo', 'error', 'Erro de conexão ao encerrar o ano letivo.');
        btn.disabled = false;
    }
}

function formatarDataBr(v, comHora = false) {
    if (!v) return '—';
    const d = new Date(v);
    if (isNaN(d.getTime())) return '—';
    return comHora ? d.toLocaleString('pt-BR') : d.toLocaleDateString('pt-BR');
}

function renderizarAnosArquivados() {
    const lista = document.getElementById('listaAnosArquivados');
    if (!anosArquivados.length) {
        lista.innerHTML = '<p style="color:#64748b;">Nenhum ano letivo arquivado.</p>';
        return;
    }
    lista.innerHTML = anosArquivados.map(arq => {
        const snap = arq.casos;
        const total = snap.length;
        const encerrados = snap.filter(c => c.status === 'fechado' || c.status === 'arquivado').length;
        const pendentes = total - encerrados;
        const linhas = snap.map(c => {
            const qtdMsgs = c.total_mensagens ?? (c.mensagens || []).length;
            const badge = (c.status === 'fechado' || c.status === 'arquivado')
                ? `<span style="background:#dcfce7;color:#166534;border-radius:10px;padding:2px 8px;font-size:0.75rem;font-weight:600;">🔴 Encerrado</span>`
                : `<span style="background:#fef9c3;color:#92400e;border-radius:10px;padding:2px 8px;font-size:0.75rem;font-weight:600;">🟡 Em aberto</span>`;
            return `<tr>
                <td>${esc(c.aluno_nome || '—')}</td>
                <td>${esc(c.escola_origem || '—')}</td>
                <td>${esc(c.motivo || '—')}</td>
                <td>${badge}</td>
                <td style="text-align:center;">${qtdMsgs}</td>
                <td>${formatarDataBr(c.criado_em)}</td>
                <td>${formatarDataBr(c.fechado_em)}</td>
                <td style="text-align:center;"><button class="btn-secondary" style="font-size:0.75rem;padding:3px 9px;" onclick="verCasoArquivado(${arq.ano},${c.id})">🔍 Ver</button></td>
            </tr>`;
        }).join('') || '<tr><td colspan="8" style="color:#94a3b8; text-align:center;">Nenhum caso neste ano.</td></tr>';
        return `
        <details id="arq-ano-${arq.ano}" style="margin-bottom:12px;border:1px solid #e2e8f0;border-radius:10px;overflow:hidden;">
            <summary style="cursor:pointer;font-weight:600;padding:14px 18px;background:#f8fafc;display:flex;align-items:center;gap:10px;list-style:none;user-select:none;">
                <span style="flex:1;font-size:1rem;">📦 Ano Letivo ${arq.ano}</span>
                <span style="font-size:0.8rem;color:#64748b;font-weight:400;">Encerrado em ${formatarDataBr(arq.fechado_em)}${arq.fechado_por ? ` por ${esc(arq.fechado_por.split(' (')[0])}` : ''}</span>
                <span style="color:#94a3b8;font-size:0.85rem;flex-shrink:0;">▼</span>
            </summary>
            <div style="padding:18px;">
                <div style="display:flex;gap:14px;flex-wrap:wrap;margin-bottom:16px;">
                    <div style="background:#f1f5f9;border-radius:8px;padding:10px 20px;text-align:center;">
                        <div style="font-size:1.5rem;font-weight:700;">${total}</div>
                        <div style="font-size:0.75rem;color:#64748b;">Total de casos</div>
                    </div>
                    <div style="background:#dcfce7;border-radius:8px;padding:10px 20px;text-align:center;">
                        <div style="font-size:1.5rem;font-weight:700;color:#166534;">${encerrados}</div>
                        <div style="font-size:0.75rem;color:#166534;">Encerrados</div>
                    </div>
                    ${pendentes > 0 ? `<div style="background:#fef9c3;border-radius:8px;padding:10px 20px;text-align:center;">
                        <div style="font-size:1.5rem;font-weight:700;color:#92400e;">${pendentes}</div>
                        <div style="font-size:0.75rem;color:#92400e;">Pendentes arquivados</div>
                    </div>` : ''}
                </div>
                <div style="display:flex;gap:10px;margin-bottom:12px;align-items:center;">
                    <input type="text" placeholder="🔍 Filtrar por aluno ou motivo…" oninput="filtrarTabelaArquivada(this,'tabela-arq-${arq.ano}')" style="flex:1;max-width:360px;font-size:0.85rem;padding:7px 10px;">
                    <span style="font-size:0.8rem;color:#64748b;">🔒 Somente leitura</span>
                </div>
                <div style="overflow-x:auto;">
                    <table id="tabela-arq-${arq.ano}" style="font-size:0.85rem;">
                        <thead><tr>
                            <th>Aluno</th><th>Escola</th><th>Motivo</th><th>Status</th>
                            <th style="text-align:center;">Msgs</th><th>Abertura</th><th>Fechamento</th><th></th>
                        </tr></thead>
                        <tbody>${linhas}</tbody>
                    </table>
                </div>
            </div>
        </details>`;
    }).join('');
}

function verAnosArquivados(ano) {
    const el = document.getElementById(`arq-ano-${ano}`);
    if (!el) return;
    el.open = true;
    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function filtrarTabelaArquivada(input, tabelaId) {
    const termo = input.value.toLowerCase();
    document.querySelectorAll(`#${tabelaId} tbody tr`).forEach(tr => {
        tr.style.display = tr.innerText.toLowerCase().includes(termo) ? '' : 'none';
    });
}

async function verCasoArquivado(ano, casoId) {
    const arq = anosArquivados.find(a => a.ano === ano);
    let caso = arq ? arq.casos.find(c => c.id === casoId) : null;
    if (!caso || !Array.isArray(caso.mensagens)) {
        const detalhe = await carregarDetalheCaso(casoId);
        if (detalhe) caso = { ...(caso || {}), ...detalhe };
    }
    if (!caso) {
        alerta('alertaAnoLetivo', 'error', 'Não foi possível carregar este caso arquivado.');
        return;
    }
    const mensagens = caso.mensagens || [];
    const msgsHtml = mensagens.map(renderizarMensagemCompacta).join('') || '<p style="color:#94a3b8;">Nenhuma mensagem neste caso.</p>';
    document.getElementById('casoArquivadoConteudo').innerHTML = `
        <div style="background:#fef9c3;border-radius:8px;padding:10px 14px;margin-bottom:16px;font-size:0.85rem;">
            🔒 <strong>Ano Letivo ${ano} — Dados arquivados.</strong> Apenas consulta, sem edição.
        </div>
        <h3 style="margin:0 0 4px;">${esc(caso.aluno_nome || '')}</h3>
        <p style="color:#64748b;font-size:0.85rem;margin:0 0 12px;">${esc(caso.escola_origem || '')} | Motivo: ${esc(caso.motivo || '—')} | Status: ${esc(caso.status || '—')}</p>
        <p style="color:#64748b;font-size:0.82rem;margin:0 0 4px;">Aberto em: ${formatarDataBr(caso.criado_em, true)}${caso.criado_por ? ` por ${esc(caso.criado_por.split(' (')[0])}` : ''}</p>
        ${caso.fechado_em ? `<p style="color:#64748b;font-size:0.82rem;margin:0 0 14px;">Fechado em: ${formatarDataBr(caso.fechado_em, true)}${caso.fechado_por ? ` por ${esc(caso.fechado_por.split(' (')[0])}` : ''}</p>` : ''}
        <hr style="margin:14px 0;border:none;border-top:1px solid #e2e8f0;">
        <p style="font-weight:600;margin:0 0 6px;color:#475569;">💬 Mensagens (${mensagens.length})</p>
        ${msgsHtml}`;
    document.getElementById('modalCasoArquivado').style.display = 'flex';
    document.body.style.overflow = 'hidden';
}

function fecharCasoArquivado() {
    document.getElementById('modalCasoArquivado').style.display = 'none';
    document.body.style.overflow = '';
}

// Pré-visualização ao vivo da personalização do chat
['c_chat_bg_color', 'c_chat_bubble_sent', 'c_chat_bubble_received', 'c_chat_header_color', 'c_chat_bg_image_remover'].forEach(id => {
    const el = document.getElementById(id);
    if (el) { el.addEventListener('input', atualizarPreviewChatAoVivo); el.addEventListener('change', atualizarPreviewChatAoVivo); }
});

// ---------------- INICIALIZAÇÃO ----------------
carregarConfigVisual();
if (currentUser) {
    entrarNoSistema();
}
</script>
</body>
</html>
EOF_BUSCA_ATIVA

echo

# ---------------------------------------------------------
# 3. Construir e subir os containers
# ---------------------------------------------------------
if [ "${SKIP_DOCKER:-0}" = "1" ]; then
    echo "SKIP_DOCKER=1: arquivos gravados; containers NAO foram construidos (modo de teste)."
else
    echo "Construindo as imagens (isso pode levar alguns minutos na primeira vez)..."
    docker compose build

    echo "Subindo os containers..."
    docker compose up -d

    echo "Aguardando o sistema responder..."
    PRONTO=0
    for i in $(seq 1 40); do
        if curl -fsS -o /dev/null "http://127.0.0.1:8085/alunos/api/config" 2>/dev/null; then PRONTO=1; break; fi
        sleep 2
    done
    if [ "$PRONTO" != "1" ]; then
        echo "ATENCAO: o sistema ainda nao respondeu. Veja: docker logs api_busca_ativa --tail 30"
    fi

    # O sistema grava data/hora com o relogio do servidor: ele precisa estar sincronizado
    if command -v timedatectl >/dev/null 2>&1; then
        if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "no" ]; then
            echo
            echo "ATENCAO: o relogio do servidor NAO esta sincronizado. Sem isso, as datas e horas"
            echo "         gravadas pelo sistema podem sair erradas. Corrija com:"
            echo "           sudo timedatectl set-ntp true"
        fi
    fi
fi

IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$IP_LOCAL" ]; then IP_LOCAL="localhost"; fi

echo
echo "=========================================="
if [ "$ATUALIZACAO" = "1" ]; then
    echo " Atualizacao concluida!"
    echo "=========================================="
    echo "Seus dados, usuarios e senhas foram mantidos."
    echo "Acesse: http://$IP_LOCAL:8085/alunos/"
    echo "Pressione Ctrl+F5 no navegador para carregar a versao nova."
else
    ADMIN_SENHA="$(grep '^ADMIN_INITIAL_PASSWORD=' .env | cut -d= -f2-)"
    echo " Instalacao concluida!"
    echo "=========================================="
    echo "Acesse: http://$IP_LOCAL:8085/alunos/"
    echo "Login do administrador:  admin"
    echo "Senha inicial:           $ADMIN_SENHA"
    echo
    echo "ANOTE a senha acima agora e troque-a no primeiro acesso, pela aba"
    echo "Configuracoes e Usuarios. Ela tambem fica no arquivo $INSTALL_DIR/.env"
fi
echo "=========================================="
