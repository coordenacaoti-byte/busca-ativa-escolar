#!/bin/bash
#
# Instalador do Sistema de Busca Ativa Escolar
# Secretaria de Educacao e Inovacao Pedagogica de Goiana - PE
#
# Uso:
#   sudo bash install.sh                       # instala em /opt/sistemas-locais
#   sudo bash install.sh /outro/caminho         # instala em outro caminho
#
set -e

INSTALL_DIR="${1:-/opt/sistemas-locais}"

echo "=========================================="
echo " Instalador - Busca Ativa Escolar"
echo "=========================================="
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "Este script precisa rodar como root (use: sudo bash install.sh)"
    exit 1
fi

# ---------------------------------------------------------
# 1. Instalar o Docker, se ainda nao estiver instalado
# ---------------------------------------------------------
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
echo

# ---------------------------------------------------------
# 2. Criar a estrutura de pastas e arquivos
# ---------------------------------------------------------
echo "Instalando os arquivos em $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
mkdir -p app_alunos/backend app_alunos/frontend nginx

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
      POSTGRES_PASSWORD: SenhaSeguraLocal123
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
      - DB_PASSWORD=SenhaSeguraLocal123
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

echo "  - gravando app_alunos/backend/main.py"
cat > 'app_alunos/backend/main.py' << 'EOF_BUSCA_ATIVA'
from fastapi import FastAPI, HTTPException, UploadFile, File, Query
from fastapi.responses import StreamingResponse, Response
from pydantic import BaseModel
import psycopg2
from psycopg2.extras import RealDictCursor
import os
import io
import base64
import pandas as pd
from datetime import datetime, date
from zoneinfo import ZoneInfo

from reportlab.lib.pagesizes import letter, landscape
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

app = FastAPI()

DB_HOST = os.getenv("DB_HOST", "postgres_busca_ativa")
DB_NAME = os.getenv("DB_NAME", "busca_ativa_db")
DB_USER = os.getenv("DB_USER", "admin_local")
DB_PASS = os.getenv("DB_PASSWORD", "SenhaSeguraLocal123")

FUSO_RECIFE = ZoneInfo("America/Recife")

OPCOES_PERFIL = ["Usuário Comum", "Gestor / Visualizador", "Administrador"]


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASS,
        cursor_factory=RealDictCursor
    )


def init_db():
    conn = get_db_connection()
    cur = conn.cursor()

    # Tabela de alunos (já existente em produção - mantida sem alterações)
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

    # Tabela de configurações do sistema (título, logo)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS configuracoes_sistema (
            id INTEGER PRIMARY KEY DEFAULT 1,
            titulo_login VARCHAR(255),
            subtitulo_login VARCHAR(255),
            titulo_interno VARCHAR(255),
            logo_base64 TEXT
        );
    """)

    # Tabela de escolas da rede (editável pelo administrador)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS escolas (
            id SERIAL PRIMARY KEY,
            nome VARCHAR(255) UNIQUE NOT NULL
        );
    """)

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

    cur.execute("ALTER TABLE escolas ADD COLUMN IF NOT EXISTS ordem INTEGER;")
    cur.execute("""
        UPDATE escolas SET ordem = sub.rn
        FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY nome) AS rn FROM escolas) AS sub
        WHERE escolas.id = sub.id AND escolas.ordem IS NULL;
    """)

    cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS modo_ordenacao_escolas VARCHAR(20) DEFAULT 'alfabetica';")

    # Cria usuário admin padrão se ainda não houver nenhum usuário
    cur.execute("SELECT COUNT(*) as total FROM usuarios;")
    if cur.fetchone()["total"] == 0:
        cur.execute(
            "INSERT INTO usuarios (usuario, senha, nome, perfil) VALUES (%s, %s, %s, %s);",
            ("admin", "admin123", "Administrador", "Administrador")
        )

    # Adiciona colunas de cor (personalização visual) se ainda não existirem
    cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS cor_cabecalho VARCHAR(20) DEFAULT '#1e293b';")
    cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS cor_menu VARCHAR(20) DEFAULT '#0f172a';")
    cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS cor_texto_cabecalho VARCHAR(20) DEFAULT '#ffffff';")
    cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS imagem_fundo_login TEXT;")
    cur.execute("ALTER TABLE configuracoes_sistema ADD COLUMN IF NOT EXISTS rodape_texto TEXT;")

    # Cria configuração padrão se ainda não existir
    cur.execute("SELECT COUNT(*) as total FROM configuracoes_sistema;")
    if cur.fetchone()["total"] == 0:
        cur.execute("""
            INSERT INTO configuracoes_sistema (id, titulo_login, subtitulo_login, titulo_interno, logo_base64)
            VALUES (1, 'Sistema de Gestão Escolar', 'Acesse com suas credenciais para continuar', 'Busca Ativa Escolar & Gestão', NULL);
        """)

    # Garante um texto de rodapé padrão para quem ainda não tem um configurado
    rodape_padrao = (
        "© 2026 Secretaria de Educação e Inovação Pedagógica de Goiana - PE\n"
        "Desenvolvimento: Coordenação de Tecnologia\n"
        "Todos os direitos reservados."
    )
    cur.execute(
        "UPDATE configuracoes_sistema SET rodape_texto = %s WHERE id = 1 AND rodape_texto IS NULL;",
        (rodape_padrao,)
    )

    conn.commit()
    cur.close()
    conn.close()


@app.on_event("startup")
def startup_event():
    init_db()


def registrar_log(usuario: str, acao: str, detalhes: str = ""):
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO logs_auditoria (usuario, acao, detalhes) VALUES (%s, %s, %s);",
            (usuario, acao, detalhes)
        )
        conn.commit()
        cur.close()
        conn.close()
    except Exception:
        pass


# ---------------------------------------------------------
# SCHEMAS
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


class ConfigSchema(BaseModel):
    titulo_login: str
    subtitulo_login: str
    titulo_interno: str
    logo_base64: str | None = None
    cor_cabecalho: str = "#1e293b"
    cor_menu: str = "#0f172a"
    cor_texto_cabecalho: str = "#ffffff"
    imagem_fundo_login: str | None = None
    rodape_texto: str = ""
    modo_ordenacao_escolas: str = "alfabetica"


class ExcluirTodosSchema(BaseModel):
    confirmacao: str
    usuario_responsavel: str = "Desconhecido"


class EscolaSchema(BaseModel):
    nome: str


class OrdemEscolasSchema(BaseModel):
    ordem: list[int]


class ModoOrdenacaoSchema(BaseModel):
    modo: str


# ---------------------------------------------------------
# AUTENTICAÇÃO
# ---------------------------------------------------------
@app.post("/api/login")
def login(dados: LoginSchema):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        "SELECT usuario, nome, perfil FROM usuarios WHERE usuario = %s AND senha = %s;",
        (dados.usuario, dados.senha)
    )
    usuario = cur.fetchone()
    cur.close()
    conn.close()

    if not usuario:
        raise HTTPException(status_code=401, detail="Usuário ou senha incorretos.")

    registrar_log(dados.usuario, "Login Realizado", "Autenticação local")
    return usuario


# ---------------------------------------------------------
# ALUNOS
# ---------------------------------------------------------
@app.get("/api/alunos")
def listar_alunos():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT * FROM alunos ORDER BY id DESC;")
    alunos = cur.fetchall()
    cur.close()
    conn.close()
    return alunos


@app.post("/api/alunos")
def cadastrar_aluno(aluno: AlunoSchema, usuario_responsavel: str = "Desconhecido"):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO alunos (nome, cpf, data_nasc, tipo_busca, escola_origem, turma, endereco, observacoes)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING id;
    """, (aluno.nome, aluno.cpf, aluno.data_nasc, aluno.tipo_busca, aluno.escola_origem,
          aluno.turma, aluno.endereco, aluno.observacoes))
    novo_id = cur.fetchone()["id"]
    conn.commit()
    cur.close()
    conn.close()

    detalhes = f"Aluno: {aluno.nome} | CPF: {aluno.cpf} | Escola: {aluno.escola_origem}"
    registrar_log(usuario_responsavel, "Cadastro Individual", detalhes)
    return {"status": "sucesso", "id": novo_id}


@app.get("/api/alunos/modelo")
def baixar_modelo_alunos():
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


@app.post("/api/alunos/lote")
async def importar_alunos_lote(arquivo: UploadFile = File(...), usuario_responsavel: str = "Desconhecido"):
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

    conn = get_db_connection()
    cur = conn.cursor()
    total = 0
    for _, row in df.iterrows():
        cur.execute("""
            INSERT INTO alunos (nome, cpf, data_nasc, tipo_busca, escola_origem, turma, endereco, observacoes)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
        """, (row["nome"], row["cpf"], row["data_nasc"], row["tipo_busca"],
              row["escola_origem"], row["turma"], row["endereco"], row.get("observacoes", "")))
        total += 1
    conn.commit()
    cur.close()
    conn.close()

    registrar_log(usuario_responsavel, "Importação em Lote", f"Importados {total} alunos via planilha.")
    return {"status": "sucesso", "total_importado": total}


@app.get("/api/alunos/export")
def exportar_alunos():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT * FROM alunos ORDER BY id DESC;")
    dados = cur.fetchall()
    cur.close()
    conn.close()

    df = pd.DataFrame(dados)
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


@app.post("/api/alunos/excluir-tudo")
def excluir_todos_alunos(dados: ExcluirTodosSchema):
    if dados.confirmacao.strip() != "DELETAR":
        raise HTTPException(status_code=400, detail="Texto de confirmação incorreto. Digite exatamente 'DELETAR'.")

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) as total FROM alunos;")
    qtd = cur.fetchone()["total"]
    cur.execute("DELETE FROM alunos;")
    conn.commit()
    cur.close()
    conn.close()

    registrar_log(dados.usuario_responsavel, "Exclusão da Base de Alunos", f"A base contendo {qtd} aluno(s) foi zerada.")
    return {"status": "sucesso", "excluidos": qtd}


# ---------------------------------------------------------
# DASHBOARD
# ---------------------------------------------------------
@app.get("/api/dashboard")
def dashboard_stats():
    conn = get_db_connection()
    cur = conn.cursor()

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

    cur.close()
    conn.close()

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
@app.get("/api/usuarios")
def listar_usuarios():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT usuario, nome, perfil FROM usuarios ORDER BY id;")
    usuarios = cur.fetchall()
    cur.close()
    conn.close()
    return usuarios


@app.post("/api/usuarios")
def criar_usuario(dados: UsuarioSchema, usuario_responsavel: str = "Desconhecido"):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "INSERT INTO usuarios (usuario, senha, nome, perfil) VALUES (%s, %s, %s, %s);",
            (dados.usuario, dados.senha, dados.nome, dados.perfil)
        )
        conn.commit()
    except psycopg2.errors.UniqueViolation:
        conn.rollback()
        cur.close()
        conn.close()
        raise HTTPException(status_code=400, detail="Já existe um usuário com esse login.")
    cur.close()
    conn.close()

    registrar_log(usuario_responsavel, "Cadastro de Usuário", f"Criou o usuário {dados.usuario} ({dados.perfil})")
    return {"status": "sucesso"}


@app.put("/api/usuarios/{usuario_login}")
def atualizar_perfil(usuario_login: str, dados: PerfilUpdateSchema, usuario_responsavel: str = "Desconhecido"):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("UPDATE usuarios SET perfil = %s WHERE usuario = %s;", (dados.perfil, usuario_login))
    conn.commit()
    cur.close()
    conn.close()

    registrar_log(usuario_responsavel, "Alteração de Perfil", f"Alterou perfil de {usuario_login} para {dados.perfil}")
    return {"status": "sucesso"}


@app.delete("/api/usuarios/{usuario_login}")
def remover_usuario(usuario_login: str, usuario_responsavel: str = "Desconhecido"):
    if usuario_login == "admin":
        raise HTTPException(status_code=400, detail="Não é permitido remover o usuário admin.")

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("DELETE FROM usuarios WHERE usuario = %s;", (usuario_login,))
    conn.commit()
    cur.close()
    conn.close()

    registrar_log(usuario_responsavel, "Exclusão de Usuário", f"Removeu o usuário {usuario_login}")
    return {"status": "sucesso"}


@app.get("/api/usuarios/modelo")
def baixar_modelo_usuarios():
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


@app.post("/api/usuarios/lote")
async def importar_usuarios_lote(arquivo: UploadFile = File(...), usuario_responsavel: str = "Desconhecido"):
    conteudo = await arquivo.read()
    buffer = io.BytesIO(conteudo)

    if arquivo.filename.endswith(".csv"):
        df = pd.read_csv(buffer)
    else:
        df = pd.read_excel(buffer)

    df.columns = [c.strip().lower() for c in df.columns]
    df["perfil"] = df["perfil"].apply(lambda p: p if p in OPCOES_PERFIL else "Usuário Comum")

    conn = get_db_connection()
    cur = conn.cursor()
    total = 0
    for _, row in df.iterrows():
        try:
            cur.execute(
                "INSERT INTO usuarios (usuario, senha, nome, perfil) VALUES (%s, %s, %s, %s);",
                (row["usuario"], row["senha"], row["nome"], row["perfil"])
            )
            total += 1
        except psycopg2.errors.UniqueViolation:
            conn.rollback()
            continue
    conn.commit()
    cur.close()
    conn.close()

    registrar_log(usuario_responsavel, "Importação de Usuários em Lote", f"Importados {total} usuários via planilha.")
    return {"status": "sucesso", "total_importado": total}


# ---------------------------------------------------------
# ESCOLAS
# ---------------------------------------------------------
@app.get("/api/escolas")
def listar_escolas():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT modo_ordenacao_escolas FROM configuracoes_sistema WHERE id = 1;")
    row = cur.fetchone()
    modo = row["modo_ordenacao_escolas"] if row and row["modo_ordenacao_escolas"] else "alfabetica"

    if modo == "manual":
        cur.execute("SELECT id, nome, ordem FROM escolas ORDER BY ordem NULLS LAST, nome;")
    else:
        cur.execute("SELECT id, nome, ordem FROM escolas ORDER BY nome;")

    escolas = cur.fetchall()
    cur.close()
    conn.close()
    return {"modo": modo, "escolas": escolas}


@app.put("/api/escolas/ordem")
def reordenar_escolas(dados: OrdemEscolasSchema, usuario_responsavel: str = "Desconhecido"):
    conn = get_db_connection()
    cur = conn.cursor()
    for posicao, escola_id in enumerate(dados.ordem):
        cur.execute("UPDATE escolas SET ordem = %s WHERE id = %s;", (posicao, escola_id))
    conn.commit()
    cur.close()
    conn.close()

    registrar_log(usuario_responsavel, "Reordenação de Escolas", "Atualizou a ordem manual das escolas")
    return {"status": "sucesso"}


@app.post("/api/escolas/modo")
def definir_modo_ordenacao(dados: ModoOrdenacaoSchema, usuario_responsavel: str = "Desconhecido"):
    if dados.modo not in ("alfabetica", "manual"):
        raise HTTPException(status_code=400, detail="Modo inválido. Use 'alfabetica' ou 'manual'.")

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("UPDATE configuracoes_sistema SET modo_ordenacao_escolas = %s WHERE id = 1;", (dados.modo,))
    conn.commit()
    cur.close()
    conn.close()

    registrar_log(usuario_responsavel, "Alteração do Modo de Ordenação", f"Escolas passaram a ser ordenadas por: {dados.modo}")
    return {"status": "sucesso"}


@app.post("/api/escolas")
def criar_escola(dados: EscolaSchema, usuario_responsavel: str = "Desconhecido"):
    nome = dados.nome.strip()
    if not nome:
        raise HTTPException(status_code=400, detail="O nome da escola não pode ficar em branco.")

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("INSERT INTO escolas (nome) VALUES (%s) RETURNING id;", (nome,))
        novo_id = cur.fetchone()["id"]
        conn.commit()
    except psycopg2.errors.UniqueViolation:
        conn.rollback()
        cur.close()
        conn.close()
        raise HTTPException(status_code=400, detail="Essa escola já está cadastrada.")
    cur.close()
    conn.close()

    registrar_log(usuario_responsavel, "Cadastro de Escola", f"Adicionou a escola {nome}")
    return {"status": "sucesso", "id": novo_id}


@app.delete("/api/escolas/{escola_id}")
def remover_escola(escola_id: int, usuario_responsavel: str = "Desconhecido"):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT nome FROM escolas WHERE id = %s;", (escola_id,))
    row = cur.fetchone()
    cur.execute("DELETE FROM escolas WHERE id = %s;", (escola_id,))
    conn.commit()
    cur.close()
    conn.close()

    if row:
        registrar_log(usuario_responsavel, "Exclusão de Escola", f"Removeu a escola {row['nome']}")
    return {"status": "sucesso"}


# ---------------------------------------------------------
# LOGS DE AUDITORIA
# ---------------------------------------------------------
@app.get("/api/logs")
def listar_logs(data_inicio: str | None = Query(None), data_fim: str | None = Query(None)):
    conn = get_db_connection()
    cur = conn.cursor()

    condicoes = []
    parametros = []
    if data_inicio:
        condicoes.append("data_hora >= %s")
        parametros.append(f"{data_inicio} 00:00:00")
    if data_fim:
        condicoes.append("data_hora <= %s")
        parametros.append(f"{data_fim} 23:59:59")

    where_clause = f"WHERE {' AND '.join(condicoes)}" if condicoes else ""
    cur.execute(f"SELECT * FROM logs_auditoria {where_clause} ORDER BY id DESC;", parametros)
    logs = cur.fetchall()
    cur.close()
    conn.close()
    return logs


def _buscar_logs_periodo(data_inicio, data_fim):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("""
        SELECT * FROM logs_auditoria
        WHERE data_hora >= %s AND data_hora <= %s
        ORDER BY id DESC;
    """, (f"{data_inicio} 00:00:00", f"{data_fim} 23:59:59"))
    logs = cur.fetchall()
    cur.close()
    conn.close()
    return logs


@app.get("/api/logs/csv")
def exportar_logs_csv(data_inicio: str, data_fim: str):
    logs = _buscar_logs_periodo(data_inicio, data_fim)
    df = pd.DataFrame(logs)
    buffer = io.StringIO()
    df.to_csv(buffer, index=False)
    buffer.seek(0)
    return StreamingResponse(
        iter([buffer.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename=logs_auditoria_{data_inicio}_{data_fim}.csv"}
    )


@app.get("/api/logs/pdf")
def exportar_logs_pdf(data_inicio: str, data_fim: str, usuario_solicitante: str = "Desconhecido"):
    logs = _buscar_logs_periodo(data_inicio, data_fim)

    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer, pagesize=landscape(letter),
        rightMargin=30, leftMargin=30, topMargin=30, bottomMargin=30
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
    periodo_str = f"<b>Período:</b> {data_inicio} até {data_fim}"
    emissao_str = f"<b>Emissão:</b> {datetime.now(FUSO_RECIFE).strftime('%d/%m/%Y %H:%M:%S')} por {usuario_solicitante}"
    elements.append(Paragraph(f"{periodo_str} | {emissao_str}", subtitle_style))

    data = [["Data/Hora", "Usuário Responsável", "Ação / Evento", "Detalhes do Registro"]]
    data[0] = [Paragraph(col, style_header) for col in data[0]]

    for row in logs:
        data_hora_fmt = row["data_hora"].strftime("%d/%m/%Y %H:%M:%S") if row.get("data_hora") else ""
        data.append([
            Paragraph(data_hora_fmt, style_cell),
            Paragraph(str(row.get("usuario", "")), style_cell),
            Paragraph(str(row.get("acao", "")), style_cell),
            Paragraph(str(row.get("detalhes", "")), style_cell),
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
    doc.build(elements)
    buffer.seek(0)

    return StreamingResponse(
        buffer, media_type="application/pdf",
        headers={"Content-Disposition": f"attachment; filename=relatorio_auditoria_{data_inicio}_{data_fim}.pdf"}
    )


@app.delete("/api/logs")
def limpar_logs():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("DELETE FROM logs_auditoria;")
    conn.commit()
    cur.close()
    conn.close()
    return {"status": "sucesso"}


# ---------------------------------------------------------
# CONFIGURAÇÕES DO SISTEMA
# ---------------------------------------------------------
def _decodificar_data_uri(data_uri):
    """Separa uma data URI (data:image/png;base64,....) em (mime, bytes)."""
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


@app.get("/api/config")
def obter_config():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("""
        SELECT id, titulo_login, subtitulo_login, titulo_interno,
               cor_cabecalho, cor_menu, cor_texto_cabecalho, rodape_texto, modo_ordenacao_escolas,
               (logo_base64 IS NOT NULL) AS tem_logo,
               (imagem_fundo_login IS NOT NULL) AS tem_fundo_login
        FROM configuracoes_sistema WHERE id = 1;
    """)
    config = cur.fetchone()
    cur.close()
    conn.close()
    return config


@app.get("/api/config/logo")
def obter_logo():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT logo_base64 FROM configuracoes_sistema WHERE id = 1;")
    row = cur.fetchone()
    cur.close()
    conn.close()
    mime, raw = _decodificar_data_uri(row["logo_base64"] if row else None)
    if not raw:
        raise HTTPException(status_code=404, detail="Logo não configurado.")
    return Response(content=raw, media_type=mime, headers={"Cache-Control": "public, max-age=3600"})


@app.get("/api/config/fundo-login")
def obter_fundo_login():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT imagem_fundo_login FROM configuracoes_sistema WHERE id = 1;")
    row = cur.fetchone()
    cur.close()
    conn.close()
    mime, raw = _decodificar_data_uri(row["imagem_fundo_login"] if row else None)
    if not raw:
        raise HTTPException(status_code=404, detail="Imagem de fundo não configurada.")
    return Response(content=raw, media_type=mime, headers={"Cache-Control": "public, max-age=3600"})


@app.post("/api/config")
def salvar_config(dados: ConfigSchema):
    conn = get_db_connection()
    cur = conn.cursor()
    if dados.logo_base64:
        cur.execute("""
            UPDATE configuracoes_sistema
            SET titulo_login = %s, subtitulo_login = %s, titulo_interno = %s, logo_base64 = %s,
                cor_cabecalho = %s, cor_menu = %s, cor_texto_cabecalho = %s, rodape_texto = %s
            WHERE id = 1;
        """, (dados.titulo_login, dados.subtitulo_login, dados.titulo_interno, dados.logo_base64,
              dados.cor_cabecalho, dados.cor_menu, dados.cor_texto_cabecalho, dados.rodape_texto))
    else:
        cur.execute("""
            UPDATE configuracoes_sistema
            SET titulo_login = %s, subtitulo_login = %s, titulo_interno = %s,
                cor_cabecalho = %s, cor_menu = %s, cor_texto_cabecalho = %s, rodape_texto = %s
            WHERE id = 1;
        """, (dados.titulo_login, dados.subtitulo_login, dados.titulo_interno,
              dados.cor_cabecalho, dados.cor_menu, dados.cor_texto_cabecalho, dados.rodape_texto))

    if dados.imagem_fundo_login:
        cur.execute(
            "UPDATE configuracoes_sistema SET imagem_fundo_login = %s WHERE id = 1;",
            (dados.imagem_fundo_login,)
        )

    conn.commit()
    cur.close()
    conn.close()
    return {"status": "sucesso"}
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
<style>
    * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
    body { background: #f1f5f9; margin: 0; color: #1e293b; }

    /* LOGIN */
    #loginScreen { display: flex; justify-content: center; align-items: center; height: 100vh; background: #0f172a; }
    .login-card { background: white; padding: 40px; border-radius: 12px; width: 360px; box-shadow: 0 10px 25px rgba(0,0,0,0.3); }
    .login-card h2 { text-align: center; margin-top: 0; }
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
    .nav-tabs button { background: transparent; border: none; color: #cbd5e1; padding: 14px 20px; cursor: pointer; font-size: 0.95rem; font-weight: 600; border-bottom: 3px solid transparent; }
    .nav-tabs button.active { color: white; border-bottom-color: #2563eb; }

    .tab-content { display: none; padding: 30px; max-width: 1100px; margin: 0 auto; }
    .tab-content.active { display: block; }

    .container { background: white; border-radius: 12px; padding: 32px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); margin-bottom: 24px; }
    h2 { margin-top: 0; color: #0f172a; }

    .form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px 20px; }
    .full-width { grid-column: span 2; }
    .form-group { display: flex; flex-direction: column; gap: 6px; }
    label { font-size: 0.9rem; font-weight: 600; color: #334155; }
    input, select, textarea { width: 100%; padding: 10px 12px; border: 1px solid #cbd5e1; border-radius: 6px; font-size: 0.95rem; }
    textarea { resize: vertical; min-height: 70px; }

    button.btn-primary { background: #2563eb; color: white; border: none; padding: 12px 20px; border-radius: 6px; font-weight: 600; cursor: pointer; }
    button.btn-primary:hover { background: #1d4ed8; }
    button.btn-danger { background: #dc2626; color: white; border: none; padding: 10px 16px; border-radius: 6px; font-weight: 600; cursor: pointer; }
    button.btn-secondary { background: #f1f5f9; color: #1e293b; border: 1px solid #cbd5e1; padding: 10px 16px; border-radius: 6px; cursor: pointer; }

    table { width: 100%; border-collapse: collapse; margin-top: 16px; font-size: 0.9rem; }
    th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid #e2e8f0; }
    th { background: #f8fafc; color: #475569; }
    tr:nth-child(even) { background: #f8fafc; }

    .kpi-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin-bottom: 24px; }
    .kpi-card { background: white; border-radius: 12px; padding: 20px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); display: flex; justify-content: space-between; align-items: center; }
    .kpi-title { font-size: 0.75rem; font-weight: 700; color: #64748b; text-transform: uppercase; }
    .kpi-value { font-size: 1.7rem; font-weight: 800; margin: 4px 0; }
    .kpi-icon { width: 42px; height: 42px; border-radius: 12px; display: flex; align-items: center; justify-content: center; font-size: 20px; background: #e0e7ff; }

    .charts-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 24px; }

    .import-card { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 12px; padding: 20px; }
    .step-badge { display: inline-block; background: #e0e7ff; color: #4f46e5; font-size: 0.75rem; font-weight: 700; padding: 4px 10px; border-radius: 20px; margin-bottom: 10px; }

    .subtabs { display: flex; gap: 10px; margin-bottom: 20px; border-bottom: 1px solid #e2e8f0; }
    .subtabs button { background: none; border: none; padding: 10px 4px; margin-right: 20px; cursor: pointer; font-weight: 600; color: #64748b; border-bottom: 3px solid transparent; }
    .subtabs button.active { color: #2563eb; border-bottom-color: #2563eb; }
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
        <div class="user-info">
            <b id="userNome"></b>
            <span id="userPerfil"></span>
            &nbsp;·&nbsp;<a href="#" onclick="logout()" style="color:#93c5fd;">Sair</a>
        </div>
    </header>

    <div class="nav-tabs" id="navTabs">
        <button data-tab="cadastro" class="active" onclick="mudarTab('cadastro')">📝 Cadastro de Alunos</button>
        <button data-tab="dashboard" id="btnTabDashboard" onclick="mudarTab('dashboard')">📊 Dashboard Geral</button>
        <button data-tab="config" id="btnTabConfig" onclick="mudarTab('config')" style="display:none;">⚙️ Configurações & Usuários</button>
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
                    <a href="/alunos/api/alunos/modelo"><button class="btn-secondary" style="width:100%;">Baixar Modelo (.xlsx)</button></a>
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
            <h2>📊 Tabela Completa de Alunos</h2>
            <div style="display:flex; gap:10px; margin-bottom:16px;">
                <a href="/alunos/api/alunos/export"><button class="btn-secondary">📥 Baixar Base Completa (.xlsx)</button></a>
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
                    <thead><tr><th>Nome</th><th>CPF</th><th>Nascimento</th><th>Escola</th><th>Turma</th><th>Tipo</th><th>Endereço</th><th>Observações</th></tr></thead>
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

    <!-- ===== TAB CONFIG & USUÁRIOS ===== -->
    <div class="tab-content" id="tab-config">
        <div class="subtabs">
            <button class="active" data-sub="usuarios" onclick="mudarSubtab('usuarios')">👥 Usuários</button>
            <button data-sub="visual" onclick="mudarSubtab('visual')">🎨 Personalização</button>
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
                <a href="/alunos/api/usuarios/modelo"><button class="btn-secondary">Baixar Modelo (.xlsx)</button></a>
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
                    <div class="form-group full-width"><label>Imagem de Fundo da Tela de Login</label><input type="file" id="c_fundo_login" accept="image/*"></div>
                    <div class="form-group full-width"><label>Texto do Rodapé (uma linha por parágrafo)</label><textarea id="c_rodape_texto" rows="3"></textarea></div>
                </div>
                <button class="btn-primary" style="margin-top:16px;" onclick="salvarConfig()">💾 Salvar Personalização</button>
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
    </div>

    <div class="footer" id="footerTexto" style="margin-top:30px; padding:20px; text-align:center; font-size:0.85rem; color:#64748b; line-height:1.5; border-top:1px solid #e2e8f0;">
        © 2026 Secretaria de Educação e Inovação Pedagógica de Goiana - PE<br>
        Desenvolvimento: Coordenação de Tecnologia<br>
        Todos os direitos reservados.
    </div>
</div>

<script>
const API = '/alunos/api';
let currentUser = JSON.parse(sessionStorage.getItem('usuario_logado') || 'null');

let escolasCache = [];
let escolaArrastadaId = null;

async function carregarEscolas() {
    const res = await fetch(`${API}/escolas`);
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
    await fetch(`${API}/escolas/modo?usuario_responsavel=${usuarioResp}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ modo })
    });
    carregarEscolas();
}

function preencherSelectEscolas() {
    const sel = document.getElementById('f_escola_origem');
    sel.innerHTML = '<option value="">Selecione a Escola</option>' +
        escolasCache.map(e => `<option value="${e.nome}">${e.nome}</option>`).join('');
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
            <span>${manual ? '⠿ ' : ''}${e.nome}</span>
            <button class="btn-danger" style="padding:4px 10px; font-size:0.8rem;" onclick="removerEscola(${e.id}, '${e.nome.replace(/'/g, "\\'")}')">Remover</button>
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
    await fetch(`${API}/escolas/ordem?usuario_responsavel=${usuarioResp}`, {
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
    const res = await fetch(`${API}/escolas?usuario_responsavel=${usuarioResp}`, {
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
    await fetch(`${API}/escolas/${id}?usuario_responsavel=${usuarioResp}`, { method: 'DELETE' });
    carregarEscolas();
}

function toggleSenhaLogin() {
    const campo = document.getElementById('loginSenha');
    campo.type = campo.type === 'password' ? 'text' : 'password';
}

function alerta(containerId, tipo, mensagem) {
    document.getElementById(containerId).innerHTML = `<div class="alert alert-${tipo}">${mensagem}</div>`;
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
                    .map(linha => linha.trim())
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
            window._configAtual = cfg;
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
        if (!res.ok) {
            document.getElementById('loginErro').innerText = '⚠️ Usuário ou senha incorretos.';
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
    currentUser = null;
    document.getElementById('appScreen').style.display = 'none';
    document.getElementById('loginScreen').style.display = 'flex';
}

function entrarNoSistema() {
    document.getElementById('loginScreen').style.display = 'none';
    document.getElementById('appScreen').style.display = 'block';
    document.getElementById('userNome').innerText = currentUser.nome;
    document.getElementById('userPerfil').innerText = currentUser.perfil;

    document.getElementById('btnTabConfig').style.display = currentUser.perfil === 'Administrador' ? 'inline-block' : 'none';
    document.getElementById('btnTabDashboard').style.display = currentUser.perfil === 'Usuário Comum' ? 'none' : 'inline-block';
    document.getElementById('btnLimparLogs').style.display = currentUser.perfil === 'Administrador' ? 'inline-block' : 'none';
    document.getElementById('btnAbrirExclusao').style.display = currentUser.perfil === 'Administrador' ? 'inline-block' : 'none';
    document.getElementById('cardLogsAuditoria').style.display = currentUser.perfil === 'Usuário Comum' ? 'none' : 'block';

    if (currentUser.perfil === 'Usuário Comum') {
        mudarTab('cadastro');
    }

    carregarEscolas();
    carregarAlunosDashboard();
    carregarDashboardStats();
    const hoje = new Date().toISOString().slice(0, 10);
    const inicioMes = hoje.slice(0, 8) + '01';
    document.getElementById('logDataInicio').value = inicioMes;
    document.getElementById('logDataFim').value = hoje;
    carregarLogs();
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
    const res = await fetch(`${API}/alunos?usuario_responsavel=${usuarioResp}`, {
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
    const res = await fetch(`${API}/alunos/lote?usuario_responsavel=${usuarioResp}`, { method: 'POST', body: formData });
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

async function carregarDashboardStats() {
    const res = await fetch(`${API}/dashboard`);
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

async function carregarAlunosDashboard() {
    const res = await fetch(`${API}/alunos`);
    const alunos = await res.json();
    const tbody = document.getElementById('tabelaAlunosDashboard');
    tbody.innerHTML = alunos.map(a => `
        <tr>
            <td>${a.nome}</td><td>${a.cpf}</td>
            <td>${a.data_nasc ? new Date(a.data_nasc).toLocaleDateString('pt-BR') : ''}</td>
            <td>${a.escola_origem}</td><td>${a.turma}</td><td>${a.tipo_busca}</td>
            <td>${a.endereco || ''}</td><td>${a.observacoes || ''}</td>
        </tr>`).join('');
}

function toggleExclusao() {
    const p = document.getElementById('painelExclusao');
    p.style.display = p.style.display === 'none' ? 'block' : 'none';
}

async function excluirTodosAlunos() {
    const confirmacao = document.getElementById('txtDeletar').value;
    const usuarioResp = `${currentUser.nome} (${currentUser.usuario})`;
    const res = await fetch(`${API}/alunos/excluir-tudo`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ confirmacao, usuario_responsavel: usuarioResp })
    });
    if (res.ok) {
        alerta('dashboardAlerta', 'success', '✅ Base de alunos excluída com sucesso!');
        document.getElementById('painelExclusao').style.display = 'none';
        carregarAlunosDashboard();
        carregarDashboardStats();
    } else {
        const err = await res.json();
        alerta('dashboardAlerta', 'error', `❌ ${err.detail || 'Erro ao excluir.'}`);
    }
}

// ---------------- LOGS ----------------
async function carregarLogs() {
    const ini = document.getElementById('logDataInicio').value;
    const fim = document.getElementById('logDataFim').value;
    const res = await fetch(`${API}/logs?data_inicio=${ini}&data_fim=${fim}`);
    const logs = await res.json();
    document.getElementById('tabelaLogs').innerHTML = logs.map(l => `
        <tr>
            <td>${l.data_hora ? new Date(l.data_hora).toLocaleString('pt-BR') : ''}</td>
            <td>${l.usuario || ''}</td><td>${l.acao || ''}</td><td>${l.detalhes || ''}</td>
        </tr>`).join('');
}

function exportarLogsPdf() {
    const ini = document.getElementById('logDataInicio').value;
    const fim = document.getElementById('logDataFim').value;
    const usr = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    window.open(`${API}/logs/pdf?data_inicio=${ini}&data_fim=${fim}&usuario_solicitante=${usr}`, '_blank');
}

function exportarLogsCsv() {
    const ini = document.getElementById('logDataInicio').value;
    const fim = document.getElementById('logDataFim').value;
    window.open(`${API}/logs/csv?data_inicio=${ini}&data_fim=${fim}`, '_blank');
}

async function limparLogs() {
    if (!confirm('Tem certeza que deseja apagar todos os logs?')) return;
    await fetch(`${API}/logs`, { method: 'DELETE' });
    carregarLogs();
}

// ---------------- USUÁRIOS ----------------
async function carregarUsuarios() {
    const res = await fetch(`${API}/usuarios`);
    const usuarios = await res.json();
    document.getElementById('tabelaUsuarios').innerHTML = usuarios.map(u => `
        <tr>
            <td>${u.usuario}</td><td>${u.nome}</td>
            <td>
                <select onchange="atualizarPerfilUsuario('${u.usuario}', this.value)">
                    <option ${u.perfil === 'Usuário Comum' ? 'selected' : ''}>Usuário Comum</option>
                    <option ${u.perfil === 'Gestor / Visualizador' ? 'selected' : ''}>Gestor / Visualizador</option>
                    <option ${u.perfil === 'Administrador' ? 'selected' : ''}>Administrador</option>
                </select>
            </td>
            <td>${u.usuario === 'admin' ? '' : `<button class="btn-danger" onclick="removerUsuario('${u.usuario}')">Remover</button>`}</td>
        </tr>`).join('');
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
    const res = await fetch(`${API}/usuarios?usuario_responsavel=${usuarioResp}`, {
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
    await fetch(`${API}/usuarios/${usuario}?usuario_responsavel=${usuarioResp}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ perfil: novoPerfil })
    });
}

async function removerUsuario(usuario) {
    if (!confirm(`Remover o usuário ${usuario}?`)) return;
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    await fetch(`${API}/usuarios/${usuario}?usuario_responsavel=${usuarioResp}`, { method: 'DELETE' });
    carregarUsuarios();
}

async function importarLoteUsuarios() {
    const arquivo = document.getElementById('arquivoLoteUsuarios').files[0];
    if (!arquivo) { alerta('importAlertaUsuarios', 'warning', 'Selecione um arquivo primeiro.'); return; }
    const formData = new FormData();
    formData.append('arquivo', arquivo);
    const usuarioResp = encodeURIComponent(`${currentUser.nome} (${currentUser.usuario})`);
    const res = await fetch(`${API}/usuarios/lote?usuario_responsavel=${usuarioResp}`, { method: 'POST', body: formData });
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
    document.getElementById('c_rodape_texto').value = cfg.rodape_texto || '';
    window._configAtual = cfg;
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

    const dados = {
        titulo_login: document.getElementById('c_titulo_login').value,
        subtitulo_login: document.getElementById('c_subtitulo_login').value,
        titulo_interno: document.getElementById('c_titulo_interno').value,
        logo_base64: logoBase64,
        cor_cabecalho: document.getElementById('c_cor_cabecalho').value,
        cor_menu: document.getElementById('c_cor_menu').value,
        cor_texto_cabecalho: document.getElementById('c_cor_texto_cabecalho').value,
        imagem_fundo_login: fundoLoginBase64,
        rodape_texto: document.getElementById('c_rodape_texto').value
    };
    const res = await fetch(`${API}/config`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(dados)
    });
    if (res.ok) {
        alerta('configAlerta', 'success', 'Configurações atualizadas!');
        carregarConfigVisual(true);
    } else {
        alerta('configAlerta', 'error', 'Erro ao salvar configurações.');
    }
}

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
echo "Construindo as imagens (isso pode levar alguns minutos na primeira vez)..."
docker compose build

echo "Subindo os containers..."
docker compose up -d

echo "Aguardando o backend inicializar..."
sleep 5

IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$IP_LOCAL" ]; then IP_LOCAL="localhost"; fi

echo "=========================================="
echo " Instalacao concluida!"
echo "=========================================="
echo "Acesse: http://$IP_LOCAL:8085/alunos/"
echo "Login padrao:  admin"
echo "Senha padrao:  admin123"
echo
echo "IMPORTANTE: troque a senha padrao assim que possivel,"
echo "pela aba Configuracoes e Usuarios dentro do sistema."
echo "=========================================="
