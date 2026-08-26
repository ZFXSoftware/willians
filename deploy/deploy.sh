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
#   ./deploy/deploy.sh publicar DOMINIO     escreve o site (ainda desativado)
#   ./deploy/deploy.sh trocar DOMINIO       desativa o antigo e ativa o novo
#   ./deploy/deploy.sh reverter             desfaz a troca
#   ./deploy/deploy.sh status               saúde da stack nova
#   ./deploy/deploy.sh estado               o que está conectado e importado
#   ./deploy/deploy.sh rake TAREFA [VAR=x]  roda uma tarefa de diagnóstico
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
  local dominio="${1:-}"

  # Aceita colado do navegador: tira protocolo, barra final e caminho.
  dominio="${dominio#http://}"
  dominio="${dominio#https://}"
  dominio="${dominio%%/*}"

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

  # As três variáveis do domínio precisam ser coerentes entre si. Preenchê-las
  # à mão é onde nasce o erro clássico: barra sobrando no APP_PUBLIC_URL, que
  # faz a redirect_uri deixar de bater com a cadastrada no portal do
  # marketplace — e o OAuth falha com uma mensagem que não ajuda.
  if [[ -n "$dominio" ]]; then
    titulo "Domínio"

    sed -i "s|^PUBLIC_HOST=.*|PUBLIC_HOST=${dominio}|" "$ENV_FILE"
    sed -i "s|^APP_PUBLIC_URL=.*|APP_PUBLIC_URL=https://${dominio}|" "$ENV_FILE"
    sed -i "s|^FRONTEND_ORIGINS=.*|FRONTEND_ORIGINS=https://${dominio}|" "$ENV_FILE"

    passo "PUBLIC_HOST      = $dominio"
    passo "APP_PUBLIC_URL   = https://$dominio"
    passo "FRONTEND_ORIGINS = https://$dominio"

    titulo "URLs de retorno para cadastrar nos portais"
    cat <<URLS
   Precisam bater CARACTERE POR CARACTERE com o que estiver cadastrado:

     https://${dominio}/api/integracoes/mercado-livre/callback
     https://${dominio}/api/integracoes/shopee/callback
     https://${dominio}/api/integracoes/amazon/callback
URLS
  fi

  titulo "Falta você preencher"

  [[ -z "$dominio" ]] && cat <<'FALTA'
   PUBLIC_HOST         domínio, sem protocolo
   APP_PUBLIC_URL      https://SEU-DOMINIO
   FRONTEND_ORIGINS    https://SEU-DOMINIO
FALTA

  cat <<'FALTA'
   OMIE_APP_KEY/SECRET chaves do aplicativo OMIE

   Elas já existem no .env do sistema antigo, nesta mesma máquina — copie de
   lá em vez de gerar de novo, para o cliente continuar sendo o mesmo no OMIE.

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

# ------------------------------------------------------------- nginx: auxiliares

SITE_NOVO="willians-prod"

DISABLED="$RAIZ/deploy/sites-desativados"

caminho_do_site() {
  if [[ -d /etc/nginx/sites-available ]]; then
    echo "/etc/nginx/sites-available/$1"
  else
    echo "/etc/nginx/conf.d/$1.conf"
  fi
}

# Sites ATIVOS que respondem por este domínio, exceto o nosso.
#
# Procurar pelo server_name, e não por nome de arquivo, porque a instalação
# antiga pode ter qualquer nome — na VPS do cliente são dois arquivos
# (willians-api e willians-frontend) para dois domínios.
sites_que_atendem() {
  local dominio="$1"
  local dir=/etc/nginx/sites-enabled

  [[ -d "$dir" ]] || dir=/etc/nginx/conf.d

  grep -lE "server_name[^;]*\b${dominio//./\\.}\b" "$dir"/* 2>/dev/null \
    | while read -r arquivo; do
        [[ "$(basename "$arquivo")" == "$SITE_NOVO"* ]] || basename "$arquivo"
      done
}

# Bloco `listen` do servidor TLS, na sintaxe que ESTA versão do nginx entende.
#
# A diretiva `http2 on;` só existe a partir do 1.25.1. Nas anteriores o HTTP/2
# é ligado no próprio listen, e usar a forma nova derruba o `nginx -t` inteiro
# com "unknown directive".
listen_tls() {
  local versao
  versao="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

  local menor
  menor="$(printf '%s\n%s\n' "${versao:-0.0.0}" "1.25.1" | sort -V | head -1)"

  if [[ "$menor" == "1.25.1" ]]; then
    printf '    listen 443 ssl;\n    listen [::]:443 ssl;\n\n    http2 on;'
  else
    printf '    listen 443 ssl http2;\n    listen [::]:443 ssl http2;'
  fi
}

# Certificado que cobre o domínio. O certbot guarda em /live/<primeiro nome>/,
# então o diretório pode ter o nome de OUTRO domínio do mesmo certificado —
# é o caso da VPS, onde api.* usa o certificado emitido para dev.*.
certificado_para() {
  local dominio="$1"

  local direto="/etc/letsencrypt/live/$dominio/fullchain.pem"

  [[ -f "$direto" ]] && { echo "/etc/letsencrypt/live/$dominio"; return 0; }

  local dir
  for dir in /etc/letsencrypt/live/*/; do
    [[ -f "$dir/fullchain.pem" ]] || continue

    if sudo openssl x509 -in "$dir/fullchain.pem" -noout -text 2>/dev/null \
         | grep -qE "DNS:${dominio//./\\.}(,|$| )"; then
      echo "${dir%/}"
      return 0
    fi
  done

  return 1
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
  destino="$(caminho_do_site "$SITE_NOVO")"

  titulo "Preparando o site $destino"

  local cert_dir=""

  if cert_dir="$(certificado_para "$dominio")"; then
    passo "certificado encontrado: $cert_dir"
  else
    cert_dir=""
    amarelo "   sem certificado para $dominio"
  fi

  local conteudo
  conteudo="$(cat infra/nginx/site.conf.modelo)"

  if [[ -n "$cert_dir" ]]; then
    # Estes dois arquivos só existem se o certbot os tiver criado. Referenciar
    # um que não existe faz o `nginx -t` falhar — e derrubaria o reload de
    # TODOS os sites da máquina, não só o nosso.
    local opcoes_ssl=""

    [[ -f /etc/letsencrypt/options-ssl-nginx.conf ]] &&
      opcoes_ssl="    include /etc/letsencrypt/options-ssl-nginx.conf;"

    [[ -f /etc/letsencrypt/ssl-dhparams.pem ]] &&
      opcoes_ssl="${opcoes_ssl}
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;"

    local listen
    listen="$(listen_tls)"

    passo "sintaxe de HTTP/2: $(printf '%s' "$listen" | tail -1 | sed 's/^ *//')"

    conteudo="${conteudo//\{\{LISTEN_TLS\}\}/$listen}"
    conteudo="${conteudo//\{\{OPCOES_SSL\}\}/$opcoes_ssl}"
    conteudo="${conteudo//\{\{REDIRECT_HTTPS\}\}/    return 301 https://\$host\$request_uri;}"
    conteudo="${conteudo//\{\{BLOCO_TLS_INICIO\}\}/}"
    conteudo="${conteudo//\{\{BLOCO_TLS_FIM\}\}/}"
    conteudo="${conteudo//\{\{CERT_FULLCHAIN\}\}/$cert_dir/fullchain.pem}"
    conteudo="${conteudo//\{\{CERT_KEY\}\}/$cert_dir/privkey.pem}"
  else
    # Sem certificado: serve em HTTP e o bloco TLS sai do arquivo. O certbot
    # roda depois, quando o domínio já apontar para cá.
    conteudo="${conteudo//\{\{REDIRECT_HTTPS\}\}/    location \/ \{
        proxy_pass http:\/\/127.0.0.1:$porta;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
    \}}"
    conteudo="$(printf '%s' "$conteudo" | sed '/{{BLOCO_TLS_INICIO}}/,/{{BLOCO_TLS_FIM}}/d')"
  fi

  conteudo="${conteudo//\{\{DOMINIO\}\}/$dominio}"
  conteudo="${conteudo//\{\{PORTA\}\}/$porta}"

  if [[ -f "$destino" ]]; then
    local copia="${destino}.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp "$destino" "$copia"
    passo "cópia de segurança: $copia"
  fi

  printf '%s\n' "$conteudo" | sudo tee "$destino" >/dev/null

  # Escrito, mas NÃO ativado: dois sites com o mesmo server_name fariam o nginx
  # ignorar um deles em silêncio. A ativação acontece no `trocar`, junto com a
  # desativação do antigo.
  verde "   site escrito (ainda DESATIVADO)"

  titulo "Sites que hoje atendem $dominio"
  local antigos
  antigos="$(sites_que_atendem "$dominio")"

  if [[ -n "$antigos" ]]; then
    echo "$antigos" | sed 's/^/   /'
    passo ""
    passo "O comando trocar desativa esses e ativa o novo, numa operação só."
  else
    amarelo "   nenhum — o domínio pode não estar apontando para esta máquina"
  fi

  [[ -z "$cert_dir" ]] && amarelo "
   Sem HTTPS o OAuth dos marketplaces NÃO funciona. Depois de trocar, rode:
     sudo certbot --nginx -d $dominio"

  passo "próximo: ./deploy/deploy.sh trocar $dominio"
}

# ---------------------------------------------------------------------- trocar

cmd_trocar() {
  local dominio="${1:-}"
  [[ -n "$dominio" ]] || erro "informe o domínio: ./deploy/deploy.sh trocar app.exemplo.com.br"

  exigir_env

  local porta
  porta="$(porta_configurada)"

  local destino
  destino="$(caminho_do_site "$SITE_NOVO")"

  [[ -f "$destino" ]] || erro "site não preparado. Rode: ./deploy/deploy.sh publicar $dominio"

  local antigos
  antigos="$(sites_que_atendem "$dominio")"

  titulo "Trocar o sistema antigo pelo novo"

  cat <<AVISO
   $dominio passa a ser servido pela stack nova (127.0.0.1:$porta),
   que entrega a interface, /api e /gateway na MESMA origem.
AVISO

  if [[ -n "$antigos" ]]; then
    passo ""
    passo "Serão DESATIVADOS (arquivo preservado, só sai de sites-enabled):"
    echo "$antigos" | sed 's/^/     /'
  fi

  cat <<'AVISO'

   Nada e apagado: os arquivos continuam em sites-available, os containers
   antigos seguem rodando, e o comando reverter desfaz tudo.
AVISO

  confirmar "Confirma a troca?" || { passo "cancelado"; return 0; }

  mkdir -p "$DISABLED"

  # Guarda quais foram desativados, para o reverter saber o que religar.
  local registro="$DISABLED/ultima-troca.txt"
  : | sudo tee "$registro" >/dev/null 2>&1 || true
  echo "$antigos" > "$registro"

  local nome
  while read -r nome; do
    [[ -n "$nome" ]] || continue
    sudo rm -f "/etc/nginx/sites-enabled/$nome"
    passo "desativado: $nome"
  done <<< "$antigos"

  if [[ -d /etc/nginx/sites-enabled ]]; then
    sudo ln -sf "$destino" "/etc/nginx/sites-enabled/$SITE_NOVO"
    passo "ativado: $SITE_NOVO"
  fi

  if ! sudo nginx -t; then
    # Desfaz na hora: o domínio não pode ficar sem site nenhum.
    sudo rm -f "/etc/nginx/sites-enabled/$SITE_NOVO"
    while read -r nome; do
      [[ -n "$nome" ]] || continue
      sudo ln -sf "$(caminho_do_site "$nome")" "/etc/nginx/sites-enabled/$nome"
    done <<< "$antigos"
    erro "configuração inválida; restaurei os sites anteriores. Nada foi recarregado."
  fi

  sudo systemctl reload nginx

  verde "   $dominio agora é a stack nova"
  passo "confira: curl -I https://$dominio"
  passo "para desfazer: ./deploy/deploy.sh reverter"

  avisar_sites_orfaos "$porta"
}

# Sites que continuam ativos apontando para a stack ANTIGA.
#
# Com origem única, o domínio separado da API perde a função — mas o site dele
# segue no ar mirando a porta antiga. No dia em que a stack antiga for parada,
# ele passa a devolver 502 sem explicação.
avisar_sites_orfaos() {
  local porta_nova="$1"
  local dir=/etc/nginx/sites-enabled

  [[ -d "$dir" ]] || return 0

  local achou=0
  local arquivo alvo

  for arquivo in "$dir"/*; do
    [[ -f "$arquivo" || -L "$arquivo" ]] || continue
    [[ "$(basename "$arquivo")" == "$SITE_NOVO"* ]] && continue

    # Só interessam os que miram a máquina local numa porta diferente da nossa.
    alvo="$(grep -oE "proxy_pass +http://127\.0\.0\.1:[0-9]+" "$arquivo" 2>/dev/null | grep -oE "[0-9]+$" | head -1)"

    [[ -n "$alvo" && "$alvo" != "$porta_nova" ]] || continue

    # E que pertençam ao Willians: não é da nossa conta apontar o dedo para os
    # outros sistemas da máquina.
    grep -qiE "willians|conciliation" "$arquivo" 2>/dev/null || continue

    if [[ $achou -eq 0 ]]; then
      titulo "Sites que ainda apontam para a stack antiga"
      achou=1
    fi

    passo "$(basename "$arquivo") -> 127.0.0.1:$alvo"
  done

  [[ $achou -eq 1 ]] && cat <<'AVISO'

   Com origem única esses domínios ficaram sem função: a interface, /api e
   /gateway saem todos do domínio principal.

   Enquanto a stack antiga roda, eles continuam funcionando. Quando você rodar
   `parar-antigo`, passam a devolver 502. Decida antes:

     - desativar:  sudo rm /etc/nginx/sites-enabled/NOME && sudo systemctl reload nginx
     - ou apontar para a stack nova, editando o proxy_pass do arquivo
AVISO

  return 0
}

# -------------------------------------------------------------------- reverter

cmd_reverter() {
  local registro="$DISABLED/ultima-troca.txt"

  [[ -f "$registro" ]] || erro "não há troca registrada para desfazer."

  titulo "Desfazendo a última troca"

  passo "Serão reativados:"
  sed 's/^/     /' "$registro"

  confirmar "Confirma?" || { passo "cancelado"; return 0; }

  local nome
  while read -r nome; do
    [[ -n "$nome" ]] || continue
    sudo ln -sf "$(caminho_do_site "$nome")" "/etc/nginx/sites-enabled/$nome"
    passo "reativado: $nome"
  done < "$registro"

  sudo rm -f "/etc/nginx/sites-enabled/$SITE_NOVO"

  sudo nginx -t || erro "a configuração restaurada não valida. Confira à mão antes de recarregar."
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

# ------------------------------------------------------------------------ rake

# Atalho para as tarefas de diagnóstico e importação.
#
# Existe porque a alternativa é decorar (ou colar) a linha inteira do compose
# com projeto, arquivo e env-file — e uma linha longa colada pela metade vira
# erro que não tem nada a ver com o problema que se está investigando.
#
# `VAR=valor` funciona como argumento: o rake atribui ao ambiente sozinho.
#
#   ./deploy/deploy.sh rake omie:opcoes BUSCA=mercado
#   ./deploy/deploy.sh rake omie:enviar_notas APLICAR=1 LIMITE=1
cmd_rake() {
  exigir_env

  [[ $# -gt 0 ]] || erro "diga a tarefa. Ex.: ./deploy/deploy.sh rake tiny:check DIAS=90
   Disponíveis: estado | tiny:check | tiny:importar | omie:titulos | omie:opcoes
                omie:settings | omie:enviar_notas | liberacoes:corrigir_status
                repasses:corrigir_valores"

  compose exec -T backend bin/rails "$@"
}

# ----------------------------------------------------------------------- estado

# O status acima diz se a stack está DE PÉ. Este diz se ela está FUNCIONANDO:
# quais empresas existem, o que cada uma conectou e o que já foi importado.
cmd_estado() {
  exigir_env

  compose exec -T backend bin/rails estado
}

# ------------------------------------------------------------------------ main

case "${1:-inspecionar}" in
  estado)        cmd_estado ;;
  rake)          shift; cmd_rake "$@" ;;
  inspecionar)   cmd_inspecionar ;;
  preparar)      cmd_preparar "${2:-}" ;;
  subir)         cmd_subir ;;
  migrar)        cmd_migrar ;;
  publicar)      cmd_publicar "${2:-}" ;;
  trocar)        cmd_trocar "${2:-}" ;;
  reverter)      cmd_reverter ;;
  parar-antigo)  cmd_parar_antigo "${2:-}" ;;
  status)        cmd_status ;;
  *)
    erro "comando desconhecido: $1
   use: inspecionar | preparar | subir | migrar | publicar DOMINIO | trocar DOMINIO | reverter | parar-antigo NOME | status | estado | rake TAREFA"
    ;;
esac
