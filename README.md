# Busca Ativa Escolar

Sistema self-hosted (100% local, sem dependência de nuvem) para cadastro de alunos e
**acompanhamento de casos de Busca Ativa Escolar**, com login por perfil, dashboard,
histórico de cada caso em formato de conversa, relatórios, gestão de usuários e de escolas,
auditoria e personalização visual (white-label).

Desenvolvido pela Coordenação de Tecnologia da Secretaria de Educação e Inovação Pedagógica
de Goiana - PE.

## Instalação (1 comando)

Em qualquer máquina Linux com acesso root (Ubuntu/Debian recomendado):

```bash
curl -fsSL https://raw.githubusercontent.com/coordenacaoti-byte/busca-ativa-escolar/main/install.sh | sudo bash
```

Se preferir ler o script antes de executar (recomendado), baixe e rode em dois passos:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/coordenacaoti-byte/busca-ativa-escolar/main/install.sh
sudo bash install.sh
```

Por padrão, instala em `/opt/sistemas-locais`. Para instalar em outro caminho:

```bash
sudo bash install.sh /caminho/personalizado
```

## O que o instalador faz

1. Instala o Docker e o Docker Compose, caso ainda não estejam presentes (script oficial `get.docker.com`).
2. Cria a estrutura de pastas e arquivos (backend FastAPI, front-end HTML/JS, configuração do Nginx e `docker-compose.yml`).
3. **Em instalação nova, gera senhas aleatórias** do banco de dados e do administrador e as grava em `.env`
   (somente o root lê). Nenhuma senha fica escrita neste repositório.
4. Constrói as imagens e sobe os containers (`nginx_gateway`, `api_busca_ativa`, `postgres_busca_ativa`).
5. Confere se o relógio do servidor está sincronizado e avisa se não estiver.

Ao final, o sistema fica em `http://<IP-DO-SERVIDOR>:8085/alunos/` e o instalador mostra a
**senha inicial do administrador** (usuário `admin`). Anote-a e troque no primeiro acesso, pela aba
Configurações & Usuários.

## Requisitos

- Linux com `systemd` (Ubuntu 20.04+, Debian 11+ ou equivalente) e acesso root (`sudo`)
- Porta `8085` livre
- Internet na primeira instalação (Docker e imagens base)
- **Relógio do servidor sincronizado** (`timedatectl` deve mostrar `System clock synchronized: yes`;
  se não, `sudo timedatectl set-ntp true`). O sistema grava data e hora com o relógio do servidor.

## Atualizando uma instalação existente

Rode o `install.sh` de novo no mesmo servidor. Se já houver uma instalação, ele **atualiza só o sistema**
(`main.py` e `index.html`), guarda uma cópia dos arquivos anteriores em `backups/sistema_AAAAMMDD_HHMMSS/`
e **preserva** `docker-compose.yml`, `nginx/nginx.conf`, `.env`, senhas e todos os dados.
Depois, pressione `Ctrl+F5` no navegador para carregar a versão nova.

## Arquitetura

```
Nginx (porta 8085) ──┬── /alunos/        → arquivos estáticos (front-end)
                      └── /alunos/api/    → proxy para o backend FastAPI
                                                   │
                                          PostgreSQL (dados persistentes, não exposto fora do Docker)
```

Todos os dados (alunos, casos, mensagens, anexos, usuários, logs, configurações) ficam no volume Docker
`pgdata_busca_ativa`, preservado entre atualizações e reinícios.

## Funcionalidades

- **Perfis:** Usuário Comum (só cadastro), Gestor / Visualizador, Coordenador de Acompanhamento e Administrador.
- **Alunos:** cadastro individual, importação e exportação em lote (Excel/CSV), foto do aluno.
- **Consulta e Acompanhamento:** um caso por aluno, com histórico em formato de conversa, anexos,
  urgência, prazo de retorno, atrasos, encaminhamento oficial (Conselho Tutelar, CRAS/CREAS, saúde, Ministério Público)
  e **sigilo automático** para casos de Saúde e Violência/Negligência (visíveis só ao Coordenador e ao Administrador).
- **Relatório do caso:** página imprimível (salvar como PDF), com textos institucionais editáveis.
- **Ano letivo:** encerramento arquiva os casos do ano em modo somente leitura, com consulta ao histórico.
- **Dashboard** com indicadores e gráficos; exportação de casos abertos.
- **Usuários e escolas:** criação, perfis, redefinição de senha pelo administrador, importação em lote, ordem das escolas.
- **Auditoria:** registro de logins (com a origem: IP, rede local ou acesso externo, aparelho e navegador),
  tentativas falhas, ações sobre casos e cadastros; exportação em PDF/CSV.
- **Personalização (white-label):** títulos, logotipo, cores do cabeçalho e do menu, imagem de fundo do login,
  cores e fundo do chat, cabeçalho e rodapé dos relatórios.
- **Relógio:** automático (horário de Recife, vindo do servidor) ou manual, definido pelo administrador
  (útil para registrar ocorrências antigas); um aviso aparece no cabeçalho enquanto estiver em modo manual.

## Segurança

- Login com token assinado (validade de 24 horas); a chave de assinatura é gerada na instalação e guardada no banco.
- Senhas guardadas com hash (PBKDF2); contas antigas em texto puro são convertidas no primeiro login.
- Permissões validadas **no servidor** por perfil (não dependem do que a tela mostra).
- Bloqueio por tentativas incorretas em três camadas (IP + usuário, IP e conta).
- Textos digitados são escapados na tela e nos relatórios; o CSV dos logs neutraliza fórmulas de planilha.
- Fotos e anexos só são entregues a usuários logados e respeitam o sigilo do caso.
- O banco de dados não é publicado fora da rede interna do Docker.

> O sistema funciona em HTTP simples, mas **recomenda-se colocá-lo atrás de um proxy HTTPS**: o Chrome bloqueia
> downloads (exportações em Excel/CSV/PDF) feitos a partir de endereços `http://`.

## Atrás de proxy ou túnel (IP real do cliente)

Se houver outro proxy na frente do Nginx do sistema (por exemplo, um proxy HTTPS em outro container),
o Nginx enxerga todos os acessos com o IP desse proxy. Para que o IP real chegue à auditoria e ao
bloqueio de tentativas, edite `nginx/nginx.conf`, descomente as 3 linhas `set_real_ip_from`,
`real_ip_header` e `real_ip_recursive` (trocando o IP pelo do proxy, que aparece em
`docker logs nginx_gateway --tail 3`) e recarregue:

```bash
docker exec nginx_gateway nginx -t && docker exec nginx_gateway nginx -s reload
```

## Horário

O sistema usa o fuso `America/Recife` e grava data e hora locais, independentemente do fuso do servidor.
Por isso o relógio do servidor precisa estar correto e sincronizado (veja "Requisitos").

## Manutenção manual

```bash
cd /opt/sistemas-locais

# Editar o backend
nano app_alunos/backend/main.py
docker compose build api_busca_ativa
docker compose up -d api_busca_ativa
docker logs api_busca_ativa --tail 50

# Editar o front-end (não precisa rebuild, é estático; depois Ctrl+F5 no navegador)
nano app_alunos/frontend/index.html

# Backup do banco de dados (guarde em local protegido: contém dados de crianças e adolescentes)
mkdir -p backups
docker exec postgres_busca_ativa pg_dump -U admin_local busca_ativa_db > backups/backup_$(date +%Y%m%d).sql
```

## Dados pessoais

O sistema trata dados de crianças e adolescentes. Este repositório **não contém dados reais**.
Em produção: restrinja o acesso físico e de rede ao servidor, guarde os backups em local protegido,
conceda cada perfil apenas a quem precisa e mantenha o registro de auditoria.

## Licença

Uso interno — Secretaria de Educação e Inovação Pedagógica de Goiana - PE.
