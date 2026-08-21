#!/usr/bin/env bash
#
# Deploy do Willians numa VPS que JÁ TEM outros sistemas rodando.
#
# Premissas do desenho, todas por causa disso:
#
#   - a stack sobe com nome de projeto próprio (willians-prod) e volumes
#     próprios, então não encosta em containers ou dados de mais ninguém;
#   - publica UMA porta, e só em 127.0.0.1. Quem fala com a internet é o nginx
#     do host;
#   - a porta é verificada antes de usar; se estiver ocupada, o script para;
#   - nenhum arquivo de nginx é sobrescrito sem cópia de segurança;
#   - o sistema antigo é PARADO, nunca apagado — o rollback é um comando.
#
# Uso:
#
#   ./deploy/deploy.sh inspecionar          o que existe hoje (não muda nada)
#   ./deploy/deploy.sh preparar             cria .env.production e gera segredos
#   ./deploy/deploy.sh subir                constrói e sobe a stack nova
#   ./deploy/deploy.sh migrar               backup + migrações do banco
#   ./deploy/deploy.sh publicar DOMINIO     nginx do host + certificado
#   ./deploy/deploy.sh trocar               aponta o domínio para a stack nova
#   ./deploy/deploy.sh reverter             desfaz a troca
#   ./deploy/deploy.sh status               saúde da stack nova
#   ./deploy/deploy.sh parar-antigo NOME    para (sem apagar) a stack antiga
#
set -euo pipefail

PROJETO="willians-prod"
COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE=".env.production"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUPS="$RAIZ/deploy/backups"

cd "$RAIZ"

# ------------------------------------------------------------------ aparência

vermelho() { printf '\033[31m%s\033[0m\n' "$*"; }
verde()    { printf '\033[32m%s\033[0m\n' "$*"; }
amarelo()  { printf '\033[33m%s\033[0m\n' "$*"; }
titulo()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
passo()    { printf '   %s\n' "$*"; }

erro() { vermelho "ERRO: $*"; exit 1; }

confirmar() {
  local pergunta="$1"
  read -r -p "   $pergunta [s/N] " resposta
  [[ "$resposta" =~ ^[sSyY]$ ]]
}

# ------------------------------------------------------------------ utilidades

compose() {
  docker compose -p "$PROJETO" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

exigir() {
  command -v "$1" >/dev/null 2>&1 || erro "$1 não encontrado. Instale antes de continuar."
}

# Uma porta só é considerada livre se nada estiver escutando nela. Numa VPS
# compartilhada este é o ponto mais provável de estrago.
porta_ocupada() {
  local porta="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$porta" 2>/dev/null | grep -q . && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -qE "[:.]$porta[[:space:]]" && return 0
  fi

  # Segunda checagem: alguém pode ter mapeado a porta no Docker sem estar
  # escutando agora.
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "(^|[^0-9]):$porta->" && return 0

  return 1
}

porta_livre() {
  local candidata="${1:-8090}"

  for _ in $(seq 1 40); do
    porta_ocupada "$candidata" || { echo "$candidata"; return 0; }
    candidata=$((candidata + 1))
  done

  erro "não achei porta livre a partir de ${1:-8090}."
}

porta_configurada() {
  grep -E "^APP_PORT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' ' || true
}

exigir_env() {
  [[ -f "$ENV_FILE" ]] || erro "$ENV_FILE não existe. Rode: ./deploy/deploy.sh preparar"
}

segredo() { openssl rand -hex 32; }

# ---------------------------------------------------------------- inspecionar

cmd_inspecionar() {
  titulo "Ferramentas"
  for f in docker git openssl; do
    command -v "$f" >/dev/null 2>&1 && passo "ok    $f" || vermelho "   FALTA $f"
  done
  docker compose version >/dev/null 2>&1 && passo "ok    docker compose" || vermelho "   FALTA docker compose (plugin v2)"
  command -v nginx >/dev/null 2>&1 && passo "ok    nginx" || amarelo "   ausente nginx (só precisa para publicar)"
  command -v certbot >/dev/null 2>&1 && passo "ok    certbot" || amarelo "   ausente certbot (só precisa para HTTPS)"

  titulo "Containers em execução nesta máquina"
  docker ps --format '   {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || passo "(sem acesso ao docker)"

  titulo "Projetos compose existentes"
  docker ps -a --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null \
    | grep -v '^$' | sort -u | sed 's/^/   /' || passo "(nenhum)"

  titulo "Portas TCP em escuta"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/^/   /' | sort -u | head -30
  else
    amarelo "   ss não disponível"
  fi

  titulo "Sites do nginx"
  if [[ -d /etc/nginx/sites-enabled ]]; then
    ls -1 /etc/nginx/sites-enabled 2>/dev/null | sed 's/^/   /' || passo "(vazio)"
  elif [[ -d /etc/nginx/conf.d ]]; then
    ls -1 /etc/nginx/conf.d 2>/dev/null | sed 's/^/   /' || passo "(vazio)"
  else
    passo "(nginx não instalado)"
  fi

  titulo "Stack nova (${PROJETO})"
  if docker ps -a --filter "label=com.docker.compose.project=$PROJETO" --format '{{.Names}}' | grep -q .; then
    docker ps -a --filter "label=com.docker.compose.project=$PROJETO" \
      --format '   {{.Names}}\t{{.Status}}'
  else
    passo "ainda não existe nesta máquina"
  fi

  titulo "Leia antes de seguir"
  cat <<'AVISO'
   Este script NÃO apaga nem altera nada que não tenha criado. O sistema
   antigo continua no ar até você rodar `trocar`, e continua existindo
   (parado) depois disso, para o caso de precisar voltar.
AVISO
}

# -------------------------------------------------------------------- preparar

cmd_preparar() {
  titulo "Preparando $ENV_FILE"

  if [[ -f "$ENV_FILE" ]]; then
    passo "$ENV_FILE já existe; nada foi sobrescrito."
  else
    cp .env.production.example "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    passo "criado a partir de .env.production.example (modo 600)"
  fi

  # Gera só o que está vazio: rodar duas vezes não troca segredo já em uso —
  # trocar a chave de encryption tornaria ilegíveis os tokens já gravados.
  local gerou=0
  for chave in SECRET_KEY_BASE POSTGRES_PASSWORD SERVICE_API_TOKEN \
               AR_ENCRYPTION_PRIMARY_KEY AR_ENCRYPTION_DETERMINISTIC_KEY \
               AR_ENCRYPTION_KEY_DERIVATION_SALT; do
    local atual
    atual="$(grep -E "^${chave}=" "$ENV_FILE" | cut -d= -f2- || true)"

    if [[ -z "$atual" ]]; then
      local valor
      valor="$(segredo)"
      # Delimitador | porque hex não contém |.
      sed -i "s|^${chave}=.*|${chave}=${valor}|" "$ENV_FILE"
      passo "gerado  $chave"
      gerou=$((gerou + 1))
    else
      passo "mantido $chave (já preenchido)"
    fi
  done

  local porta
  porta="$(porta_configurada)"

  if [[ -z "$porta" ]] || porta_ocupada "$porta"; then
    local nova
    nova="$(porta_livre 8090)"
    sed -i "s|^APP_PORT=.*|APP_PORT=${nova}|" "$ENV_FILE"
    [[ -n "$porta" ]] && amarelo "   porta $porta está ocupada; troquei para $nova"
    passo "porta local: $nova (só 127.0.0.1)"
  else
    passo "porta local: $porta (livre)"
  fi

  titulo "Falta você preencher"
  cat <<'FALTA'
   PUBLIC_HOST         domínio, sem protocolo
   APP_PUBLIC_URL      https://SEU-DOMINIO
   FRONTEND_ORIGINS    https://SEU-DOMINIO
   OMIE_APP_KEY/SECRET chaves do aplicativo OMIE

   As chaves de ML, Shopee, Amazon e Tiny podem ficar em branco: a tela de
   Configurações grava cifrado no banco, por empresa.

   OMIE_ALLOW_WRITES fica VAZIO até você validar em simulação. Com `true` o
   sistema passa a gravar na contabilidade do cliente.
FALTA
  printf '\n   nano %s\n\n' "$ENV_FILE"
}

# ----------------------------------------------------------------------- subir

cmd_subir() {
  exigir docker
  exigir_env

  local porta
  porta="$(porta_configurada)"
  [[ -n "$porta" ]] || erro "APP_PORT não definido em $ENV_FILE"

  # A stack pode já estar de pé e reusando a própria porta; só é conflito se
  # quem estiver escutando não formos nós.
  if porta_ocupada "$porta" && ! docker ps --filter "label=com.docker.compose.project=$PROJETO" --format '{{.Ports}}' | grep -q ":$porta->"; then
    erro "a porta $porta está ocupada por outro serviço. Edite APP_PORT em $ENV_FILE."
  fi

  titulo "Construindo imagens"
  compose build

  titulo "Subindo (projeto $PROJETO)"
  compose up -d

  passo "aguardando o backend responder..."
  local tentativas=0
  until compose exec -T backend bin/rails runner 'puts 1' >/dev/null 2>&1; do
    tentativas=$((tentativas + 1))
    [[ $tentativas -gt 30 ]] && erro "o backend não subiu. Veja: docker compose -p $PROJETO logs backend"
    sleep 4
  done

  verde "   stack no ar em http://127.0.0.1:$porta (ainda não publicada)"
  passo "próximo: ./deploy/deploy.sh migrar"
}

# ---------------------------------------------------------------------- migrar

cmd_migrar() {
  exigir_env

  mkdir -p "$BACKUPS"

  local arquivo="$BACKUPS/antes-da-migracao-$(date +%Y%m%d-%H%M%S).sql.gz"

  titulo "Backup do banco antes de migrar"
  if compose exec -T db pg_isready -U backend >/dev/null 2>&1; then
    compose exec -T db pg_dumpall -U backend | gzip > "$arquivo"
    verde "   $arquivo ($(du -h "$arquivo" | cut -f1))"
  else
    amarelo "   banco ainda vazio; nada a salvar"
  fi

  titulo "Migrações"
  # db:prepare cria também os bancos de cache, fila e cable do Solid.
  compose exec -T backend bin/rails db:prepare

  verde "   banco em dia"

  titulo "Primeiro acesso"
  if confirmar "Criar um usuário administrador agora?"; then
    read -r -p "   e-mail: " email
    read -r -s -p "   senha (mínimo 12 caracteres): " senha; echo
    read -r -p "   nome da empresa: " empresa

    EMAIL="$email" SENHA="$senha" EMPRESA="$empresa" \
      compose exec -T \
        -e EMAIL="$email" -e SENHA="$senha" -e EMPRESA="$empresa" \
        backend bin/rails runner '
          usuario = User.find_or_initialize_by(email: ENV["EMAIL"])
          usuario.update!(name: ENV["EMAIL"].split("@").first, password: ENV["SENHA"], status: :active)
          tenant = Tenant.find_or_create_by!(name: ENV["EMPRESA"]) { |t| t.status = :active }
          TenantUser.find_or_create_by!(tenant: tenant, user: usuario) { |m| m.role = :owner }
          puts "usuário #{usuario.email} pronto na empresa #{tenant.name}"
        '
  fi
}

# -------------------------------------------------------------------- publicar

cmd_publicar() {
  local dominio="${1:-}"
  [[ -n "$dominio" ]] || erro "informe o domínio: ./deploy/deploy.sh publicar app.exemplo.com.br"

  exigir_env
  exigir nginx

  local porta
  porta="$(porta_configurada)"

  local destino
  if [[ -d /etc/nginx/sites-available ]]; then
    destino="/etc/nginx/sites-available/willians"
  else
    destino="/etc/nginx/conf.d/willians.conf"
  fi

  titulo "Site do nginx: $destino"

  if [[ -f "$destino" ]]; then
    local copia="${destino}.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp "$destino" "$copia"
    passo "cópia de segurança: $copia"
  fi

  sed -e "s|{{DOMINIO}}|$dominio|g" -e "s|{{PORTA}}|$porta|g" \
    infra/nginx/site.conf.modelo | sudo tee "$destino" >/dev/null

  if [[ -d /etc/nginx/sites-enabled ]]; then
    sudo ln -sf "$destino" /etc/nginx/sites-enabled/willians
  fi

  titulo "Conferindo a configuração do nginx"
  # `nginx -t` valida TODOS os sites: se algo de outro sistema quebrar aqui, é
  # melhor descobrir antes de recarregar.
  sudo nginx -t || erro "configuração inválida. Nada foi recarregado; o site anterior segue valendo."

  sudo systemctl reload nginx
  verde "   nginx recarregado"

  if command -v certbot >/dev/null 2>&1; then
    if confirmar "Emitir certificado para $dominio com o certbot?"; then
      sudo certbot --nginx -d "$dominio" --redirect
    fi
  else
    amarelo "   certbot ausente: o site está em HTTP. O OAuth dos marketplaces EXIGE HTTPS."
  fi

  passo "confira: curl -I https://$dominio"
}

# ---------------------------------------------------------------------- trocar

cmd_trocar() {
  exigir_env

  local porta
  porta="$(porta_configurada)"

  titulo "Trocar o sistema antigo pelo novo"
  cat <<AVISO
   O domínio passa a apontar para a stack nova (127.0.0.1:$porta).
   O sistema antigo NAO e apagado: continua parado, e o comando reverter
   traz a configuracao anterior de volta.
AVISO

  confirmar "Confirma a troca?" || { passo "cancelado"; return 0; }

  local destino
  if [[ -f /etc/nginx/sites-available/willians ]]; then
    destino="/etc/nginx/sites-available/willians"
  else
    destino="/etc/nginx/conf.d/willians.conf"
  fi

  [[ -f "$destino" ]] || erro "site não encontrado. Rode: ./deploy/deploy.sh publicar DOMINIO"

  local copia="${destino}.bak-$(date +%Y%m%d-%H%M%S)"
  sudo cp "$destino" "$copia"
  passo "cópia de segurança: $copia"

  # Troca só a porta do proxy_pass, preservando TLS e o resto que o certbot
  # tenha acrescentado.
  sudo sed -i -E "s|proxy_pass http://127\.0\.0\.1:[0-9]+|proxy_pass http://127.0.0.1:$porta|g" "$destino"

  sudo nginx -t || {
    sudo cp "$copia" "$destino"
    erro "configuração inválida; restaurei a anterior."
  }

  sudo systemctl reload nginx
  verde "   domínio apontando para a stack nova"
  passo "para desfazer: ./deploy/deploy.sh reverter"
}

# -------------------------------------------------------------------- reverter

cmd_reverter() {
  local destino
  if [[ -f /etc/nginx/sites-available/willians ]]; then
    destino="/etc/nginx/sites-available/willians"
  else
    destino="/etc/nginx/conf.d/willians.conf"
  fi

  local ultima
  ultima="$(ls -1t "${destino}".bak-* 2>/dev/null | head -1 || true)"

  [[ -n "$ultima" ]] || erro "não há cópia de segurança para restaurar."

  titulo "Restaurando $ultima"
  confirmar "Confirma?" || { passo "cancelado"; return 0; }

  sudo cp "$ultima" "$destino"
  sudo nginx -t || erro "a cópia restaurada não valida. Confira $destino à mão."
  sudo systemctl reload nginx

  verde "   configuração anterior restaurada"
  passo "para religar o sistema antigo: docker compose -p NOME start"
}

# ---------------------------------------------------------------- parar-antigo

cmd_parar_antigo() {
  local nome="${1:-}"
  [[ -n "$nome" ]] || erro "informe o nome do projeto compose antigo (veja em: ./deploy/deploy.sh inspecionar)."

  [[ "$nome" == "$PROJETO" ]] && erro "esse é o projeto NOVO. Não faz sentido pará-lo aqui."

  titulo "Parando o projeto $nome"
  cat <<'AVISO'
   Os containers são apenas PARADOS. Volumes, dados e imagens continuam
   intactos, e `docker compose -p NOME start` traz tudo de volta.
AVISO

  confirmar "Confirma?" || { passo "cancelado"; return 0; }

  docker ps --filter "label=com.docker.compose.project=$nome" -q | xargs -r docker stop

  verde "   projeto $nome parado (não apagado)"
}

# ---------------------------------------------------------------------- status

cmd_status() {
  exigir_env

  local porta
  porta="$(porta_configurada)"

  titulo "Containers"
  compose ps

  titulo "Resposta local"
  if curl -fsS -o /dev/null -w '   HTTP %{http_code} em %{time_total}s\n' "http://127.0.0.1:$porta/" 2>/dev/null; then
    verde "   front respondendo"
  else
    vermelho "   front não respondeu em 127.0.0.1:$porta"
  fi

  if curl -fsS -o /dev/null -w '   HTTP %{http_code} (api)\n' "http://127.0.0.1:$porta/api/up" 2>/dev/null; then
    verde "   api respondendo"
  else
    vermelho "   api não respondeu"
  fi

  titulo "Escrita no OMIE"
  if grep -qE '^OMIE_ALLOW_WRITES=(true|1)$' "$ENV_FILE"; then
    amarelo "   LIBERADA — o sistema grava na contabilidade do cliente"
  else
    passo "bloqueada (simulação). Libere só depois de validar."
  fi
}

# ------------------------------------------------------------------------ main

case "${1:-inspecionar}" in
  inspecionar)   cmd_inspecionar ;;
  preparar)      cmd_preparar ;;
  subir)         cmd_subir ;;
  migrar)        cmd_migrar ;;
  publicar)      cmd_publicar "${2:-}" ;;
  trocar)        cmd_trocar ;;
  reverter)      cmd_reverter ;;
  parar-antigo)  cmd_parar_antigo "${2:-}" ;;
  status)        cmd_status ;;
  *)
    erro "comando desconhecido: $1
   use: inspecionar | preparar | subir | migrar | publicar DOMINIO | trocar | reverter | parar-antigo NOME | status"
    ;;
esac
