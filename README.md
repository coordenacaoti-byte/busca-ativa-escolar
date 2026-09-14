# Busca Ativa Escolar

Sistema self-hosted (100% local, sem dependência de nuvem) para cadastro e
acompanhamento de alunos em Busca Ativa Escolar, com login por perfil,
dashboard, gestão de usuários e de escolas, logs de auditoria e
personalização visual (white-label).

## Instalação (1 comando)

Em qualquer máquina Linux com acesso root (Ubuntu/Debian recomendado):

```bash
curl -fsSL https://raw.githubusercontent.com/coordenacaoti-byte/busca-ativa-escolar/main/install.sh | sudo bash
```

Ou, clonando o repositório primeiro:

```bash
git clone https://github.com/coordenacaoti-byte/busca-ativa-escolar.git
cd SEU-REPOSITORIO
sudo bash install.sh
```

Por padrão, instala em `/opt/sistemas-locais`. Para instalar em outro caminho:

```bash
sudo bash install.sh /caminho/personalizado
```

## O que o instalador faz

1. Instala o Docker e o Docker Compose, caso ainda não estejam presentes
   (usando o script oficial `get.docker.com`).
2. Cria toda a estrutura de pastas e arquivos (backend FastAPI, frontend
   HTML/JS, configuração do Nginx, `docker-compose.yml`).
3. Constrói as imagens e sobe os containers (`nginx_gateway`,
   `api_busca_ativa`, `postgres_busca_ativa`).

Ao final, o sistema fica disponível em:

```
http://<IP-DO-SERVIDOR>:8085/alunos/
```

**Login padrão:** `admin` / `admin123` — troque assim que possível, pela aba
Configurações & Usuários.

## Requisitos

- Linux com `systemd` (Ubuntu 20.04+, Debian 11+, ou equivalente)
- Acesso root (`sudo`)
- Porta `8085` livre no servidor
- Conexão com a internet (para baixar o Docker e as imagens base na primeira instalação)

## Arquitetura

```
Nginx (porta 8085) ──┬── /alunos/         → arquivos estáticos (frontend)
                      └── /alunos/api/     → proxy para o backend FastAPI
                                                     │
                                            PostgreSQL (dados persistentes)
```

Todos os dados (alunos, usuários, logs, configurações, escolas) ficam em um
volume Docker persistente (`pgdata_busca_ativa`), preservados entre
atualizações e reinícios dos containers.

## Funcionalidades

- Login com 3 perfis: Administrador, Gestor/Visualizador, Usuário Comum
- Cadastro individual de alunos + importação/exportação em lote (Excel/CSV)
- Dashboard com KPIs e gráficos
- Gestão de usuários (criar, editar perfil, remover, importar em lote)
- Gestão de escolas da rede (adicionar, remover, ordenar alfabeticamente ou manualmente por arrastar-e-soltar)
- Logs de auditoria com exportação em PDF/CSV
- Personalização completa (white-label): título, subtítulo, logotipo, cores do
  cabeçalho/menu/texto, imagem de fundo do login, texto do rodapé

## Atualizando uma instalação existente

Rodar o `install.sh` de novo **sobrescreve os arquivos de código** (`main.py`,
`index.html`, etc.) com a versão mais recente, mas **não apaga os dados** —
o volume do Postgres é preservado entre execuções.

## Manutenção manual

```bash
cd /opt/sistemas-locais

# Editar o backend
nano app_alunos/backend/main.py
docker compose build api_busca_ativa
docker compose up -d api_busca_ativa

# Editar o frontend (não precisa rebuild, é estático)
nano app_alunos/frontend/index.html

# Backup do banco de dados
docker exec postgres_busca_ativa pg_dump -U admin_local busca_ativa_db > backup_$(date +%Y%m%d).sql

# Ver logs do backend
docker logs api_busca_ativa --tail 50
```

## Licença

Uso interno — Secretaria de Educação e Inovação Pedagógica de Goiana - PE.
