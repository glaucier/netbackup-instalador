#!/usr/bin/env bash
# =============================================================================
# NetBackup Manager - instalador (FASE 3b: da VM limpa até "acesse https://NOME:44318")
#
# Software proprietário, uso sob licença. Este arquivo é só o instalador.
#
# Uso:  sudo bash instalar.sh [--respostas ARQUIVO | --certificado | --check | --status | -h]
#
# Organização:
#   - cada etapa tem  check_<etapa>  (SÓ LEITURA, imprime ok/falta/aviso por item)
#     e  etapa_<etapa>_run  (age, depois de conferir o estado: idempotente);
#   - a lista ETAPAS define a ordem: precheck, perguntas (e confirmação), disco,
#     chave, codigo, config, deploy, https, firewall, relatorio. Toda PERGUNTA vem
#     antes de qualquer alteração (só a escolha do disco e o cadastro da chave
#     ficam no meio);
#   - estado conferível: --check (detalhado) e --status (resumo, sem rede);
#   - regra de ouro: o deploy.sh passa /opt/netbackup para o usuário netbackup.
#     Toda escrita do root em /opt/netbackup acontece ANTES dele (árvore ainda do
#     root e conferida por confia); depois dele o instalador nunca mais executa
#     nem escreve nada de lá. O que o HTTPS precisa do produto (modelo do Nginx)
#     fica numa cópia só do root.
# =============================================================================
set -u
export LC_ALL=C

VERSAO="0.2.0-dev"

# ---- Configuração (tudo sobrescrevível por ambiente; padrões = valores reais) --
REPO="${REPO:-git@github-netbackup:glaucier/netbackup-manager.git}"
BRANCH="${BRANCH:-main}"

GH_HOST="${GH_HOST:-github.com}"
GH_PORT="${GH_PORT:-443}"
# Impressão digital OFICIAL da chave ed25519 do GitHub (não sobrescrevível).
readonly GITHUB_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"

OPT_DIR="${OPT_DIR:-/opt}"
NB_DIR="${NB_DIR:-$OPT_DIR/netbackup}"
DEPLOY_SH="${DEPLOY_SH:-$NB_DIR/deploy/deploy.sh}"
FSTAB="${FSTAB:-/etc/fstab}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
MEMINFO="${MEMINFO:-/proc/meminfo}"
SSH_DIR="${SSH_DIR:-/root/.ssh}"
SSH_CONFIG="${SSH_CONFIG:-$SSH_DIR/config}"
KEY_FILE="${KEY_FILE:-$SSH_DIR/id_ed25519_github_netbackup_ro}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$SSH_DIR/known_hosts_github_netbackup}"
SSH_ALIAS="${SSH_ALIAS:-github-netbackup}"
LOG_DIR="${LOG_DIR:-/root}"

# Fase 3b: usuário do serviço, registros do instalador (só do root), respostas, relatório.
APP_USER="${APP_USER:-netbackup}"
ESTADO_DIR="${ESTADO_DIR:-/etc/netbackup-instalador}"
ESTADO_FILE="${ESTADO_FILE:-$ESTADO_DIR/estado.conf}"
PROVISORIO_DIR="${PROVISORIO_DIR:-$ESTADO_DIR/provisorio}"
SHARE_DIR="${SHARE_DIR:-/usr/local/share/netbackup-instalador}"
RESPOSTAS_SALVAS="${RESPOSTAS_SALVAS:-$LOG_DIR/netbackup-respostas.conf}"
RELATORIO_TXT="${RELATORIO_TXT:-$LOG_DIR/netbackup-instalacao.txt}"
ZONEINFO_DIR="${ZONEINFO_DIR:-/usr/share/zoneinfo}"
NGINX_SITE_DST="${NGINX_SITE_DST:-/etc/nginx/sites-available/netbackup}"
NGINX_SITE_LINK="${NGINX_SITE_LINK:-/etc/nginx/sites-enabled/netbackup}"
NGINX_DEFAULT_LINK="${NGINX_DEFAULT_LINK:-/etc/nginx/sites-enabled/default}"
LE_LIVE="${LE_LIVE:-/etc/letsencrypt/live}"
HOOKS_DIR="${HOOKS_DIR:-/etc/letsencrypt/renewal-hooks}"
DNS_RESOLVERS="${DNS_RESOLVERS:-1.1.1.1 8.8.8.8}"
LE_STAGING="${LE_STAGING:-0}"            # 1 = certbot --staging (bancada; não gasta limite)
HTTPS_PORT=44318
readonly UFW_COMMENT="NetBackup HTTPS (Nginx) - painel"   # o MESMO texto da tela Firewall do produto
readonly NGINX_MARK='@SERVER_NAME@'
readonly MARCA_PROVISORIO="# PROVISORIO - gerado por instalar.sh (não editar)"

VG_NAME="${VG_NAME:-dados-vg}"
LV_NAME="${LV_NAME:-opt-lv}"
LV_DEV="${LV_DEV:-/dev/$VG_NAME/$LV_NAME}"
FS_LABEL="${FS_LABEL:-nb-dados}"

MEM_MIN_MB="${MEM_MIN_MB:-1900}"    # ~2 GB nominais (a VM de 2 GB informa ~1,9 GB)
MEM_WARN_MB="${MEM_WARN_MB:-3800}"  # ~4 GB nominais
DISK_MIN_MB="${DISK_MIN_MB:-10240}" # espaço livre mínimo para /opt

# Confiança: dono esperado dos arquivos/pastas e até onde subir na conferência.
OWNER_UID="${OWNER_UID:-0}"
TRUST_TOP="${TRUST_TOP:-/}"

# Comandos (sobrescrevíveis para testes).
CMD_ID="${CMD_ID:-id}"
CMD_BASH="${CMD_BASH:-bash}"
CMD_GIT="${CMD_GIT:-git}"
CMD_SSH="${CMD_SSH:-ssh}"
CMD_SSH_KEYSCAN="${CMD_SSH_KEYSCAN:-ssh-keyscan}"
CMD_SSH_KEYGEN="${CMD_SSH_KEYGEN:-ssh-keygen}"
CMD_UFW="${CMD_UFW:-ufw}"
CMD_TIMEDATECTL="${CMD_TIMEDATECTL:-timedatectl}"
CMD_SYSTEMCTL="${CMD_SYSTEMCTL:-systemctl}"
CMD_DPKG="${CMD_DPKG:-dpkg}"
CMD_DF="${CMD_DF:-df}"
CMD_TIMEOUT="${CMD_TIMEOUT:-timeout}"
CMD_HOSTNAME="${CMD_HOSTNAME:-hostname}"
CMD_LSBLK="${CMD_LSBLK:-lsblk}"
CMD_WIPEFS="${CMD_WIPEFS:-wipefs}"
CMD_PVS="${CMD_PVS:-pvs}"
CMD_LVS="${CMD_LVS:-lvs}"
CMD_PVCREATE="${CMD_PVCREATE:-pvcreate}"
CMD_VGCREATE="${CMD_VGCREATE:-vgcreate}"
CMD_LVCREATE="${CMD_LVCREATE:-lvcreate}"
CMD_MKFS="${CMD_MKFS:-mkfs.ext4}"
CMD_BLKID="${CMD_BLKID:-blkid}"
CMD_MOUNT="${CMD_MOUNT:-mount}"
CMD_FINDMNT="${CMD_FINDMNT:-findmnt}"
CMD_STAT="${CMD_STAT:-stat}"
CMD_IP="${CMD_IP:-ip}"
CMD_DIG="${CMD_DIG:-dig}"
CMD_WHO="${CMD_WHO:-who}"
CMD_SS="${CMD_SS:-ss}"
CMD_CURL="${CMD_CURL:-curl}"
CMD_OPENSSL="${CMD_OPENSSL:-openssl}"
CMD_CERTBOT="${CMD_CERTBOT:-certbot}"
CMD_NGINX="${CMD_NGINX:-nginx}"
CMD_SHA256="${CMD_SHA256:-sha256sum}"

# Ordem das etapas. ETAPAS_LISTA (texto separado por espaços) só serve aos testes.
ETAPAS=(precheck perguntas disco chave codigo config deploy https firewall relatorio)
if [ -n "${ETAPAS_LISTA:-}" ]; then read -r -a ETAPAS <<<"$ETAPAS_LISTA"; fi

# ---- Estado global -----------------------------------------------------------
MODO="executar"
LOG_FILE=""
QUIET_ITEMS=0
CHECK_REMOTE=1
N_OK=0
N_FALTA=0
N_AVISO=0
RESP=""
MSG_CONFIANCA=""
AVISO_2204=0
RC_FINAL=0
DATA_STAMP=""
RESPOSTAS_ARQ=""        # --respostas ARQUIVO
R_CARREGADAS=0

# ---- Saída e log -------------------------------------------------------------
# O log é escrito por estas funções (nunca por redirecionamento da saída toda).
registra() {
  if [ -n "$LOG_FILE" ]; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
  fi
  return 0
}
saida() { printf '%s\n' "$*"; registra "$*"; }
erro() { printf 'ERRO: %s\n' "$*" >&2; registra "ERRO: $*"; }
aviso_msg() { printf 'AVISO: %s\n' "$*"; registra "AVISO: $*"; }
die() { erro "$*"; registra "Abortado (código 1)"; exit 1; }

item() { # $1 = ok|falta|aviso ; $2.. = texto
  local tipo="$1"; shift
  case "$tipo" in
    ok) N_OK=$((N_OK + 1)) ;;
    falta) N_FALTA=$((N_FALTA + 1)) ;;
    aviso) N_AVISO=$((N_AVISO + 1)) ;;
  esac
  if [ "$QUIET_ITEMS" != 1 ]; then saida "  [$tipo] $*"; fi
  return 0
}

zera_itens() { N_OK=0; N_FALTA=0; N_AVISO=0; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

pergunta() { # $1 = texto ; resposta em RESP ; retorna 1 se a entrada acabou
  printf '%s ' "$1"
  registra "PERGUNTA: $1"
  if ! IFS= read -r RESP; then
    RESP=""
    printf '\n'
    registra "RESPOSTA: (fim da entrada)"
    return 1
  fi
  RESP="$(trim "$RESP")"
  registra "RESPOSTA: $RESP"
  return 0
}

executa() { # roda um comando, mostra/loga a saída, devolve o código
  local out rc
  registra "EXEC: $*"
  out="$("$@" 2>&1)"
  rc=$?
  if [ -n "$out" ]; then saida "$out"; fi
  registra "EXEC rc=$rc"
  return "$rc"
}

# ---- Confiança em arquivos (nada gravável por outro usuário) -----------------
dono_perm_ok() { # $1 = caminho canônico existente
  local dono modo
  dono="$("$CMD_STAT" -c '%u' -- "$1" 2>/dev/null)" || { MSG_CONFIANCA="não foi possível ler o dono de $1"; return 1; }
  modo="$("$CMD_STAT" -c '%a' -- "$1" 2>/dev/null)" || { MSG_CONFIANCA="não foi possível ler as permissões de $1"; return 1; }
  if [ "$dono" != "$OWNER_UID" ]; then
    MSG_CONFIANCA="$1 não pertence ao root (dono uid $dono)"
    return 1
  fi
  if (( (8#$modo & 8#022) != 0 )); then
    MSG_CONFIANCA="$1 tem escrita para grupo/outros (modo $modo)"
    return 1
  fi
  return 0
}

# Confere o arquivo/pasta e todas as pastas acima dele (até TRUST_TOP).
confia() { # $1 = caminho
  local alvo topo p
  MSG_CONFIANCA=""
  alvo="$(realpath -e -- "$1" 2>/dev/null)" || { MSG_CONFIANCA="$1 não existe"; return 1; }
  topo="$(realpath -m -- "$TRUST_TOP")"
  dono_perm_ok "$alvo" || return 1
  p="$alvo"
  while [ "$p" != "/" ] && [ "$p" != "$topo" ]; do
    p="$(dirname -- "$p")"
    dono_perm_ok "$p" || return 1
  done
  return 0
}

# ---- Segurança do próprio instalador -----------------------------------------
exige_root() {
  local uid
  uid="$("$CMD_ID" -u 2>/dev/null)" || uid=""
  if [ "$uid" != "0" ]; then
    printf 'ERRO: este instalador precisa rodar como root (use: sudo bash instalar.sh).\n' >&2
    exit 1
  fi
}

exige_instalador_confiavel() {
  local self real nbreal
  self="${BASH_SOURCE[0]:-}"
  if [ -z "$self" ] || [ ! -f "$self" ]; then
    printf 'ERRO: rode o instalador a partir de um arquivo (baixe, confira o SHA256SUMS e execute: sudo bash instalar.sh).\n' >&2
    exit 1
  fi
  real="$(realpath -e -- "$self")"
  nbreal="$(realpath -m -- "$NB_DIR")"
  case "$real" in
    "$nbreal"/*)
      printf 'ERRO: não rode o instalador de dentro de %s; copie-o para uma pasta do root (ex.: /root/instalador).\n' "$NB_DIR" >&2
      exit 1 ;;
  esac
  if ! confia "$real"; then
    printf 'ERRO: instalador não confiável: %s.\n       Ele e todas as pastas acima devem ser do root e sem escrita para grupo/outros.\n' "$MSG_CONFIANCA" >&2
    exit 1
  fi
}

# ---- Utilidades de repositório -----------------------------------------------
repo_slug() { # git@host:dono/repo.git | https://host/dono/repo.git -> dono/repo
  local u="${1%.git}"
  case "$u" in
    *://*) u="${u#*://}"; u="${u#*/}" ;;
    *:*) u="${u#*:}" ;;
  esac
  printf '%s' "$u"
}

git_() { GIT_PAGER=cat GIT_TERMINAL_PROMPT=0 "$CMD_GIT" "$@"; }

# =============================================================================
# REGISTRO DE ESTADO (só do root) E "DEPLOY FEITO"
# =============================================================================
# O estado fica em $ESTADO_FILE (pasta do root). É lido como TEXTO: nada é
# executado nem recebe "source".
# O arquivo e a pasta dele têm de ser do root e sem escrita para grupo/outros (as pastas acima são /etc e /).
estado_confiavel() {
  local f
  f="$(realpath -e -- "$ESTADO_FILE" 2>/dev/null)" || return 1
  dono_perm_ok "$f" && dono_perm_ok "$(dirname -- "$f")"
}

estado_get() { # $1 = chave ; imprime o valor (ou nada)
  [ -f "$ESTADO_FILE" ] || return 0
  estado_confiavel || return 0
  sed -n -E "s/^$1=([A-Za-z0-9._:@\/+ -]*)\$/\1/p" "$ESTADO_FILE" | tail -n 1
}

estado_set() { # $1 = chave ; $2 = valor
  local k="$1" v="$2" tmp
  [[ $v =~ ^[A-Za-z0-9._:@/+\ -]*$ ]] || die "valor inválido para o registro de estado ($k)."
  install -d -m 755 -- "$ESTADO_DIR" || die "não foi possível criar $ESTADO_DIR."
  tmp="$(mktemp "$ESTADO_DIR/.estado.XXXXXX")" || die "não foi possível criar temporário em $ESTADO_DIR."
  {
    if [ -f "$ESTADO_FILE" ]; then grep -v -E "^$k=" "$ESTADO_FILE"; fi
    printf '%s=%s\n' "$k" "$v"
  } >"$tmp"
  if ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$ESTADO_FILE"; then rm -f -- "$tmp"; die "não foi possível gravar $ESTADO_FILE."; fi
}

# Define DEPLOY_ESTADO:
#   feito     - o instalador registrou o deploy.sh concluído
#   detectado - árvore do usuário netbackup e serviço habilitado (deploy feito à mão)
#   pendente  - a árvore ainda é do root (ou não existe): o deploy.sh pode rodar
#   recusa    - árvore de outro dono SEM sinal de deploy concluído (DEPLOY_MOTIVO)
# Depois de "feito"/"detectado" o instalador não executa nem escreve nada em NB_DIR.
DEPLOY_ESTADO=""
DEPLOY_MOTIVO=""
deploy_estado() {
  local uid nome
  DEPLOY_ESTADO=""; DEPLOY_MOTIVO=""
  if [ "$(estado_get DEPLOY_FEITO)" = "1" ]; then DEPLOY_ESTADO="feito"; return 0; fi
  if [ ! -e "$NB_DIR" ]; then DEPLOY_ESTADO="pendente"; return 0; fi
  uid="$("$CMD_STAT" -c '%u' -- "$NB_DIR" 2>/dev/null)"
  nome="$("$CMD_STAT" -c '%U' -- "$NB_DIR" 2>/dev/null)"
  if [ -z "$uid" ] || [ "$uid" = "$OWNER_UID" ]; then DEPLOY_ESTADO="pendente"; return 0; fi
  if [ "$nome" = "$APP_USER" ] && "$CMD_SYSTEMCTL" is-enabled --quiet netbackup.service >/dev/null 2>&1; then
    DEPLOY_ESTADO="detectado"; return 0
  fi
  # pasta vazia de outro dono: ainda não é caso de deploy; a etapa do código recusa com o motivo certo
  if [ -d "$NB_DIR" ] && [ -z "$(find "$NB_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    DEPLOY_ESTADO="pendente"; return 0
  fi
  DEPLOY_ESTADO="recusa"
  DEPLOY_MOTIVO="$NB_DIR pertence a '${nome:-?}' e não há registro de deploy concluído. O instalador não escreve nem executa nada numa pasta que não é do root. Se o deploy.sh foi interrompido, conclua-o à mão (sudo bash $NB_DIR/deploy/deploy.sh --dominio NOME) e rode o instalador de novo; ele reconhece o deploy concluído (serviço netbackup habilitado). O endurecimento posterior resolve isto de forma definitiva."
}

# =============================================================================
# VALIDAÇÕES (domínio, e-mail, rede, fuso, porta)
# =============================================================================
# Mesma regra do deploy.sh do produto: minúsculas, rótulos, ao menos um ponto,
# sem curinga, IP, porta nem http://.
dominio_valido() {
  local d=$1
  [ "${#d}" -ge 4 ] && [ "${#d}" -le 253 ] || return 1
  [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

email_valido() {
  local e=$1
  [ "${#e}" -le 254 ] || return 1
  [[ $e =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]{0,63}@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

ipv4_int() { # a.b.c.d -> inteiro (falha se inválido; sem zeros à esquerda)
  local ip=$1 o n=0
  local -a P
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a P <<<"$ip"
  for o in "${P[@]}"; do
    if [ "${#o}" -gt 1 ] && [ "${o:0:1}" = 0 ]; then return 1; fi
    [ "$((10#$o))" -le 255 ] || return 1
    n=$(( (n << 8) | 10#$o ))
  done
  printf '%s' "$n"
}

int_ipv4() { printf '%d.%d.%d.%d' $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 )); }

# Mesmas regras da tela Firewall do produto: só IPv4, estrito (sem bits de host),
# prefixo de /8 a /32; o endereço local só vale em rede privada; "privada" =
# 10/8, 172.16/12, 192.168/16, 127/8 (o CGNAT 100.64/10 não vale).
REDE_CANON=""
REDE_ERRO=""
rede_valida() { # $1 = painel|publica|privada ; $2 = rede (CIDR ou IPv4)
  local tipo=$1 r=$2 ip p n mask b bp bm ok=0
  REDE_CANON=""; REDE_ERRO=""
  if [ -z "$r" ] || [ "${#r}" -gt 18 ] || ! [[ $r =~ ^[0-9.]+(/[0-9]{1,2})?$ ]]; then
    REDE_ERRO="rede inválida '${r:0:40}' (use um prefixo IPv4 como 192.0.2.0/24)"; return 1
  fi
  ip=${r%%/*}; p=32
  if [[ $r == */* ]]; then p=${r#*/}; fi
  n="$(ipv4_int "$ip")" || { REDE_ERRO="endereço IPv4 inválido: $ip"; return 1; }
  if [ "${#p}" -gt 1 ] && [ "${p:0:1}" = 0 ]; then REDE_ERRO="prefixo inválido: /$p"; return 1; fi
  p=$((10#$p))
  if [ "$p" -lt 8 ] || [ "$p" -gt 32 ]; then
    REDE_ERRO="prefixo /$p fora do aceito (de /8 a /32; menor que /8 liberaria uma fatia enorme da internet)"; return 1
  fi
  mask=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  if [ $(( n & mask )) -ne "$n" ]; then
    REDE_ERRO="$r tem bits de host; use $(int_ipv4 $(( n & mask )))/$p"; return 1
  fi
  case "$tipo" in
    privada)
      for b in "167772160 8" "2886729728 12" "3232235520 16" "2130706432 8"; do
        bp=${b#* }; b=${b% *}
        bm=$(( (0xFFFFFFFF << (32 - bp)) & 0xFFFFFFFF ))
        if [ "$p" -ge "$bp" ] && [ $(( n & bm )) -eq "$b" ]; then ok=1; fi
      done
      if [ "$ok" != 1 ]; then
        REDE_ERRO="$r não é rede privada (aceitas: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8)"; return 1
      fi ;;
    *)
      if [ $(( n >> 24 )) -eq 127 ]; then
        REDE_ERRO="$r é o endereço local do servidor: só vale em rede privada"; return 1
      fi ;;
  esac
  REDE_CANON="$(int_ipv4 "$n")/$p"
}

# "CIDR descrição" (descrição opcional, uma linha, até 100 caracteres).
ENTRADA_OK=""
ENTRADA_ERRO=""
entrada_rede() { # $1 = tipo ; $2 = linha
  local linha r desc=""
  ENTRADA_OK=""; ENTRADA_ERRO=""
  linha="$(trim "$2")"
  r=${linha%%[[:space:]]*}
  if [ "$r" != "$linha" ]; then desc="$(trim "${linha#"$r"}")"; fi
  if [[ $desc =~ [[:cntrl:]] ]]; then ENTRADA_ERRO="a descrição não pode ter caractere de controle"; return 1; fi
  if [ "${#desc}" -gt 100 ]; then ENTRADA_ERRO="a descrição passa de 100 caracteres"; return 1; fi
  rede_valida "$1" "$r" || { ENTRADA_ERRO="$REDE_ERRO"; return 1; }
  ENTRADA_OK="$REDE_CANON"
  if [ -n "$desc" ]; then ENTRADA_OK="$REDE_CANON  $desc"; fi
}

# Nome IANA que existe em $ZONEINFO_DIR (sem posix/, right/, pontos nem curingas).
fuso_valido() {
  local z=$1
  [[ $z =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$ ]] || return 1
  case "$z" in posix/*|right/*|posixrules|localtime|Factory|leapseconds) return 1 ;; esac
  [ -f "$ZONEINFO_DIR/$z" ]
}

porta_valida() {
  local p=$1
  [[ $p =~ ^[1-9][0-9]{0,4}$ ]] && [ "$p" -le 65535 ]
}

# IPv6 -> forma única (minúsculas, sem zeros à esquerda, "::" expandido).
ipv6_norm() {
  local a="${1,,}" esq dir out="" h i
  local -a pe pd todos
  [[ $a =~ ^[0-9a-f:]+$ ]] || return 1
  [[ $a == *:::* ]] && return 1
  if [[ $a == *::* ]]; then
    esq=${a%%::*}; dir=${a#*::}
    [[ $dir == *::* ]] && return 1
    pe=(); pd=()
    if [ -n "$esq" ]; then IFS=: read -r -a pe <<<"$esq"; fi
    if [ -n "$dir" ]; then IFS=: read -r -a pd <<<"$dir"; fi
    [ $(( ${#pe[@]} + ${#pd[@]} )) -le 7 ] || return 1
    todos=("${pe[@]}")
    for (( i = ${#pe[@]} + ${#pd[@]}; i < 8; i++ )); do todos+=(0); done
    todos+=("${pd[@]}")
  else
    IFS=: read -r -a todos <<<"$a"
    [ "${#todos[@]}" -eq 8 ] || return 1
  fi
  for h in "${todos[@]}"; do
    [[ $h =~ ^[0-9a-f]{1,4}$ ]] || return 1
    out+="${out:+:}$(printf '%x' $((16#$h)))"
  done
  printf '%s' "$out"
}

# =============================================================================
# RESPOSTAS (arquivo CHAVE=valor, sem segredos)
# =============================================================================
P_SSH_PAD=22; P_HTTPS_PAD=443; P_HTTP_PAD=80; P_WINBOX_PAD=8291
R_DOMINIO=""; R_EMAIL=""; R_FUSO=""; R_PSSH=""; R_PHTTPS=""; R_PHTTP=""; R_PWINBOX=""
R_PAINEL=(); R_PUBLICAS=(); R_PRIVADAS=()
RESP_ERROS=()

resp_limpa() {
  R_DOMINIO=""; R_EMAIL=""; R_FUSO=""; R_PSSH=""; R_PHTTPS=""; R_PHTTP=""; R_PWINBOX=""
  R_PAINEL=(); R_PUBLICAS=(); R_PRIVADAS=(); R_CARREGADAS=0
}

resp_erro() { RESP_ERROS+=("$*"); }

resp_add() { local -n _d=$1; _d+=("$2"); }

resp_ja_tem() { # $1 = nome do array ; $2 = entrada "CIDR  desc" -> 0 se a rede já está
  local -n arr=$1
  local e
  for e in "${arr[@]}"; do [ "${e%% *}" = "${2%% *}" ] && return 0; done
  return 1
}

# Lê e valida o arquivo inteiro; nada é executado. Retorna 1 se houver erro (RESP_ERROS).
respostas_le() { # $1 = arquivo
  local f=$1 n=0 linha chave valor
  resp_limpa; RESP_ERROS=()
  if [ ! -f "$f" ] || [ -L "$f" ]; then resp_erro "arquivo de respostas não encontrado (ou é link): $f"; return 1; fi
  while IFS= read -r linha || [ -n "$linha" ]; do
    n=$((n + 1))
    linha="${linha%$'\r'}"
    linha="${linha//$'\t'/ }"
    linha="$(trim "$linha")"
    case "$linha" in ''|'#'*) continue ;; esac
    if [[ $linha =~ [[:cntrl:]] ]]; then resp_erro "linha $n: caractere de controle"; continue; fi
    if [[ $linha != *=* ]]; then resp_erro "linha $n: esperado CHAVE=valor"; continue; fi
    chave="$(trim "${linha%%=*}")"
    valor="$(trim "${linha#*=}")"
    case "$chave" in
      DOMINIO)
        [ -z "$R_DOMINIO" ] || { resp_erro "linha $n: DOMINIO repetido"; continue; }
        valor="${valor,,}"
        if dominio_valido "$valor"; then R_DOMINIO="$valor"
        else resp_erro "linha $n: DOMINIO inválido (minúsculas, ao menos um ponto, sem http://, porta, IP nem curinga)"; fi ;;
      EMAIL_LETSENCRYPT)
        [ -z "$R_EMAIL" ] || { resp_erro "linha $n: EMAIL_LETSENCRYPT repetido"; continue; }
        if email_valido "$valor"; then R_EMAIL="$valor"; else resp_erro "linha $n: EMAIL_LETSENCRYPT inválido"; fi ;;
      FUSO)
        [ -z "$R_FUSO" ] || { resp_erro "linha $n: FUSO repetido"; continue; }
        if fuso_valido "$valor"; then R_FUSO="$valor"; else resp_erro "linha $n: FUSO '$valor' não é um nome IANA existente"; fi ;;
      PORTA_SSH|PORTA_HTTPS|PORTA_HTTP|PORTA_WINBOX)
        if ! porta_valida "$valor"; then resp_erro "linha $n: $chave inválida (1 a 65535)"; continue; fi
        case "$chave" in
          PORTA_SSH) R_PSSH="$valor" ;; PORTA_HTTPS) R_PHTTPS="$valor" ;;
          PORTA_HTTP) R_PHTTP="$valor" ;; PORTA_WINBOX) R_PWINBOX="$valor" ;;
        esac ;;
      REDES_PAINEL|REDES_PUBLICAS|REDES_PRIVADAS)
        local tipo alvo
        case "$chave" in
          REDES_PAINEL) tipo=painel; alvo=R_PAINEL ;;
          REDES_PUBLICAS) tipo=publica; alvo=R_PUBLICAS ;;
          *) tipo=privada; alvo=R_PRIVADAS ;;
        esac
        if entrada_rede "$tipo" "$valor"; then
          resp_ja_tem "$alvo" "$ENTRADA_OK" || resp_add "$alvo" "$ENTRADA_OK"
        else
          resp_erro "linha $n: $chave: $ENTRADA_ERRO"
        fi ;;
      *) resp_erro "linha $n: chave desconhecida '${chave:0:30}'" ;;
    esac
  done <"$f"
  [ -n "$R_DOMINIO" ] || resp_erro "falta DOMINIO"
  [ -n "$R_EMAIL" ] || resp_erro "falta EMAIL_LETSENCRYPT"
  [ "${#R_PAINEL[@]}" -gt 0 ] || resp_erro "falta ao menos uma REDES_PAINEL (sem ela a instalação limpa responde 403 a todos)"
  if [ "${#RESP_ERROS[@]}" -gt 0 ]; then return 1; fi
  resp_defaults
  R_CARREGADAS=1
  return 0
}

fuso_servidor() { "$CMD_TIMEDATECTL" show -p Timezone --value 2>/dev/null | head -n 1; }

resp_defaults() {
  local z
  if [ -z "$R_FUSO" ]; then
    z="$(fuso_servidor)"
    if [ -n "$z" ] && fuso_valido "$z"; then R_FUSO="$z"; fi
  fi
  [ -n "$R_PSSH" ] || R_PSSH="$P_SSH_PAD"
  [ -n "$R_PHTTPS" ] || R_PHTTPS="$P_HTTPS_PAD"
  [ -n "$R_PHTTP" ] || R_PHTTP="$P_HTTP_PAD"
  [ -n "$R_PWINBOX" ] || R_PWINBOX="$P_WINBOX_PAD"
}

respostas_texto() {
  local e
  printf '# netbackup-instalador %s: respostas da instalação (sem segredos).\n' "$VERSAO"
  printf '# A senha do administrador NÃO fica aqui: o deploy.sh a pede no terminal.\n'
  printf 'DOMINIO=%s\n' "$R_DOMINIO"
  printf 'EMAIL_LETSENCRYPT=%s\n' "$R_EMAIL"
  for e in "${R_PAINEL[@]}"; do printf 'REDES_PAINEL=%s\n' "$e"; done
  for e in "${R_PUBLICAS[@]}"; do printf 'REDES_PUBLICAS=%s\n' "$e"; done
  for e in "${R_PRIVADAS[@]}"; do printf 'REDES_PRIVADAS=%s\n' "$e"; done
  if [ -n "$R_FUSO" ]; then printf 'FUSO=%s\n' "$R_FUSO"; fi
  printf 'PORTA_SSH=%s\nPORTA_HTTPS=%s\nPORTA_HTTP=%s\nPORTA_WINBOX=%s\n' "$R_PSSH" "$R_PHTTPS" "$R_PHTTP" "$R_PWINBOX"
}

respostas_grava() {
  local tmp
  tmp="$(mktemp "$RESPOSTAS_SALVAS.tmp.XXXXXX")" || die "não foi possível criar temporário para $RESPOSTAS_SALVAS."
  respostas_texto >"$tmp" || { rm -f -- "$tmp"; die "não foi possível gravar as respostas."; }
  if ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$RESPOSTAS_SALVAS"; then rm -f -- "$tmp"; die "não foi possível gravar $RESPOSTAS_SALVAS."; fi
  saida "respostas gravadas em $RESPOSTAS_SALVAS (modo 600)."
}

# Carrega um arquivo de respostas depois de conferir a confiança; mostra os erros.
carrega_respostas_arquivo() { # $1 = arquivo ; $2 = "quieto" para não mostrar erros
  local e
  if [ ! -e "$1" ]; then
    RESP_ERROS=("arquivo de respostas não encontrado: $1")
    resp_limpa
  elif ! confia "$1"; then
    RESP_ERROS=("arquivo de respostas não confiável: $MSG_CONFIANCA (ele deve ser do root e sem escrita para grupo/outros; copie-o para /root)")
    resp_limpa
  else
    respostas_le "$1" && return 0
  fi
  if [ "${2:-}" != "quieto" ]; then
    for e in "${RESP_ERROS[@]}"; do erro "respostas: $e"; done
  fi
  return 1
}

# Para --check/--status/etapas posteriores: usa as respostas gravadas, sem imprimir.
carrega_salvas() {
  [ "$R_CARREGADAS" = 1 ] && return 0
  [ -f "$RESPOSTAS_SALVAS" ] || return 1
  carrega_respostas_arquivo "$RESPOSTAS_SALVAS" quieto
}

# ---- perguntas ---------------------------------------------------------------
PEDE_ERRO=""
VALOR=""
pede() { # $1 = texto ; $2 = validador (usa VALOR) ; $3 = padrão
  local t=0 pad=${3:-}
  while [ "$t" -lt 3 ]; do
    t=$((t + 1))
    if [ -n "$pad" ]; then pergunta "$1 [$pad]:" || die "entrada encerrada. Nada foi alterado."
    else pergunta "$1:" || die "entrada encerrada. Nada foi alterado."; fi
    VALOR="$RESP"
    [ -n "$VALOR" ] || VALOR="$pad"
    if "$2"; then return 0; fi
    aviso_msg "$PEDE_ERRO"
  done
  die "valor inválido após 3 tentativas. Nada foi alterado."
}
val_dominio() {
  VALOR="${VALOR,,}"
  dominio_valido "$VALOR" && return 0
  PEDE_ERRO="nome inválido: use minúsculas, ao menos um ponto, sem http://, porta, IP nem curinga (ex.: netbackup.example.com)"; return 1
}
val_email() { email_valido "$VALOR" && return 0; PEDE_ERRO="e-mail inválido"; return 1; }
val_fuso() { fuso_valido "$VALOR" && return 0; PEDE_ERRO="fuso inválido: informe um nome IANA existente (ex.: America/Sao_Paulo)"; return 1; }
val_porta() { porta_valida "$VALOR" && return 0; PEDE_ERRO="porta inválida (1 a 65535)"; return 1; }

pede_redes() { # $1 = tipo ; $2 = array alvo ; $3 = texto ; $4 = 1 se exige ao menos uma ; $5 = sugestão
  local -n alvo=$2
  local t linha prompt primeira=1 sug=${5:-}
  while :; do
    if [ "$primeira" = 1 ]; then
      prompt="$3"
      if [ -n "$sug" ]; then prompt="$prompt [Enter = $sug]"; fi
    else
      prompt="Outra rede? (Enter para terminar)"
    fi
    t=0
    while :; do
      pergunta "$prompt:" || die "entrada encerrada. Nada foi alterado."
      linha="$RESP"
      if [ -z "$linha" ]; then
        if [ "$primeira" = 1 ] && [ -n "$sug" ]; then linha="$sug"
        elif [ "$primeira" = 1 ] && [ "$4" = 1 ]; then
          aviso_msg "ao menos uma rede é obrigatória."
          t=$((t + 1)); [ "$t" -lt 3 ] || die "nenhuma rede informada. Nada foi alterado."
          continue
        else
          return 0
        fi
      fi
      if entrada_rede "$1" "$linha"; then
        if ! resp_ja_tem "$2" "$ENTRADA_OK"; then alvo+=("$ENTRADA_OK"); fi
        primeira=0
        break
      fi
      aviso_msg "$ENTRADA_ERRO"
      t=$((t + 1)); [ "$t" -lt 3 ] || die "rede inválida após 3 tentativas. Nada foi alterado."
    done
  done
}

# IP de quem está no SSH (utmp via who -m; o sudo -i apaga o SSH_CLIENT). Sem descobrir, sem sugestão.
ip_ssh_origem() {
  local ip
  ip="$("$CMD_WHO" -m 2>/dev/null | head -n 1 | sed -n 's/.*(\([^)]*\)).*/\1/p')"
  if [ -z "$ip" ] && [ -n "${SSH_CLIENT:-}" ]; then ip="${SSH_CLIENT%% *}"; fi
  if [ -n "$ip" ] && ipv4_int "$ip" >/dev/null 2>&1; then printf '%s' "$ip"; fi
  return 0
}

resumo_respostas() {
  local e
  saida "Resumo das respostas:"
  saida "  Endereço do painel ....: https://$R_DOMINIO:$HTTPS_PORT"
  saida "  E-mail (Let's Encrypt) : $R_EMAIL"
  saida "  Redes do painel (acessam o painel pela porta $HTTPS_PORT):"
  for e in "${R_PAINEL[@]}"; do saida "      $e"; done
  saida "  Redes públicas confiáveis (SSH de gestão):"
  if [ "${#R_PUBLICAS[@]}" -eq 0 ]; then saida "      (nenhuma)"; fi
  for e in "${R_PUBLICAS[@]}"; do saida "      $e"; done
  saida "  Redes privadas confiáveis (todas as portas):"
  if [ "${#R_PRIVADAS[@]}" -eq 0 ]; then saida "      (nenhuma)"; fi
  for e in "${R_PRIVADAS[@]}"; do saida "      $e"; done
  saida "  Fuso horário ..........: ${R_FUSO:-(padrão do produto)}"
  saida "  Portas sugeridas no cadastro: SSH $R_PSSH, HTTPS $R_PHTTPS, HTTP $R_PHTTP, WinBox $R_PWINBOX"
  saida "  Senha do administrador : será pedida pelo deploy.sh, digitada no terminal (nunca gravada)."
}

perguntas_interativas() {
  local sug="" ip z
  saida "Responda às perguntas; nada é alterado antes da confirmação final."
  resp_limpa
  pede "Nome do painel (ex.: netbackup.example.com)" val_dominio ""
  R_DOMINIO="$VALOR"
  pede "E-mail para avisos do Let's Encrypt" val_email ""
  R_EMAIL="$VALOR"
  ip="$(ip_ssh_origem)"
  if [ -n "$ip" ]; then sug="$ip/32  administração (origem do SSH)"; fi
  saida "Redes do painel: quem pode abrir https://$R_DOMINIO:$HTTPS_PORT (formato: CIDR e descrição; ex.: 203.0.113.10/32 Administração)."
  pede_redes painel R_PAINEL "Rede do painel" 1 "$sug"
  pede_redes publica R_PUBLICAS "Rede PÚBLICA confiável para o SSH de gestão (opcional; Enter para pular)" 0 ""
  pede_redes privada R_PRIVADAS "Rede PRIVADA confiável (opcional; ex.: 192.168.0.0/16; Enter para pular)" 0 ""
  z="$(fuso_servidor)"
  if [ -n "$z" ] && ! fuso_valido "$z"; then z=""; fi
  pede "Fuso horário (nome IANA)" val_fuso "$z"
  R_FUSO="$VALOR"
  pergunta "Usar as portas oficiais no cadastro de equipamentos (SSH 22, HTTPS 443, HTTP 80, WinBox 8291)? [S/n]" || die "entrada encerrada. Nada foi alterado."
  case "${RESP,,}" in
    n|nao|não)
      pede "Porta SSH" val_porta "$P_SSH_PAD"; R_PSSH="$VALOR"
      pede "Porta HTTPS" val_porta "$P_HTTPS_PAD"; R_PHTTPS="$VALOR"
      pede "Porta HTTP" val_porta "$P_HTTP_PAD"; R_PHTTP="$VALOR"
      pede "Porta WinBox" val_porta "$P_WINBOX_PAD"; R_PWINBOX="$VALOR" ;;
  esac
  resp_defaults
  R_CARREGADAS=1
}

check_perguntas() {
  if [ ! -f "$RESPOSTAS_SALVAS" ]; then item falta "respostas ainda não gravadas ($RESPOSTAS_SALVAS)"; return 0; fi
  if carrega_salvas; then item ok "respostas gravadas e válidas ($RESPOSTAS_SALVAS; painel $R_DOMINIO)"
  else item falta "respostas gravadas inválidas: ${RESP_ERROS[0]:-?}"; fi
}

etapa_perguntas_run() {
  local sozinho=0
  saida "== 2. Perguntas =="
  resp_limpa
  deploy_estado
  case "$DEPLOY_ESTADO" in feito|detectado) sozinho=1 ;; esac
  if [ -n "$RESPOSTAS_ARQ" ]; then
    carrega_respostas_arquivo "$RESPOSTAS_ARQ" || die "o arquivo de respostas é inválido; corrija e rode de novo. Nada foi alterado."
    saida "respostas lidas de $RESPOSTAS_ARQ (sem perguntas; sem confirmação interativa)."
    resumo_respostas
    if [ "$(realpath -m -- "$RESPOSTAS_ARQ")" != "$(realpath -m -- "$RESPOSTAS_SALVAS")" ]; then respostas_grava; fi
    return 0
  fi
  if [ -f "$RESPOSTAS_SALVAS" ]; then
    if carrega_respostas_arquivo "$RESPOSTAS_SALVAS"; then
      if [ "$sozinho" = 1 ]; then
        saida "ok: deploy já feito; usando as respostas gravadas em $RESPOSTAS_SALVAS."
        resumo_respostas
        return 0
      fi
      resumo_respostas
      pergunta "Usar as respostas gravadas em $RESPOSTAS_SALVAS? [S/n]" || die "entrada encerrada. Nada foi alterado."
      case "${RESP,,}" in
        n|nao|não) resp_limpa ;;
        *) return 0 ;;
      esac
    else
      aviso_msg "as respostas gravadas estão inválidas; elas serão perguntadas de novo."
    fi
  fi
  if [ "$sozinho" = 1 ]; then
    die "o deploy já foi feito, mas não há respostas gravadas válidas em $RESPOSTAS_SALVAS; sem elas o HTTPS e o firewall não podem ser concluídos. Restaure o arquivo (ou use --respostas ARQUIVO)."
  fi
  perguntas_interativas
  resumo_respostas
  pergunta "Confirma estas respostas e inicia a instalação? [s/N]" || die "entrada encerrada. Nada foi alterado."
  case "${RESP,,}" in
    s|sim) ;;
    *) die "instalação cancelada na confirmação. Nada foi alterado." ;;
  esac
  respostas_grava
}

# =============================================================================
# ETAPA 1 - PRÉ-CHECAGEM (não altera nada)
# =============================================================================
espaco_livre_mb() {
  local d="$OPT_DIR"
  [ -d "$d" ] || d="$(dirname -- "$OPT_DIR")"
  "$CMD_DF" -Pm "$d" 2>/dev/null | awk 'NR==2 {print $4}'
}

pre_so() {
  local id ver arq
  id="$(sed -n 's/^ID=//p' "$OS_RELEASE" 2>/dev/null | head -1 | tr -d '"')"
  ver="$(sed -n 's/^VERSION_ID=//p' "$OS_RELEASE" 2>/dev/null | head -1 | tr -d '"')"
  arq="$("$CMD_DPKG" --print-architecture 2>/dev/null)"
  if [ "$id" = "ubuntu" ] && [ "$ver" = "24.04" ]; then
    item ok "sistema: Ubuntu 24.04"
  elif [ "$id" = "ubuntu" ] && [ "$ver" = "22.04" ]; then
    AVISO_2204=1
    item aviso "sistema: Ubuntu 22.04 (suportado é 24.04; será pedida confirmação)"
  else
    item falta "sistema: '${id:-?} ${ver:-?}' não suportado (necessário Ubuntu 24.04)"
  fi
  if [ "$arq" = "amd64" ]; then
    item ok "arquitetura: amd64"
  else
    item falta "arquitetura: '${arq:-?}' (necessário amd64)"
  fi
}

pre_ufw() {
  if "$CMD_UFW" status 2>/dev/null | grep -qi '^Status: active'; then
    item ok "UFW ativo"
  else
    item falta "UFW não está ativo (aplique antes o server-baseline)"
  fi
}

pre_relogio() {
  local v
  v="$("$CMD_TIMEDATECTL" show -p NTPSynchronized --value 2>/dev/null)"
  if [ "$v" = "yes" ]; then
    item ok "relógio sincronizado (NTP)"
  else
    item falta "relógio não sincronizado (timedatectl: NTPSynchronized=${v:-?})"
  fi
}

pre_memoria() {
  local kb mb
  kb="$(awk '/^MemTotal:/ {print $2}' "$MEMINFO" 2>/dev/null)"
  if [ -z "$kb" ]; then item falta "memória: não foi possível ler $MEMINFO"; return; fi
  mb=$((kb / 1024))
  if [ "$mb" -lt "$MEM_MIN_MB" ]; then
    item falta "memória: ${mb} MB (mínimo ~2 GB)"
  elif [ "$mb" -lt "$MEM_WARN_MB" ]; then
    item aviso "memória: ${mb} MB (recomendado ~4 GB ou mais)"
  else
    item ok "memória: ${mb} MB"
  fi
}

pre_espaco() {
  local livre cand
  livre="$(espaco_livre_mb)"
  if [ -z "$livre" ]; then item falta "espaço livre: não foi possível medir"; return; fi
  if [ "$livre" -ge "$DISK_MIN_MB" ]; then
    item ok "espaço livre em $OPT_DIR: ${livre} MB"
    return
  fi
  cand="$(lista_candidatos | wc -l)"
  if [ "$cand" -gt 0 ] && ! disco_pronto; then
    item aviso "espaço livre em $OPT_DIR: ${livre} MB (< ${DISK_MIN_MB} MB; há disco de dados candidato, conferido de novo antes do código)"
  else
    item falta "espaço livre em $OPT_DIR: ${livre} MB (mínimo ${DISK_MIN_MB} MB)"
  fi
}

pre_rede() {
  [ "$CHECK_REMOTE" = 1 ] || return 0
  # shellcheck disable=SC2016  # $1/$2 expandem no bash filho, de propósito
  if "$CMD_TIMEOUT" 10 "$CMD_BASH" -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$GH_HOST" "$GH_PORT" 2>/dev/null; then
    item ok "saída para $GH_HOST:$GH_PORT"
  else
    item falta "sem saída para $GH_HOST:$GH_PORT (firewall/proxy/DNS)"
  fi
}

# Programas usados: "variável-do-comando|pacote do Ubuntu|grupo" (grupo "lvm" só
# é exigido se houver disco candidato e o disco de dados ainda não estiver pronto;
# "opcional" só avisa: sem o dig o DNS não é conferido e o HTTPS fica provisório).
# nginx e certbot não estão aqui: o deploy.sh do produto é quem os instala.
PROGRAMAS=(
  "CMD_GIT|git|base" "CMD_SSH|openssh-client|base" "CMD_SSH_KEYSCAN|openssh-client|base"
  "CMD_SSH_KEYGEN|openssh-client|base" "CMD_LSBLK|util-linux|base" "CMD_WIPEFS|util-linux|base"
  "CMD_BLKID|util-linux|base" "CMD_FINDMNT|util-linux|base" "CMD_MOUNT|util-linux|base"
  "CMD_TIMEOUT|coreutils|base" "realpath|coreutils|base" "CMD_STAT|coreutils|base"
  "CMD_SHA256|coreutils|base" "mktemp|coreutils|base"
  "awk|mawk ou gawk|base" "sed|sed|base" "CMD_OPENSSL|openssl|base" "CMD_IP|iproute2|base"
  "CMD_CURL|curl|base" "CMD_DIG|bind9-dnsutils|opcional"
  "CMD_PVS|lvm2|lvm" "CMD_LVS|lvm2|lvm" "CMD_PVCREATE|lvm2|lvm"
  "CMD_VGCREATE|lvm2|lvm" "CMD_LVCREATE|lvm2|lvm" "CMD_MKFS|e2fsprogs|lvm"
)

pre_programas() {
  local entrada var pacote grupo cmd faltando=0 precisa_lvm=0
  # lsblk/wipefs podem faltar: então não há como listar candidatos (já será "falta")
  if [ -n "$(lista_candidatos)" ] && ! disco_pronto; then precisa_lvm=1; fi
  for entrada in "${PROGRAMAS[@]}"; do
    IFS='|' read -r var pacote grupo <<<"$entrada"
    if [ "$grupo" = "lvm" ] && [ "$precisa_lvm" -eq 0 ]; then continue; fi
    case "$var" in CMD_*) cmd="${!var}" ;; *) cmd="$var" ;; esac
    if ! command -v -- "$cmd" >/dev/null 2>&1; then
      if [ "$grupo" = "opcional" ]; then
        item aviso "programa '$cmd' ausente (instale o pacote: $pacote); sem ele o DNS não é conferido"
      else
        item falta "programa '$cmd' ausente (instale o pacote: $pacote)"
        faltando=1
      fi
    fi
  done
  if [ "$faltando" -eq 0 ]; then item ok "programas necessários presentes"; fi
}

check_precheck() {
  pre_programas; pre_so; pre_ufw; pre_relogio; pre_memoria; pre_espaco; pre_rede
}

etapa_precheck_run() {
  saida "== 1. Pré-checagem =="
  zera_itens; AVISO_2204=0
  check_precheck
  if [ "$N_FALTA" -gt 0 ]; then
    die "pré-checagem falhou em $N_FALTA item(ns); corrija e rode de novo (nada foi alterado)."
  fi
  if [ "$AVISO_2204" = 1 ]; then
    pergunta "Ubuntu 22.04 não é o alvo oficial. Continuar mesmo assim? (digite sim)" || die "entrada encerrada."
    [ "$RESP" = "sim" ] || die "instalação cancelada (Ubuntu 22.04 não confirmado)."
  fi
}

# =============================================================================
# ETAPA 2 - DISCO DE DADOS EM /opt (OPCIONAL)
# =============================================================================
mapper_name() { printf '%s-%s' "${VG_NAME//-/--}" "${LV_NAME//-/--}"; }

opt_fonte() { "$CMD_FINDMNT" -n -o SOURCE "$OPT_DIR" 2>/dev/null | head -1; }

fonte_e_dados() { # $1 = fonte do findmnt
  case "$1" in
    "/dev/mapper/$(mapper_name)"|"$LV_DEV"|"/dev/$VG_NAME/$LV_NAME") return 0 ;;
  esac
  return 1
}

disco_pronto() { local f; f="$(opt_fonte)"; [ -n "$f" ] && fonte_e_dados "$f"; }

opt_vazio() {
  [ ! -d "$OPT_DIR" ] && return 0
  [ -z "$(find "$OPT_DIR" -mindepth 1 -maxdepth 1 ! -name 'lost+found' -print -quit 2>/dev/null)" ]
}

lv_existe() { "$CMD_LVS" "$VG_NAME/$LV_NAME" >/dev/null 2>&1; }

# Imprime o motivo e retorna 0 se o disco deve ser RECUSADO; 1 se é candidato.
disco_recusa_motivo() { # $1 = /dev/xxx
  local dev="$1" n=0 mp wf tam tam_mb
  while read -r _ _ mp; do
    n=$((n + 1))
    if [ "$n" -eq 1 ] && [ -n "${mp:-}" ]; then echo "montado em $mp"; return 0; fi
  done < <("$CMD_LSBLK" -nr -o NAME,TYPE,MOUNTPOINT "$dev" 2>/dev/null)
  if [ "$n" -eq 0 ]; then echo "não foi possível ler o disco"; return 0; fi
  if [ "$n" -gt 1 ]; then echo "tem partições/volumes"; return 0; fi
  wf="$("$CMD_WIPEFS" -n "$dev" 2>&1)" || { echo "wipefs falhou"; return 0; }
  if [ -n "$wf" ]; then echo "tem assinatura de sistema de arquivos/RAID/LVM"; return 0; fi
  if "$CMD_PVS" --noheadings -o pv_name 2>/dev/null | tr -d ' ' | grep -qxF "$dev"; then
    echo "já faz parte de um LVM"; return 0
  fi
  tam="$("$CMD_LSBLK" -dnbo SIZE "$dev" 2>/dev/null | head -1)"
  tam_mb=$(( ${tam:-0} / 1048576 ))
  if [ "$tam_mb" -le 0 ]; then echo "não foi possível ler o tamanho"; return 0; fi
  # estimativa conservadora do espaço útil: 90% (reservado de 5% do ext4 + metadados)
  if [ $(( tam_mb * 90 / 100 )) -lt "$DISK_MIN_MB" ]; then
    echo "pequeno demais: $(( tam_mb / 1024 )) GiB; mínimo ~$(disco_min_gib) GiB"; return 0
  fi
  return 1
}

disco_min_gib() { echo $(( (DISK_MIN_MB * 100 + 92160 - 1) / 92160 )); }

# Discos que só foram recusados pelo tamanho: imprime "dispositivo|motivo"
lista_recusados_tamanho() {
  local dev tipo motivo
  while read -r dev tipo; do
    [ "$tipo" = "disk" ] || continue
    motivo="$(disco_recusa_motivo "$dev")" || true
    case "$motivo" in "pequeno demais"*) printf '%s|%s\n' "$dev" "$motivo" ;; esac
  done < <("$CMD_LSBLK" -dnpo NAME,TYPE 2>/dev/null)
}

lista_candidatos() { # imprime "dispositivo|tamanho em GiB"
  local dev tipo tam
  while read -r dev tipo; do
    [ "$tipo" = "disk" ] || continue
    disco_recusa_motivo "$dev" >/dev/null && continue
    tam="$("$CMD_LSBLK" -dnbo SIZE "$dev" 2>/dev/null | head -1)"
    printf '%s|%s\n' "$dev" "$(( ${tam:-0} / 1073741824 ))"
  done < <("$CMD_LSBLK" -dnpo NAME,TYPE 2>/dev/null)
}

check_disco() {
  local f ncand dev motivo
  f="$(opt_fonte)"
  if [ -n "$f" ] && fonte_e_dados "$f"; then
    item ok "$OPT_DIR montado de $VG_NAME/$LV_NAME ($f)"
    if grep -Eq "^[^#]*[[:space:]]${OPT_DIR}[[:space:]]+ext4[[:space:]]" "$FSTAB" 2>/dev/null; then
      item ok "linha de $OPT_DIR no fstab"
    else
      item falta "linha de $OPT_DIR ausente no fstab"
    fi
  elif [ -n "$f" ]; then
    item aviso "$OPT_DIR já é um ponto de montagem de outro volume ($f); disco de dados não será configurado"
  elif lv_existe; then
    item falta "volume $VG_NAME/$LV_NAME existe mas $OPT_DIR não está montado (a execução conclui)"
  else
    ncand="$(lista_candidatos | wc -l)"
    item aviso "$OPT_DIR no disco do sistema (disco de dados é opcional; candidatos: $ncand)"
    while IFS='|' read -r dev motivo; do
      [ -n "$dev" ] && item aviso "disco $dev recusado: $motivo"
    done < <(lista_recusados_tamanho)
  fi
}

disco_executa() { # $1 = /dev/xxx (já confirmado)
  local dev="$1" uuid i
  DATA_STAMP="$(date +%Y%m%d_%H%M%S)"
  if ! lv_existe; then
    saida "-> criando volume físico, grupo e volume lógico em $dev"
    executa "$CMD_PVCREATE" "$dev" || die "pvcreate falhou."
    executa "$CMD_VGCREATE" "$VG_NAME" "$dev" || die "vgcreate falhou."
    executa "$CMD_LVCREATE" -n "$LV_NAME" -l 100%FREE "$VG_NAME" || die "lvcreate falhou."
  fi
  if "$CMD_BLKID" -s TYPE -o value "$LV_DEV" 2>/dev/null | grep -q .; then
    saida "-> $LV_DEV já tem sistema de arquivos; não será formatado"
  else
    executa "$CMD_MKFS" -L "$FS_LABEL" "$LV_DEV" || die "mkfs.ext4 falhou."
  fi
  uuid=""
  for i in 1 2 3 4 5; do
    uuid="$("$CMD_BLKID" -s UUID -o value "$LV_DEV" 2>/dev/null)"
    [ -n "$uuid" ] && break
    sleep 1
  done
  [ -n "$uuid" ] || die "não foi possível obter o UUID de $LV_DEV."
  fstab_ajusta "$uuid"
  mkdir -p -- "$OPT_DIR"
  executa "$CMD_SYSTEMCTL" daemon-reload || aviso_msg "systemctl daemon-reload falhou (seguindo)."
  executa "$CMD_MOUNT" -a || die "mount -a falhou (fstab foi preservado em cópia)."
  disco_pronto || die "conferência final: $OPT_DIR não está montado de $VG_NAME/$LV_NAME (findmnt: $(opt_fonte))."
  saida "-> $OPT_DIR montado de $VG_NAME/$LV_NAME, UUID $uuid"
}

fstab_ajusta() { # $1 = UUID
  local uuid="$1" linha
  linha="UUID=$uuid $OPT_DIR ext4 defaults,nodev,nosuid,nofail 0 2"
  if grep -qF "UUID=$uuid " "$FSTAB" 2>/dev/null; then
    saida "-> fstab já tem a linha deste UUID"
    return 0
  fi
  if grep -Eq "^[^#]*[[:space:]]${OPT_DIR}[[:space:]]" "$FSTAB" 2>/dev/null; then
    die "o fstab já tem outra linha para $OPT_DIR; ajuste manualmente e rode de novo."
  fi
  cp -p -- "$FSTAB" "$FSTAB.bak-$DATA_STAMP" || die "não foi possível copiar o fstab."
  saida "-> cópia do fstab: $FSTAB.bak-$DATA_STAMP"
  if [ -s "$FSTAB" ] && [ -n "$(tail -c1 "$FSTAB")" ]; then printf '\n' >>"$FSTAB"; fi
  printf '%s\n' "$linha" >>"$FSTAB" || die "não foi possível gravar o fstab."
  saida "-> fstab: $linha"
}

etapa_disco_run() {
  local f cands=() linha i escolha dev tam motivo
  saida "== 3. Disco de dados em $OPT_DIR (opcional) =="
  f="$(opt_fonte)"
  if [ -n "$f" ] && fonte_e_dados "$f"; then
    saida "ok: $OPT_DIR já montado de $VG_NAME/$LV_NAME; segue."
    return 0
  fi
  if [ -n "$f" ]; then
    aviso_msg "$OPT_DIR já é ponto de montagem de outro volume ($f); disco de dados não será configurado."
    return 0
  fi
  if lv_existe; then
    saida "volume $VG_NAME/$LV_NAME já existe (execução anterior interrompida); concluindo fstab e montagem."
    opt_vazio || { aviso_msg "$OPT_DIR não está vazio; não é seguro montar o volume por cima. Nada foi alterado nesta etapa."; return 0; }
    disco_executa ""
    return 0
  fi
  if ! opt_vazio; then
    aviso_msg "$OPT_DIR não está vazio; disco de dados RECUSADO (nada foi alterado). $OPT_DIR continua no disco do sistema."
    return 0
  fi
  while IFS='|' read -r dev motivo; do
    [ -n "$dev" ] && aviso_msg "disco $dev recusado: $motivo."
  done < <(lista_recusados_tamanho)
  while IFS= read -r linha; do cands+=("$linha"); done < <(lista_candidatos)
  if [ "${#cands[@]}" -eq 0 ]; then
    aviso_msg "nenhum disco candidato (sem partição, sem assinatura, não montado, fora de LVM). $OPT_DIR ficará no disco do sistema."
    return 0
  fi
  saida "Discos candidatos (vazios, sem partição/assinatura, não montados, fora de LVM):"
  i=0
  for linha in "${cands[@]}"; do
    i=$((i + 1))
    saida "  $i) ${linha%%|*}  (${linha##*|} GiB)"
  done
  pergunta "Escolha o número do disco para $OPT_DIR ou digite 'nenhum':" || die "entrada encerrada."
  escolha="$RESP"
  if [ "$escolha" = "nenhum" ]; then
    aviso_msg "nenhum disco escolhido: $OPT_DIR ficará no disco do sistema (backups e banco dividem o espaço com o sistema)."
    return 0
  fi
  case "$escolha" in
    ''|*[!0-9]*) die "escolha inválida: '$escolha'. Nada foi alterado." ;;
  esac
  if [ "$escolha" -lt 1 ] || [ "$escolha" -gt "${#cands[@]}" ]; then
    die "escolha fora da lista: '$escolha'. Nada foi alterado."
  fi
  linha="${cands[$((escolha - 1))]}"
  dev="${linha%%|*}"; tam="${linha##*|}"
  saida "ATENÇÃO: $dev (${tam} GiB) será transformado em LVM ($VG_NAME/$LV_NAME), formatado em ext4 e montado em $OPT_DIR."
  pergunta "Para confirmar, digite o nome do dispositivo ($dev):" || die "entrada encerrada."
  [ "$RESP" = "$dev" ] || die "confirmação não confere ('$RESP' != '$dev'). Nada foi alterado."
  if motivo="$(disco_recusa_motivo "$dev")"; then
    die "$dev recusado: $motivo. Nada foi alterado."
  fi
  opt_vazio || die "$OPT_DIR deixou de estar vazio. Nada foi alterado."
  disco_executa "$dev"
}

# =============================================================================
# ETAPA 3 - CHAVE DE DEPLOY DO GITHUB (SOMENTE LEITURA)
# =============================================================================
fp_do_arquivo() { # $1 = arquivo com chave pública -> impressão digital
  "$CMD_SSH_KEYGEN" -lf "$1" 2>/dev/null | awk 'NR==1 {print $2}'
}

known_hosts_ok() { [ -s "$KNOWN_HOSTS" ] && [ "$(fp_do_arquivo "$KNOWN_HOSTS")" = "$GITHUB_FP" ]; }
config_tem_bloco() { grep -Eq "^[[:space:]]*Host[[:space:]]+${SSH_ALIAS}([[:space:]]|\$)" "$SSH_CONFIG" 2>/dev/null; }

git_ssh_cmd() { printf '%s -F %s -o BatchMode=yes -o ConnectTimeout=15' "$CMD_SSH" "$SSH_CONFIG"; }

chave_leitura() { # 0 = consegue ler o repositório
  local out rc
  out="$(GIT_SSH_COMMAND="$(git_ssh_cmd)" git_ "ls-remote" "$REPO" HEAD 2>&1 </dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  registra "ls-remote falhou: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  return 1
}

# Descobre onde a chave está cadastrada (ssh -T) e explica por que a leitura falhou.
DIAG_MSG=""
chave_diagnostico() {
  local out slug alvo
  slug="$(repo_slug "$REPO")"
  out="$("$CMD_TIMEOUT" 30 "$CMD_SSH" -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=15 \
        -T "$SSH_ALIAS" 2>&1 </dev/null | tr -d '\000')"
  registra "ssh -T: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  alvo="$(printf '%s\n' "$out" | sed -n 's/^Hi \([^!]*\)!.*/\1/p' | head -1)"
  if [ -n "$alvo" ]; then
    case "$alvo" in
      */*)
        if [ "${alvo,,}" = "${slug,,}" ]; then
          DIAG_MSG="a chave está cadastrada no repositório certo ($alvo), mas a leitura falhou; confira se o repositório e o branch '$BRANCH' existem (veja o log)"
        else
          DIAG_MSG="a chave está cadastrada em $alvo; cadastre-a em $slug e APAGUE-A de $alvo (Settings -> Deploy keys)"
        fi ;;
      *) DIAG_MSG="a chave está cadastrada na conta '$alvo' (chave de usuário), não como Deploy key; apague-a de lá e cadastre-a como Deploy key em $slug" ;;
    esac
  elif printf '%s' "$out" | grep -qi 'Permission denied'; then
    DIAG_MSG="a chave ainda não está cadastrada em nenhum repositório (cadastre em $slug)"
  else
    DIAG_MSG="não foi possível identificar onde a chave está cadastrada (resposta registrada no log)"
  fi
}

# 0 = escrita recusada (somente leitura) ; 1 = escrita ACEITA ; 2 = inconclusivo
chave_escrita() {
  local out
  out="$("$CMD_TIMEOUT" 60 "$CMD_SSH" -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=15 \
        "$SSH_ALIAS" git-receive-pack "'$(repo_slug "$REPO").git'" 2>&1 </dev/null | tr -d '\000')"
  if printf '%s' "$out" | grep -qiE 'read[ -]?only'; then return 0; fi
  if printf '%s' "$out" | grep -qE 'refs/|report-status|capabilities'; then return 1; fi
  registra "receive-pack inconclusivo: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  return 2
}

check_chave() {
  local perm rc
  if known_hosts_ok; then item ok "chave do GitHub fixada e conferida ($KNOWN_HOSTS)"
  else item falta "chave do GitHub não fixada/conferida ($KNOWN_HOSTS)"; fi
  if [ -f "$KEY_FILE" ]; then
    perm="$(stat -c '%a' -- "$KEY_FILE" 2>/dev/null)"
    if [ "$perm" = "600" ]; then item ok "chave privada de deploy existe (modo 600)"
    else item falta "chave privada com modo $perm (esperado 600)"; fi
  else item falta "chave privada de deploy ausente ($KEY_FILE)"; fi
  if [ -f "$KEY_FILE.pub" ]; then item ok "chave pública presente"; else item falta "chave pública ausente"; fi
  if config_tem_bloco; then item ok "bloco 'Host $SSH_ALIAS' em $SSH_CONFIG"
  else item falta "bloco 'Host $SSH_ALIAS' ausente em $SSH_CONFIG"; fi
  [ "$CHECK_REMOTE" = 1 ] || return 0
  if known_hosts_ok && [ -f "$KEY_FILE" ] && config_tem_bloco; then
    if chave_leitura; then
      item ok "leitura do repositório com a chave de deploy"
      chave_escrita; rc=$?
      case "$rc" in
        0) item ok "escrita recusada pelo GitHub (somente leitura)" ;;
        1) item falta "a chave ACEITA ESCRITA: apague-a no GitHub e recadastre sem 'Allow write access'" ;;
        *) item falta "não foi possível confirmar que a chave é somente leitura" ;;
      esac
    else
      chave_diagnostico
      item falta "a chave de deploy não lê o repositório: $DIAG_MSG"
    fi
  fi
}

chave_prepara_local() {
  local tmp linha fp
  DATA_STAMP="$(date +%Y%m%d_%H%M%S)"
  mkdir -p -- "$SSH_DIR" || die "não foi possível criar $SSH_DIR."
  chmod 700 -- "$SSH_DIR" || die "não foi possível proteger $SSH_DIR."

  # 1) chave do GitHub fixada, conferida com a impressão digital oficial
  if [ -s "$KNOWN_HOSTS" ]; then
    known_hosts_ok || die "$KNOWN_HOSTS existe mas a impressão digital difere da oficial do GitHub. PARE: investigue (possível adulteração). Nada foi alterado."
    saida "ok: chave do GitHub já fixada e conferida."
  else
    tmp="$(mktemp -d)" || die "mktemp falhou."
    linha="$("$CMD_TIMEOUT" 30 "$CMD_SSH_KEYSCAN" -t ed25519 -T 10 "$GH_HOST" 2>/dev/null | awk -v h="$GH_HOST" '$1==h && $2=="ssh-ed25519" {print; exit}')"
    if [ -z "$linha" ]; then rm -rf -- "$tmp"; die "ssh-keyscan não retornou a chave ed25519 de $GH_HOST."; fi
    printf '%s\n' "$linha" >"$tmp/kh"
    fp="$(fp_do_arquivo "$tmp/kh")"
    rm -rf -- "$tmp"
    if [ "$fp" != "$GITHUB_FP" ]; then
      die "impressão digital da chave de $GH_HOST DIFERE da oficial (recebida: ${fp:-vazia}; oficial: $GITHUB_FP). PARE: possível interceptação. Nada foi gravado."
    fi
    ( umask 077; printf '%s\n' "$linha" >"$KNOWN_HOSTS" ) || die "não foi possível gravar $KNOWN_HOSTS."
    chmod 600 -- "$KNOWN_HOSTS"
    saida "ok: chave do GitHub conferida ($fp) e gravada em $KNOWN_HOSTS."
  fi

  # 2) par de chaves de deploy (só se não existir)
  if [ -f "$KEY_FILE" ]; then
    saida "ok: chave de deploy já existe ($KEY_FILE)."
    if [ ! -f "$KEY_FILE.pub" ]; then
      ( umask 022; "$CMD_SSH_KEYGEN" -y -f "$KEY_FILE" >"$KEY_FILE.pub" ) || die "não foi possível recriar a chave pública."
    fi
  else
    "$CMD_SSH_KEYGEN" -q -t ed25519 -N '' -f "$KEY_FILE" -C "$("$CMD_HOSTNAME") somente leitura" >/dev/null 2>&1 \
      || die "ssh-keygen falhou."
    saida "ok: chave de deploy gerada ($KEY_FILE)."
  fi
  chmod 600 -- "$KEY_FILE"

  # 3) bloco no ssh config
  if config_tem_bloco; then
    saida "ok: bloco 'Host $SSH_ALIAS' já existe em $SSH_CONFIG."
  else
    if [ -f "$SSH_CONFIG" ]; then
      cp -p -- "$SSH_CONFIG" "$SSH_CONFIG.bak-$DATA_STAMP" || die "não foi possível copiar $SSH_CONFIG."
      saida "cópia do ssh config: $SSH_CONFIG.bak-$DATA_STAMP"
    fi
    # O ssh vale o PRIMEIRO valor de cada opção: o bloco vai no COMEÇO do arquivo
    # (antes de qualquer Host/Match). "Match all" encerra o bloco, para que linhas
    # globais que já estavam no começo do arquivo continuem valendo para todos.
    tmp="$(mktemp "$SSH_CONFIG.tmp.XXXXXX")" || die "não foi possível criar temporário em $SSH_DIR."
    {
      printf '# NetBackup Manager: chave de deploy somente leitura (instalar.sh)\n'
      printf 'Host %s\n' "$SSH_ALIAS"
      printf '    HostName %s\n' "$GH_HOST"
      printf '    User git\n'
      printf '    IdentityFile %s\n' "$KEY_FILE"
      printf '    IdentitiesOnly yes\n'
      printf '    StrictHostKeyChecking yes\n'
      printf '    UserKnownHostsFile %s\n' "$KNOWN_HOSTS"
      printf '    HostKeyAlgorithms ssh-ed25519\n'
      printf 'Match all\n'
      if [ -f "$SSH_CONFIG" ]; then cat -- "$SSH_CONFIG"; fi
    } >"$tmp" || { rm -f -- "$tmp"; die "não foi possível gravar o temporário de $SSH_CONFIG."; }
    chmod 600 -- "$tmp" || { rm -f -- "$tmp"; die "chmod falhou em $tmp."; }
    mv -f -- "$tmp" "$SSH_CONFIG" || { rm -f -- "$tmp"; die "não foi possível substituir $SSH_CONFIG."; }
    saida "ok: bloco 'Host $SSH_ALIAS' inserido no começo de $SSH_CONFIG."
  fi
}

etapa_chave_run() {
  local t rc slug lido
  saida "== 4. Chave de deploy do GitHub (somente leitura) =="
  chave_prepara_local
  slug="$(repo_slug "$REPO")"
  if chave_leitura; then
    saida "ok: a chave já lê o repositório."
  else
    saida ""
    saida "Cadastre esta chave PÚBLICA como Deploy key SOMENTE LEITURA:"
    saida ""
    saida "$(cat -- "$KEY_FILE.pub")"
    saida ""
    saida "No GitHub: repositório $slug -> Settings -> Deploy keys -> Add deploy key."
    saida "Cole a chave acima e deixe DESMARCADO 'Allow write access'."
    t=0; lido=0
    while [ "$t" -lt 3 ] && [ "$lido" -eq 0 ]; do
      t=$((t + 1))
      pergunta "Depois de cadastrar, pressione Enter para testar (tentativa $t/3):" || die "entrada encerrada."
      if chave_leitura; then
        lido=1; saida "ok: leitura do repositório funcionando."
      else
        erro "não foi possível ler o repositório com a chave de deploy."
        chave_diagnostico
        erro "$DIAG_MSG."
      fi
    done
    [ "$lido" -eq 1 ] || die "a chave não conseguiu ler o repositório após 3 tentativas. Confira o cadastro no GitHub e rode de novo."
  fi
  chave_escrita; rc=$?
  case "$rc" in
    0) saida "ok: o GitHub recusa escrita com esta chave (somente leitura)." ;;
    1) die "a chave ACEITA ESCRITA. Apague-a em Settings -> Deploy keys e cadastre de novo SEM 'Allow write access'." ;;
    *) die "não foi possível confirmar que a chave é somente leitura (resposta inesperada do GitHub; veja o log)." ;;
  esac
}

# =============================================================================
# ETAPA 4 - CÓDIGO DO PRODUTO
# =============================================================================
# Define CODIGO_ESTADO: ausente | ok | outro  (e CODIGO_MOTIVO)
CODIGO_ESTADO=""
CODIGO_MOTIVO=""
DEPLOY_RESULT=""
codigo_estado() {
  local remoto
  CODIGO_MOTIVO=""
  if [ ! -e "$NB_DIR" ]; then CODIGO_ESTADO="ausente"; return 0; fi
  CODIGO_ESTADO="outro"
  if [ ! -d "$NB_DIR" ]; then CODIGO_MOTIVO="$NB_DIR existe e não é uma pasta"; return 0; fi
  if [ -z "$(find "$NB_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    # pasta vazia: serve para clonar dentro, se for do root e sem escrita g/o
    if confia "$NB_DIR"; then CODIGO_ESTADO="ausente"
    else CODIGO_MOTIVO="$NB_DIR existe vazia mas não é confiável: $MSG_CONFIANCA"; fi
    return 0
  fi
  if [ ! -e "$NB_DIR/.git" ]; then CODIGO_MOTIVO="$NB_DIR existe e não é um repositório git"; return 0; fi
  if ! confia "$NB_DIR/.git"; then CODIGO_MOTIVO="não confiável: $MSG_CONFIANCA"; return 0; fi
  remoto="$(git_ -C "$NB_DIR" remote get-url origin 2>/dev/null)"
  if [ -z "$remoto" ]; then CODIGO_MOTIVO="$NB_DIR sem remote 'origin'"; return 0; fi
  if [ "$(repo_slug "$remoto")" != "$(repo_slug "$REPO")" ]; then
    CODIGO_MOTIVO="$NB_DIR é de outro repositório ($remoto)"; return 0
  fi
  CODIGO_ESTADO="ok"
}

codigo_commit() {
  git_ -C "$NB_DIR" log -1 --format='%h %ad %s' --date=short 2>/dev/null
}

check_codigo() {
  deploy_estado
  case "$DEPLOY_ESTADO" in
    feito|detectado)
      item ok "código do produto em $NB_DIR (deploy feito: a pasta é do usuário $APP_USER; commit registrado: $(estado_get PRODUTO_COMMIT))"
      return 0 ;;
    recusa) item falta "$DEPLOY_MOTIVO"; return 0 ;;
  esac
  codigo_estado
  case "$CODIGO_ESTADO" in
    ausente) item falta "código do produto ausente ($NB_DIR)" ;;
    ok) item ok "código do produto em $NB_DIR: $(codigo_commit)" ;;
    *) item falta "$CODIGO_MOTIVO" ;;
  esac
}

etapa_codigo_run() {
  local livre
  saida "== 5. Código do produto =="
  deploy_estado
  case "$DEPLOY_ESTADO" in
    feito|detectado)
      saida "ok: deploy já feito; $NB_DIR é do usuário $APP_USER e o instalador não o toca mais (commit registrado: $(estado_get PRODUTO_COMMIT))."
      return 0 ;;
    recusa) die "$DEPLOY_MOTIVO" ;;
  esac
  codigo_estado
  case "$CODIGO_ESTADO" in
    outro) die "$CODIGO_MOTIVO. Nada foi alterado." ;;
    ok) saida "ok: $NB_DIR já é o repositório do produto; segue (sem atualizar nesta fase)." ;;
    ausente)
      livre="$(espaco_livre_mb)"
      if [ -z "$livre" ] || [ "$livre" -lt "$DISK_MIN_MB" ]; then
        die "espaço livre insuficiente em $OPT_DIR (${livre:-?} MB; mínimo $DISK_MIN_MB MB)."
      fi
      mkdir -p -- "$OPT_DIR"
      saida "clonando $REPO (branch $BRANCH) em $NB_DIR"
      ( umask 022; GIT_SSH_COMMAND="$(git_ssh_cmd)" executa "$CMD_GIT" clone --branch "$BRANCH" "$REPO" "$NB_DIR" ) \
        || die "git clone falhou."
      ;;
  esac
  saida "commit: $(codigo_commit)"
}

# =============================================================================
# ETAPA CONFIG - ARQUIVOS DE CONFIGURAÇÃO (ANTES DO deploy.sh, ÁRVORE AINDA DO ROOT)
# =============================================================================
# Só roda se /opt/netbackup ainda é do root e passa em confia. O root NUNCA escreve
# numa pasta que já é do usuário netbackup (risco de link simbólico): tudo o que
# depende do produto é gravado agora ou, depois do deploy, não é gravado.
CFG_DIR=""
CFG_BAK=""
CFG_MANTIDOS=""
CFG_DECISAO=""

escreve_arq() { # $1 = destino ; $2 = modo ; conteúdo em stdin ; temporário na MESMA pasta
  local dest=$1 modo=$2 tmp
  tmp="$(mktemp "$(dirname -- "$dest")/.instalador.XXXXXX")" || return 1
  if ! cat >"$tmp"; then rm -f -- "$tmp"; return 1; fi
  if ! chmod "$modo" -- "$tmp" || ! mv -f -- "$tmp" "$dest"; then rm -f -- "$tmp"; return 1; fi
}

# Valor da primeira linha ATIVA "CHAVE=valor" (sem comentário).
conf_valor() { # $1 = arquivo ; $2 = chave
  sed -n -E "s/^$2=(.*)\$/\1/p" "$1" 2>/dev/null | head -n 1
}

# Define CHAVE=valor: troca a linha ativa; senão a primeira linha comentada "# CHAVE=..."; senão acrescenta.
conf_define() { # $1 = arquivo ; $2 = chave ; $3 = valor
  local f=$1 k=$2 v=$3 i ativa=-1 com=-1 modo
  local -a L
  mapfile -t L <"$f"
  for i in "${!L[@]}"; do
    if [[ ${L[$i]} == "$k="* ]]; then ativa=$i; break; fi
    if [ "$com" -lt 0 ] && [[ ${L[$i]} =~ ^#[[:space:]]*$k= ]]; then com=$i; fi
  done
  if [ "$ativa" -ge 0 ]; then L[ativa]="$k=$v"
  elif [ "$com" -ge 0 ]; then L[com]="$k=$v"
  else L+=("$k=$v"); fi
  modo="$("$CMD_STAT" -c '%a' -- "$f")" || return 1
  printf '%s\n' "${L[@]}" | escreve_arq "$f" "$modo"
}

# Chaves de app_settings.conf que as respostas definem: "CHAVE|valor|padrão do produto"
config_chaves() {
  if [ -n "$R_FUSO" ]; then printf 'TIMEZONE|%s|\n' "$R_FUSO"; fi
  printf 'PANEL_HOSTNAME|%s:%s|\n' "$R_DOMINIO" "$HTTPS_PORT"
  printf 'DEFAULT_PORT_SSH|%s|%s\n' "$R_PSSH" "$P_SSH_PAD"
  printf 'DEFAULT_PORT_HTTPS|%s|%s\n' "$R_PHTTPS" "$P_HTTPS_PAD"
  printf 'DEFAULT_PORT_HTTP|%s|%s\n' "$R_PHTTP" "$P_HTTP_PAD"
  printf 'DEFAULT_PORT_WINBOX|%s|%s\n' "$R_PWINBOX" "$P_WINBOX_PAD"
}

# Diferenças entre um app_settings.conf e as respostas. NUNCA imprime outras linhas
# (o arquivo tem a APP_SECRET_KEY). Imprime "CHAVE|atual|desejado" por diferença.
config_app_difs() { # $1 = arquivo
  local k v pad atual
  while IFS='|' read -r k v pad; do
    atual="$(conf_valor "$1" "$k")"
    atual="$(trim "$atual")"
    if [ -z "$atual" ]; then atual="$pad"; fi
    if [ "$atual" != "$v" ]; then printf '%s|%s|%s\n' "$k" "$atual" "$v"; fi
  done < <(config_chaves)
}

config_aplica_chaves() { # $1 = arquivo ; aplica as respostas (portas iguais ao padrão só se já havia valor ativo)
  local k v pad ativo
  while IFS='|' read -r k v pad; do
    if [ -n "$pad" ] && [ "$v" = "$pad" ]; then
      ativo="$(conf_valor "$1" "$k")"
      [ -n "$ativo" ] || continue
    fi
    conf_define "$1" "$k" "$v" || return 1
  done < <(config_chaves)
}

# Linhas ATIVAS (rede + descrição normalizada com dois espaços) lidas do stdin.
rede_linhas_ativas() {
  local l net desc
  while IFS= read -r l || [ -n "$l" ]; do
    l="$(trim "$l")"
    case "$l" in ''|'#'*) continue ;; esac
    net=${l%%[[:space:]]*}
    desc=""
    if [ "$net" != "$l" ]; then desc="$(trim "${l#"$net"}")"; fi
    if [ -n "$desc" ]; then printf '%s  %s\n' "$net" "$desc"; else printf '%s\n' "$net"; fi
  done
}

# Conteúdo desejado: o modelo inteiro (comentários e linhas ativas dele) + as redes das respostas.
rede_conteudo() { # $1 = modelo ; demais = entradas "CIDR  desc"
  local ex=$1 e net ativas
  local -a L
  shift
  mapfile -t L <"$ex"
  printf '%s\n' "${L[@]}"
  ativas="$(rede_linhas_ativas <"$ex" | awk '{print $1}')"
  for e in "$@"; do
    net=${e%% *}
    if printf '%s\n' "$ativas" | grep -qxF -- "$net"; then continue; fi
    printf '%s\n' "$e"
  done
}

config_backup() { # $1 = arquivo a guardar antes de substituir
  if [ -z "$CFG_BAK" ]; then
    CFG_BAK="$LOG_DIR/netbackup-config-anterior-$(date +%Y%m%d_%H%M%S)"
    ( umask 077; mkdir -p -- "$CFG_BAK" ) || die "não foi possível criar $CFG_BAK."
  fi
  ( umask 077; cp -p -- "$1" "$CFG_BAK/" ) || die "não foi possível guardar a cópia de $1."
}

# Arquivo existente que difere das respostas: mostra e pede decisão (para no --respostas).
config_decide() { # $1 = nome ; $2 = texto da diferença
  saida "O arquivo $1 já existe e difere do que as respostas pedem:"
  saida "$2"
  if [ -n "$RESPOSTAS_ARQ" ]; then
    die "$1 existente difere das respostas e o modo --respostas não decide por você. Nada foi sobrescrito; ajuste o arquivo ou as respostas e rode de novo."
  fi
  pergunta "Digite 'manter' (não altera), 'substituir' (guarda cópia em $LOG_DIR) ou 'parar':" || die "entrada encerrada. Nada foi sobrescrito."
  case "$RESP" in
    manter) CFG_DECISAO="manter" ;;
    substituir) CFG_DECISAO="substituir" ;;
    *) die "interrompido a seu pedido. Nada foi sobrescrito." ;;
  esac
}

config_modelo() { # $1 = nome do .example ; confere e imprime o caminho
  local ex="$CFG_DIR/$1.example"
  [ -f "$ex" ] && [ ! -L "$ex" ] || die "modelo do produto ausente ou é link: $ex."
  confia "$ex" || die "RECUSADO: $ex não é confiável: $MSG_CONFIANCA."
}

config_app() {
  local nome=app_settings.conf real="$CFG_DIR/app_settings.conf" ex="$CFG_DIR/app_settings.conf.example" tmp key difs txt k a d
  config_modelo "$nome"
  [ ! -L "$real" ] || die "$real é um link simbólico; recusado."
  if [ ! -e "$real" ]; then
    key="$("$CMD_OPENSSL" rand -hex 32 2>/dev/null)" || key=""
    [[ $key =~ ^[0-9a-f]{64}$ ]] || die "openssl rand não gerou a chave esperada (64 hexadecimais)."
    tmp="$(mktemp "$CFG_DIR/.instalador.XXXXXX")" || die "não foi possível criar temporário em $CFG_DIR."
    if ! cat -- "$ex" >"$tmp" || ! chmod 600 -- "$tmp"; then rm -f -- "$tmp"; die "não foi possível preparar $nome."; fi
    conf_define "$tmp" APP_SECRET_KEY "$key" || { rm -f -- "$tmp"; die "não foi possível gravar a APP_SECRET_KEY."; }
    key=""
    config_aplica_chaves "$tmp" || { rm -f -- "$tmp"; die "não foi possível aplicar as respostas em $nome."; }
    if grep -q 'ALTERE_AQUI' "$tmp"; then rm -f -- "$tmp"; die "o texto ALTERE_AQUI continua em $nome; confira o modelo do produto."; fi
    mv -f -- "$tmp" "$real" || { rm -f -- "$tmp"; die "não foi possível criar $real."; }
    saida "ok: $nome criado a partir do modelo (APP_SECRET_KEY nova, modo 600, fuso, portas e PANEL_HOSTNAME aplicados)."
    return 0
  fi
  [ -f "$real" ] || die "$real não é um arquivo comum."
  difs="$(config_app_difs "$real")"
  if [ -z "$difs" ]; then saida "ok: $nome já está como as respostas pedem (não alterado)."; return 0; fi
  txt=""
  while IFS='|' read -r k a d; do txt+="    $k: atual='$a' desejado='$d'"$'\n'; done <<<"$difs"
  config_decide "$nome (só as chaves das respostas são mostradas)" "${txt%$'\n'}"
  if [ "$CFG_DECISAO" = manter ]; then
    CFG_MANTIDOS="$CFG_MANTIDOS $nome"
    aviso_msg "$nome mantido como está; as respostas de fuso/portas/PANEL_HOSTNAME NÃO foram aplicadas nele."
    return 0
  fi
  config_backup "$real"
  config_aplica_chaves "$real" || die "não foi possível aplicar as respostas em $nome (a cópia anterior está em $CFG_BAK)."
  # chaves cujo valor desejado é o padrão e que tinham outro valor ativo
  while IFS='|' read -r k a d; do conf_define "$real" "$k" "$d" || die "não foi possível ajustar $k."; done <<<"$difs"
  saida "ok: $nome atualizado só nas chaves mostradas (cópia anterior em $CFG_BAK)."
}

config_rede() { # $1 = nome do arquivo ; demais = entradas
  local nome=$1 ex real cur want txt
  ex="$CFG_DIR/$nome.example"; real="$CFG_DIR/$nome"
  shift
  config_modelo "$nome"
  [ ! -L "$real" ] || die "$real é um link simbólico; recusado."
  if [ ! -e "$real" ]; then
    rede_conteudo "$ex" "$@" | escreve_arq "$real" 644 || die "não foi possível criar $real."
    saida "ok: $nome criado a partir do modelo (modo 644)."
    return 0
  fi
  [ -f "$real" ] || die "$real não é um arquivo comum."
  want="$(rede_conteudo "$ex" "$@" | rede_linhas_ativas | sort)"
  cur="$(rede_linhas_ativas <"$real" | sort)"
  if [ "$cur" = "$want" ]; then saida "ok: $nome já está como as respostas pedem (não alterado)."; return 0; fi
  txt="    atual:"$'\n'"$(printf '%s\n' "${cur:-(nenhuma rede)}" | sed 's/^/      /')"$'\n'"    desejado:"$'\n'"$(printf '%s\n' "${want:-(nenhuma rede)}" | sed 's/^/      /')"
  config_decide "$nome" "$txt"
  if [ "$CFG_DECISAO" = manter ]; then
    CFG_MANTIDOS="$CFG_MANTIDOS $nome"
    aviso_msg "$nome mantido como está; as redes das respostas NÃO foram aplicadas nele."
    return 0
  fi
  config_backup "$real"
  rede_conteudo "$ex" "$@" | escreve_arq "$real" 644 || die "não foi possível substituir $real (a cópia anterior está em $CFG_BAK)."
  saida "ok: $nome substituído (cópia anterior em $CFG_BAK)."
}

# Cópia do modelo do Nginx numa pasta SÓ do root, com o sha256 registrado: o
# --certificado e o HTTPS usam só ela, nunca o /opt/netbackup.
modelo_nginx_copia() {
  local src="$NB_DIR/deploy/nginx/netbackup.conf.template" dst="$SHARE_DIR/netbackup.conf.template" soma
  [ -f "$src" ] && [ ! -L "$src" ] || die "modelo do Nginx ausente ou é link: $src."
  confia "$src" || die "RECUSADO: $src não é confiável: $MSG_CONFIANCA."
  grep -qF -- "$NGINX_MARK" "$src" || die "o modelo do Nginx não tem a marca $NGINX_MARK; confira o produto."
  install -d -m 755 -- "$SHARE_DIR" || die "não foi possível criar $SHARE_DIR."
  chmod 755 -- "$SHARE_DIR"
  cat -- "$src" | escreve_arq "$dst" 644 || die "não foi possível copiar o modelo do Nginx."
  soma="$("$CMD_SHA256" <"$dst" | awk '{print $1}')"
  [[ $soma =~ ^[0-9a-f]{64}$ ]] || die "não foi possível calcular o sha256 do modelo."
  printf '%s  netbackup.conf.template\n' "$soma" | escreve_arq "$dst.sha256" 644 || die "não foi possível registrar o sha256."
  estado_set TEMPLATE_SHA256 "$soma"
  saida "ok: cópia do modelo do Nginx em $dst (sha256 ${soma:0:16}...)."
}

config_prepara() {
  deploy_estado
  case "$DEPLOY_ESTADO" in
    feito|detectado) return 2 ;;
    recusa) die "$DEPLOY_MOTIVO" ;;
  esac
  codigo_estado
  [ "$CODIGO_ESTADO" = ok ] || die "código do produto ausente ou não confiável (${CODIGO_MOTIVO:-ausente}). A configuração não foi aplicada."
  CFG_DIR="$NB_DIR/config"
  { [ -d "$CFG_DIR" ] && [ ! -L "$CFG_DIR" ]; } || die "$CFG_DIR não existe ou é link."
  confia "$CFG_DIR" || die "RECUSADO: $CFG_DIR não é confiável: $MSG_CONFIANCA. O root não escreve em pasta que não é dele."
}

etapa_config_run() {
  local rc
  saida "== 6. Configuração do produto =="
  [ "$R_CARREGADAS" = 1 ] || die "sem respostas carregadas (etapa de perguntas)."
  config_prepara; rc=$?
  if [ "$rc" -eq 2 ]; then
    saida "ok: deploy já feito; a configuração foi aplicada antes dele e não é mais tocada (a pasta é do usuário $APP_USER)."
    return 0
  fi
  config_app
  config_rede trusted_panel_networks.conf "${R_PAINEL[@]}"
  config_rede trusted_public_networks.conf "${R_PUBLICAS[@]}"
  config_rede trusted_private_networks.conf "${R_PRIVADAS[@]}"
  modelo_nginx_copia
  estado_set PRODUTO_COMMIT "$(git_ -C "$NB_DIR" log -1 --format=%h 2>/dev/null | head -n 1)"
  estado_set CONFIG_MANTIDOS "$(trim "$CFG_MANTIDOS")"
}

check_config() {
  local ex nome difs cur want
  deploy_estado
  case "$DEPLOY_ESTADO" in
    feito|detectado) item ok "configuração aplicada antes do deploy (não reconferida: a pasta é do usuário $APP_USER)"; return 0 ;;
    recusa) item falta "$DEPLOY_MOTIVO"; return 0 ;;
  esac
  codigo_estado
  if [ "$CODIGO_ESTADO" != ok ]; then item falta "configuração depende do código do produto"; return 0; fi
  if ! carrega_salvas; then item falta "configuração depende das respostas gravadas"; return 0; fi
  CFG_DIR="$NB_DIR/config"
  if ! confia "$CFG_DIR"; then item falta "$CFG_DIR não confiável: $MSG_CONFIANCA"; return 0; fi
  if [ ! -f "$CFG_DIR/app_settings.conf" ]; then item falta "app_settings.conf ainda não criado"
  else
    difs="$(config_app_difs "$CFG_DIR/app_settings.conf")"
    if [ -z "$difs" ]; then item ok "app_settings.conf conforme as respostas"
    else item aviso "app_settings.conf difere das respostas em: $(printf '%s\n' "$difs" | cut -d'|' -f1 | tr '\n' ' ')"; fi
  fi
  for nome in trusted_panel_networks.conf trusted_public_networks.conf trusted_private_networks.conf; do
    ex="$CFG_DIR/$nome.example"
    if [ ! -f "$CFG_DIR/$nome" ]; then item falta "$nome ainda não criado"; continue; fi
    case "$nome" in
      trusted_panel_networks.conf) want="$(rede_conteudo "$ex" "${R_PAINEL[@]}" | rede_linhas_ativas | sort)" ;;
      trusted_public_networks.conf) want="$(rede_conteudo "$ex" "${R_PUBLICAS[@]}" | rede_linhas_ativas | sort)" ;;
      *) want="$(rede_conteudo "$ex" "${R_PRIVADAS[@]}" | rede_linhas_ativas | sort)" ;;
    esac
    cur="$(rede_linhas_ativas <"$CFG_DIR/$nome" | sort)"
    if [ "$cur" = "$want" ]; then item ok "$nome conforme as respostas"; else item aviso "$nome difere das respostas"; fi
  done
  if [ -f "$SHARE_DIR/netbackup.conf.template" ] && [ "$(awk 'NR==1{print $1}' "$SHARE_DIR/netbackup.conf.template.sha256" 2>/dev/null)" = "$("$CMD_SHA256" <"$SHARE_DIR/netbackup.conf.template" | awk '{print $1}')" ]; then
    item ok "cópia do modelo do Nginx em $SHARE_DIR (sha256 conferido)"
  else
    item falta "cópia do modelo do Nginx ausente ou com sha256 diferente em $SHARE_DIR"
  fi
}

# =============================================================================
# ETAPA DEPLOY - executa deploy.sh --dominio NOME (com confia, em terminal)
# =============================================================================
# Depois dele a árvore é do usuário netbackup: o instalador nunca mais executa
# nem escreve nada de /opt/netbackup.
DEPLOY_ERROS=""
DEPLOY_AVISOS=0
DEPLOY_ADMIN="pendente"

deploy_roda() { # $1 = deploy.sh (caminho real, já confiável)
  local rcf l rc
  DEPLOY_ERROS=""; DEPLOY_AVISOS=0; DEPLOY_ADMIN="pendente"
  rcf="$(mktemp)" || die "mktemp falhou."
  exec 4<&0
  # A saída passa pela função saida (log por função, sem tee); o prompt da senha do
  # admin vem do getpass do produto direto do terminal (nunca passa por aqui).
  while IFS= read -r l; do
    saida "$l"
    case "$l" in
      *ERRO:*) DEPLOY_ERROS+="$l"$'\n' ;;
      *"[aviso]"*) DEPLOY_AVISOS=$((DEPLOY_AVISOS + 1)) ;;
      *"primeiro usuário criado"*) DEPLOY_ADMIN="criado" ;;
      *"o banco já tem"*) DEPLOY_ADMIN="existente" ;;
    esac
  done < <("$CMD_BASH" "$1" --dominio "$R_DOMINIO" 2>&1 <&4; printf '%s\n' "$?" >"$rcf")
  exec 4<&-
  rc="$(cat -- "$rcf" 2>/dev/null)"
  rm -f -- "$rcf"
  [[ $rc =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}

etapa_deploy_run() {
  local real nbreal rc
  saida "== 7. Deploy do produto (deploy.sh) =="
  deploy_estado
  case "$DEPLOY_ESTADO" in
    feito) saida "ok: deploy feito (registro em $ESTADO_FILE); o instalador não executa mais nada de $NB_DIR."; return 0 ;;
    detectado)
      saida "ok: deploy detectado (árvore do usuário $APP_USER e serviço habilitado); não será executado de novo."
      estado_set DEPLOY_FEITO 1; estado_set DEPLOY_ORIGEM detectado
      return 0 ;;
    recusa) die "$DEPLOY_MOTIVO" ;;
  esac
  if [ "$(estado_get DEPLOY_TENTADO)" = "1" ] && ! confia "$NB_DIR"; then
    die "o deploy.sh já foi tentado e não terminou; $NB_DIR não é mais do root, então o instalador recusa executá-lo de novo. Conclua à mão: sudo bash $NB_DIR/deploy/deploy.sh --dominio $R_DOMINIO"
  fi
  [ -e "$DEPLOY_SH" ] || die "deploy.sh não existe ($DEPLOY_SH)."
  real="$(realpath -e -- "$DEPLOY_SH")"
  nbreal="$(realpath -m -- "$NB_DIR")"
  case "$real" in
    "$nbreal"/*) ;;
    *) die "RECUSADO: $DEPLOY_SH aponta para fora de $NB_DIR ($real); não será executado." ;;
  esac
  confia "$real" || die "RECUSADO: deploy.sh não será executado: $MSG_CONFIANCA. Corrija dono/permissões (root, sem escrita para grupo/outros)."
  [ -f "$SHARE_DIR/netbackup.conf.template" ] || die "a cópia do modelo do Nginx não existe; rode a etapa de configuração antes do deploy."
  if [ ! -t 0 ]; then
    aviso_msg "sem terminal interativo: o deploy.sh não conseguirá pedir a senha do administrador; ele avisará como criá-lo depois."
  else
    saida "O deploy.sh vai pedir a senha do usuário admin (12+ caracteres), digitada no terminal e nunca gravada."
  fi
  estado_set PRODUTO_COMMIT "$(git_ -C "$NB_DIR" log -1 --format=%h 2>/dev/null | head -n 1)"
  estado_set DEPLOY_TENTADO 1
  saida "executando: deploy.sh --dominio $R_DOMINIO (a partir daqui $NB_DIR passa a ser do usuário $APP_USER)"
  deploy_roda "$real"; rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$DEPLOY_ERROS" ]; then
    RC_FINAL=1
    erro "deploy.sh terminou com código $rc${DEPLOY_ERROS:+ e reportou ERRO:}"
    if [ -n "$DEPLOY_ERROS" ]; then while IFS= read -r l; do [ -n "$l" ] && erro "  $l"; done <<<"$DEPLOY_ERROS"; fi
    die "o deploy falhou. Corrija a causa e conclua à mão (sudo bash $NB_DIR/deploy/deploy.sh --dominio $R_DOMINIO); o instalador reconhece o deploy concluído na próxima execução."
  fi
  estado_set DEPLOY_FEITO 1
  estado_set DEPLOY_DATA "$(date +%Y-%m-%d)"
  estado_set DEPLOY_AVISOS "$DEPLOY_AVISOS"
  estado_set ADMIN "$DEPLOY_ADMIN"
  saida "ok: deploy.sh concluído (avisos: $DEPLOY_AVISOS; administrador: $DEPLOY_ADMIN)."
}

check_deploy() {
  deploy_estado
  case "$DEPLOY_ESTADO" in
    pendente) item falta "deploy.sh ainda não executado"; return 0 ;;
    recusa) item falta "$DEPLOY_MOTIVO"; return 0 ;;
  esac
  item ok "deploy feito ($DEPLOY_ESTADO; ${NB_DIR} é do usuário $APP_USER e não é mais executado pelo instalador)"
  if "$CMD_SYSTEMCTL" is-active --quiet netbackup.service >/dev/null 2>&1; then item ok "netbackup.service ativo"
  else item falta "netbackup.service não está ativo"; fi
  if "$CMD_SYSTEMCTL" is-active --quiet netbackup-scheduler.service >/dev/null 2>&1; then item ok "netbackup-scheduler.service ativo"
  else item aviso "netbackup-scheduler.service não está ativo"; fi
  case "$(estado_get ADMIN)" in
    criado|existente) item ok "administrador do painel: $(estado_get ADMIN)" ;;
    *) item aviso "administrador do painel ainda não criado (veja o relatório)" ;;
  esac
}

# =============================================================================
# ETAPA HTTPS - DNS, certificado, site do Nginx (definitivo ou provisório)
# =============================================================================
# Nada aqui usa /opt/netbackup: o modelo do Nginx vem da CÓPIA do root
# ($SHARE_DIR) e os ganchos do certbot são os instalados em $HOOKS_DIR pelo deploy.
PROV_CRT="$PROVISORIO_DIR/provisorio.crt"
PROV_KEY="$PROVISORIO_DIR/provisorio.key"
VM_IPV4=()
VM_IPV6=()
DNS_OK=0
DNS_QUIETO=0
HOOK_POST=""
HOOK_POST_PENDENTE=0
PROVA_ESPERA="${PROVA_ESPERA:-2}"

dns_saida() { if [ "$DNS_QUIETO" = 1 ]; then registra "$*"; else saida "$*"; fi; }

vm_enderecos() { # endereços GLOBAIS da VM (ip -o addr)
  local fam end n6
  VM_IPV4=(); VM_IPV6=()
  while read -r _ _ fam end _; do
    end=${end%%/*}
    case "$fam" in
      inet) VM_IPV4+=("$end") ;;
      inet6) if n6="$(ipv6_norm "$end")"; then VM_IPV6+=("$n6"); fi ;;
    esac
  done < <("$CMD_IP" -o addr show scope global 2>/dev/null)
}

em_lista() { # $1 = valor ; demais = lista
  local v=$1 x
  shift
  for x in "$@"; do [ "$x" = "$v" ] && return 0; done
  return 1
}

dns_consulta() { # $1 = resolvedor ; $2 = A|AAAA
  local out
  out="$("$CMD_TIMEOUT" 15 "$CMD_DIG" "@$1" +short +time=3 +tries=2 "$2" "$R_DOMINIO" 2>/dev/null)" || true
  case "$2" in
    A) printf '%s\n' "$out" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true ;;
    *) printf '%s\n' "$out" | grep -E '^[0-9A-Fa-f:]+$' | grep ':' || true ;;
  esac
}

# DNS_OK=1 só se, em TODOS os resolvedores públicos, o A bate com um IPv4 da VM
# e o AAAA (se existir) bate com um IPv6 da VM. AAAA errado = não tenta (o
# Let's Encrypt prefere IPv6). Mostra o encontrado e o esperado.
dns_confere() {
  local r a x ok=1
  local -a a4 a6
  DNS_OK=0
  if ! command -v -- "$CMD_DIG" >/dev/null 2>&1; then
    dns_saida "  DNS não conferido: o programa '$CMD_DIG' não está instalado (pacote bind9-dnsutils)."
    return 1
  fi
  vm_enderecos
  dns_saida "  DNS de $R_DOMINIO. Esperado (endereços globais da VM): A=${VM_IPV4[*]:-nenhum} AAAA=${VM_IPV6[*]:-nenhum}"
  if [ "${#VM_IPV4[@]}" -eq 0 ]; then
    dns_saida "  a VM não tem endereço IPv4 global (NAT?): o Let's Encrypt não alcançaria a porta 80."
    ok=0
  fi
  for r in $DNS_RESOLVERS; do
    mapfile -t a4 < <(dns_consulta "$r" A)
    mapfile -t a6 < <(dns_consulta "$r" AAAA)
    dns_saida "  Encontrado em $r: A=${a4[*]:-(vazio)} AAAA=${a6[*]:-(vazio)}"
    if [ "${#a4[@]}" -eq 0 ]; then
      dns_saida "  -> $r não devolveu registro A para $R_DOMINIO."
      ok=0
    else
      for a in "${a4[@]}"; do
        if ! em_lista "$a" "${VM_IPV4[@]}"; then dns_saida "  -> A $a (em $r) não é um endereço desta VM."; ok=0; fi
      done
    fi
    for a in "${a6[@]}"; do
      x="$(ipv6_norm "$a")" || x="$a"
      if ! em_lista "$x" "${VM_IPV6[@]}"; then
        dns_saida "  -> AAAA $a (em $r) não é um endereço desta VM: não tento emitir (o Let's Encrypt prefere IPv6 e falharia)."
        ok=0
      fi
    done
  done
  DNS_OK=$ok
  [ "$ok" -eq 1 ]
}

porta80_ocupada() {
  "$CMD_SS" -ltnH 2>/dev/null | awk '{ n = split($4, a, ":"); if (a[n] == "80") f = 1 } END { exit f ? 0 : 1 }'
}

# O site padrão do pacote nginx escuta na 80 e impede o certbot standalone; só o LINK é
# removido, e só se o nginx está parado (nada ao vivo depende dele).
nginx_default_libera() {
  [ -L "$NGINX_DEFAULT_LINK" ] || return 0
  if "$CMD_SYSTEMCTL" is-active --quiet nginx.service >/dev/null 2>&1; then
    aviso_msg "$NGINX_DEFAULT_LINK existe e o nginx está ativo: não o removo (a porta 80 pode ficar ocupada)."
    return 0
  fi
  rm -f -- "$NGINX_DEFAULT_LINK" && saida "-> removido o link $NGINX_DEFAULT_LINK (site padrão do nginx escuta na 80; o arquivo em sites-available continua)."
}

gancho_post_garante() {
  if [ "$HOOK_POST_PENDENTE" = 1 ]; then
    HOOK_POST_PENDENTE=0
    registra "EXEC (gancho post): $HOOK_POST"
    "$CMD_BASH" "$HOOK_POST" >/dev/null 2>&1 || aviso_msg "o gancho post (fecha a porta 80) retornou erro; confira: ufw status | grep ACME-hook-auto"
  fi
}

cert_existe() { [ -f "$LE_LIVE/$R_DOMINIO/fullchain.pem" ] && [ -f "$LE_LIVE/$R_DOMINIO/privkey.pem" ]; }

# gancho pre (abre a 80) -> certbot standalone -> gancho post (fecha a 80) SEMPRE (trap).
emite_certificado() {
  local pre="$HOOKS_DIR/pre/00-open-port-80.sh" post="$HOOKS_DIR/post/99-close-port-80.sh" g rc=1
  local -a args
  if ! command -v -- "$CMD_CERTBOT" >/dev/null 2>&1; then erro "certbot não está instalado (o deploy.sh instala o pacote)."; return 1; fi
  for g in "$pre" "$post"; do
    if [ ! -f "$g" ] || ! confia "$g"; then
      erro "gancho do certbot ausente ou não confiável: $g ${MSG_CONFIANCA:+($MSG_CONFIANCA)}. O deploy.sh o instala em $HOOKS_DIR."
      return 1
    fi
  done
  nginx_default_libera
  if porta80_ocupada; then
    erro "a porta 80 está ocupada (o certbot standalone precisa dela livre); libere-a e rode: instalar.sh --certificado"
    return 1
  fi
  args=(certonly --standalone -d "$R_DOMINIO" -m "$R_EMAIL" --agree-tos --no-eff-email --non-interactive)
  if [ "$LE_STAGING" = 1 ]; then args+=(--staging); fi
  if [ "$LE_STAGING" != 1 ] && [ "$(estado_get CERT_TIPO)" = staging ]; then args+=(--force-renewal); fi
  HOOK_POST="$post"; HOOK_POST_PENDENTE=1
  trap 'gancho_post_garante' EXIT
  trap 'gancho_post_garante; exit 130' INT TERM HUP
  if executa "$CMD_BASH" "$pre"; then
    executa "$CMD_CERTBOT" "${args[@]}"; rc=$?
  else
    erro "o gancho pre (abre a porta 80) falhou; o certbot não foi executado."
  fi
  gancho_post_garante
  trap - EXIT INT TERM HUP
  if [ "$rc" -eq 0 ] && ! cert_existe; then erro "o certbot terminou sem erro, mas não encontrei o certificado em $LE_LIVE/$R_DOMINIO."; rc=1; fi
  return "$rc"
}

provisorio_cert() {
  local san ip n=0
  ( umask 077; mkdir -p -- "$PROVISORIO_DIR" ) || return 1
  chmod 700 -- "$PROVISORIO_DIR" || return 1
  if [ -f "$PROV_CRT" ] && [ -f "$PROV_KEY" ] && "$CMD_OPENSSL" x509 -in "$PROV_CRT" -noout -checkend 2592000 >/dev/null 2>&1; then
    return 0
  fi
  vm_enderecos
  san="DNS:$R_DOMINIO"
  for ip in "${VM_IPV4[@]}"; do
    n=$((n + 1)); [ "$n" -le 5 ] || break
    san="$san,IP:$ip"
  done
  rm -f -- "$PROV_CRT.tmp" "$PROV_KEY.tmp"
  ( umask 077; "$CMD_OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 \
      -keyout "$PROV_KEY.tmp" -out "$PROV_CRT.tmp" -subj "/CN=$R_DOMINIO" \
      -addext "subjectAltName=$san" >/dev/null 2>&1 ) || { rm -f -- "$PROV_CRT.tmp" "$PROV_KEY.tmp"; erro "openssl não gerou o certificado provisório."; return 1; }
  chmod 600 -- "$PROV_KEY.tmp" && chmod 644 -- "$PROV_CRT.tmp" \
    && mv -f -- "$PROV_KEY.tmp" "$PROV_KEY" && mv -f -- "$PROV_CRT.tmp" "$PROV_CRT" || return 1
  saida "-> certificado provisório (autoassinado, 365 dias) gerado em $PROVISORIO_DIR"
}

# Conteúdo do site a partir da CÓPIA do root do modelo (sha256 conferido), com a
# mesma troca validada do deploy.sh (expansão do bash; nada é executado).
site_conteudo() { # $1 = definitivo|provisorio
  local tpl="$SHARE_DIR/netbackup.conf.template" shaf="$SHARE_DIR/netbackup.conf.template.sha256" esperado atual conteudo l n=0
  confia "$tpl" || return 1
  esperado="$(awk 'NR==1 {print $1}' "$shaf" 2>/dev/null)"
  atual="$("$CMD_SHA256" <"$tpl" | awk '{print $1}')"
  [ -n "$esperado" ] && [ "$esperado" = "$atual" ] || return 1
  conteudo="$(cat -- "$tpl")"
  conteudo="${conteudo//"$NGINX_MARK"/"$R_DOMINIO"}"
  if [ "$1" = definitivo ]; then printf '%s\n' "$conteudo"; return 0; fi
  printf '%s\n' "$MARCA_PROVISORIO"
  while IFS= read -r l; do
    if [[ $l =~ ^[[:space:]]*ssl_certificate_key[[:space:]] ]]; then
      printf '    ssl_certificate_key %s;\n' "$PROV_KEY"; n=$((n + 1))
    elif [[ $l =~ ^[[:space:]]*ssl_certificate[[:space:]] ]]; then
      printf '    ssl_certificate     %s;\n' "$PROV_CRT"; n=$((n + 1))
    else
      printf '%s\n' "$l"
    fi
  done <<<"$conteudo"
  [ "$n" -eq 2 ]
}

# ausente | provisorio | outro  (outro = não gerado por este instalador: nunca é tocado)
site_modo() {
  if [ ! -e "$NGINX_SITE_DST" ] && [ ! -L "$NGINX_SITE_DST" ]; then echo ausente; return 0; fi
  if [ -f "$NGINX_SITE_DST" ] && [ ! -L "$NGINX_SITE_DST" ] && [ "$(head -n 1 "$NGINX_SITE_DST")" = "$MARCA_PROVISORIO" ]; then
    echo provisorio; return 0
  fi
  echo outro
}

# Grava o site (só se ausente ou provisório; o chamador decide), liga o link e roda nginx -t;
# se o nginx -t falhar, volta o site anterior (o provisório) e desfaz o link novo.
site_aplica() { # $1 = definitivo|provisorio
  local dir tmp bak="" existia=0 criou_link=0 out
  dir="$(dirname -- "$NGINX_SITE_DST")"
  [ -d "$dir" ] || { erro "pasta $dir não existe (o nginx está instalado?)."; return 1; }
  tmp="$(mktemp "$dir/.instalador.XXXXXX")" || { erro "não foi possível criar temporário em $dir."; return 1; }
  if ! site_conteudo "$1" >"$tmp"; then
    rm -f -- "$tmp"
    erro "a cópia do modelo do Nginx ($SHARE_DIR) está ausente, alterada (sha256) ou fora do esperado; nada foi gravado."
    return 1
  fi
  chmod 644 -- "$tmp"
  if [ -e "$NGINX_SITE_DST" ]; then
    existia=1
    if cmp -s "$tmp" "$NGINX_SITE_DST"; then
      rm -f -- "$tmp"
    else
      bak="$(mktemp "$dir/.instalador-anterior.XXXXXX")" || { rm -f -- "$tmp"; return 1; }
      cp -p -- "$NGINX_SITE_DST" "$bak" || { rm -f -- "$tmp" "$bak"; return 1; }
      mv -f -- "$tmp" "$NGINX_SITE_DST" || { rm -f -- "$tmp" "$bak"; return 1; }
    fi
  else
    mv -f -- "$tmp" "$NGINX_SITE_DST" || { rm -f -- "$tmp"; return 1; }
  fi
  if [ -L "$NGINX_SITE_LINK" ]; then
    if [ "$(readlink -f -- "$NGINX_SITE_LINK")" != "$(readlink -f -- "$NGINX_SITE_DST")" ]; then
      aviso_msg "$NGINX_SITE_LINK aponta para outro arquivo; não foi alterado."
    fi
  elif [ -e "$NGINX_SITE_LINK" ]; then
    aviso_msg "$NGINX_SITE_LINK existe e não é um link; não foi alterado."
  else
    ln -s -- "$NGINX_SITE_DST" "$NGINX_SITE_LINK" || { erro "não foi possível criar $NGINX_SITE_LINK."; return 1; }
    criou_link=1
  fi
  if out="$("$CMD_NGINX" -t 2>&1)"; then
    registra "nginx -t: ok"
    [ -z "$bak" ] || rm -f -- "$bak"
    return 0
  fi
  erro "nginx -t falhou: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
  if [ -n "$bak" ]; then mv -f -- "$bak" "$NGINX_SITE_DST"
  elif [ "$existia" -eq 0 ]; then rm -f -- "$NGINX_SITE_DST"; fi
  if [ "$criou_link" -eq 1 ]; then rm -f -- "$NGINX_SITE_LINK"; fi
  erro "o site anterior foi restaurado."
  return 1
}

nginx_ativa() {
  if "$CMD_SYSTEMCTL" is-active --quiet nginx.service >/dev/null 2>&1; then
    executa "$CMD_SYSTEMCTL" reload nginx.service
  else
    executa "$CMD_SYSTEMCTL" enable --now nginx.service
  fi
}

# 0 se https responder 302/403 (no ar). Definitivo com certificado de produção: valida o
# certificado e o nome; senão (provisório/staging) aceita o certificado sem confiança.
https_prova() { # $1 = definitivo|provisorio
  local code="" i alvo
  local -a opts=(-s -o /dev/null -m 10 -w '%{http_code}')
  if [ "$1" = definitivo ] && [ "$(estado_get CERT_TIPO)" = producao ]; then
    opts+=(--resolve "$R_DOMINIO:$HTTPS_PORT:127.0.0.1"); alvo="https://$R_DOMINIO:$HTTPS_PORT/"
  else
    opts+=(-k); alvo="https://127.0.0.1:$HTTPS_PORT/"
  fi
  for i in 1 2 3 4 5; do
    code="$("$CMD_CURL" "${opts[@]}" "$alvo" 2>/dev/null)" || code=""
    case "$code" in 302|403) saida "-> $alvo respondeu $code (no ar)."; return 0 ;; esac
    sleep "$PROVA_ESPERA"
  done
  aviso_msg "$alvo não respondeu 302/403 (último código: ${code:-nenhum}); confira: systemctl status nginx / netbackup"
  return 1
}

acesso_ip() { vm_enderecos; printf '%s' "${VM_IPV4[0]:-}"; }

https_definitivo_cert() { # emite (se preciso); 0 = há certificado de acordo com o pedido
  local novo=0
  if cert_existe && ! { [ "$LE_STAGING" != 1 ] && [ "$(estado_get CERT_TIPO)" = staging ]; }; then
    saida "ok: já existe certificado em $LE_LIVE/$R_DOMINIO; não emito de novo."
  else
    if [ "$LE_STAGING" = 1 ]; then saida "-> emitindo certificado de TESTE (--staging)"; else saida "-> emitindo certificado (Let's Encrypt)"; fi
    emite_certificado || return 1
    novo=1
    if [ "$LE_STAGING" = 1 ]; then estado_set CERT_TIPO staging; else estado_set CERT_TIPO producao; fi
  fi
  [ "$novo" -eq 1 ] || [ -n "$(estado_get CERT_TIPO)" ] || estado_set CERT_TIPO producao
}

https_definitivo() { # emite (se preciso) e aplica o site definitivo; 0 = ok
  https_definitivo_cert || return 1
  site_aplica definitivo || return 1
}

etapa_https_run() {
  local modo
  saida "== 8. HTTPS (Nginx na porta $HTTPS_PORT) =="
  [ "$R_CARREGADAS" = 1 ] || die "sem respostas carregadas (etapa de perguntas)."
  deploy_estado
  case "$DEPLOY_ESTADO" in
    feito|detectado) ;;
    *) die "o HTTPS vem depois do deploy; o deploy ainda não foi feito." ;;
  esac
  command -v -- "$CMD_NGINX" >/dev/null 2>&1 || die "nginx não está instalado (o deploy.sh instala o pacote)."
  nginx_default_libera
  modo="$(site_modo)"
  if [ "$modo" = outro ] && [ "$(estado_get HTTPS_MODO)" = definitivo ]; then
    # site definitivo gerado por este instalador numa execução anterior: nunca é reescrito
    saida "ok: HTTPS definitivo já configurado por este instalador ($NGINX_SITE_DST não é reescrito)."
    if [ "$LE_STAGING" != 1 ] && [ "$(estado_get CERT_TIPO)" = staging ]; then
      saida "-> o certificado atual é de TESTE (staging); emitindo o de produção."
      if dns_confere && https_definitivo_cert; then
        nginx_ativa || RC_FINAL=1
      else
        aviso_msg "o certificado de produção não foi emitido; o de teste continua."
      fi
    fi
    if "$CMD_NGINX" -t >/dev/null 2>&1; then nginx_ativa || RC_FINAL=1; else erro "nginx -t falha com o site atual; confira à mão."; RC_FINAL=1; fi
    https_prova definitivo || RC_FINAL=1
    return 0
  fi
  if [ "$modo" = outro ]; then
    saida "ok: já existe $NGINX_SITE_DST que não foi gerado por este instalador; NÃO será alterado."
    if "$CMD_NGINX" -t >/dev/null 2>&1; then nginx_ativa || RC_FINAL=1; else aviso_msg "nginx -t falha com o site existente; confira à mão."; RC_FINAL=1; fi
    estado_set HTTPS_MODO existente
    https_prova provisorio || true
    return 0
  fi
  if [ ! -f "$SHARE_DIR/netbackup.conf.template" ]; then
    die "a cópia do modelo do Nginx ($SHARE_DIR/netbackup.conf.template) não existe: ela é feita pela etapa de configuração, ANTES do deploy.sh. Depois do deploy o instalador não lê nada de $NB_DIR; gere o site à mão (sudo bash $NB_DIR/deploy/deploy.sh --dominio $R_DOMINIO depois de emitir o certificado, docs/https-nginx.md do produto)."
  fi
  saida "Conferindo o DNS de $R_DOMINIO em resolvedores públicos ($DNS_RESOLVERS)..."
  if dns_confere && https_definitivo; then
    estado_set HTTPS_MODO definitivo
    estado_set ACESSO "https://$R_DOMINIO:$HTTPS_PORT"
    nginx_ativa || RC_FINAL=1
    https_prova definitivo || RC_FINAL=1
    return 0
  fi
  if [ "$DNS_OK" = 1 ]; then aviso_msg "não foi possível emitir o certificado; o HTTPS ficará provisório."; fi
  saida "-> HTTPS PROVISÓRIO (certificado autoassinado)."
  provisorio_cert || die "não foi possível gerar o certificado provisório."
  site_aplica provisorio || die "o site provisório não passou no nginx -t (o nginx não foi tocado)."
  estado_set HTTPS_MODO provisorio
  estado_set CERT_TIPO autoassinado
  estado_set ACESSO "https://$(acesso_ip):$HTTPS_PORT"
  nginx_ativa || RC_FINAL=1
  https_prova provisorio || RC_FINAL=1
  saida "ATENÇÃO: HTTPS provisório. Acesse https://$(acesso_ip):$HTTPS_PORT (aviso do navegador esperado); quando o DNS de $R_DOMINIO apontar para esta VM, rode: bash instalar.sh --certificado"
}

check_https() {
  local modo
  deploy_estado
  case "$DEPLOY_ESTADO" in feito|detectado) ;; *) item falta "HTTPS depende do deploy (ainda não feito)"; return 0 ;; esac
  carrega_salvas || { item falta "HTTPS depende das respostas gravadas"; return 0; }
  modo="$(site_modo)"
  case "$modo" in
    ausente) item falta "site do Nginx ainda não gerado ($NGINX_SITE_DST)" ;;
    provisorio) item aviso "HTTPS PROVISÓRIO (autoassinado); quando o DNS apontar, rode: instalar.sh --certificado" ;;
    *) if cert_existe; then item ok "site do Nginx instalado e certificado em $LE_LIVE/$R_DOMINIO"
       else item falta "site do Nginx existe, mas não há certificado em $LE_LIVE/$R_DOMINIO"; fi ;;
  esac
  if [ "$modo" != ausente ]; then
    if [ -L "$NGINX_SITE_LINK" ]; then item ok "site habilitado ($NGINX_SITE_LINK)"; else item falta "site não habilitado ($NGINX_SITE_LINK)"; fi
    if "$CMD_SYSTEMCTL" is-active --quiet nginx.service >/dev/null 2>&1; then item ok "nginx ativo"; else item falta "nginx não está ativo"; fi
  fi
  if [ "$(estado_get CERT_TIPO)" = staging ]; then item aviso "certificado de TESTE (staging): não é confiável nos navegadores"; fi
  if [ "$CHECK_REMOTE" = 1 ] && [ "$modo" != ausente ]; then
    DNS_QUIETO=1
    if dns_confere; then item ok "DNS de $R_DOMINIO confere com a VM (A/AAAA)"
    else item aviso "DNS de $R_DOMINIO não confere com a VM (ou não pôde ser conferido)"; fi
    DNS_QUIETO=0
  fi
}

# ---- modo --certificado ------------------------------------------------------
modo_certificado() {
  local modo
  abre_log
  saida "Modo --certificado: trocar o HTTPS provisório pelo certificado definitivo"
  carrega_respostas_arquivo "$RESPOSTAS_SALVAS" || die "não há respostas gravadas válidas em $RESPOSTAS_SALVAS (rode antes o instalador completo)."
  deploy_estado
  case "$DEPLOY_ESTADO" in feito|detectado) ;; *) die "o deploy ainda não foi feito; rode antes o instalador completo." ;; esac
  command -v -- "$CMD_NGINX" >/dev/null 2>&1 || die "nginx não está instalado."
  modo="$(site_modo)"
  case "$modo" in
    ausente) die "ainda não há site do Nginx; rode antes o instalador completo." ;;
    outro)
      if [ "$(estado_get HTTPS_MODO)" = definitivo ] && [ "$LE_STAGING" != 1 ] && [ "$(estado_get CERT_TIPO)" = staging ]; then
        saida "O certificado atual é de TESTE (staging); emitindo o de produção (o site não é reescrito)."
        dns_confere || { erro "o DNS ainda não aponta para esta VM; nada foi alterado."; return 1; }
        https_definitivo_cert || { erro "o certificado de produção não foi emitido; o de teste continua."; return 1; }
        nginx_ativa || return 1
        https_prova definitivo || return 1
        saida "ok: certificado de produção em uso."
        return 0
      fi
      if cert_existe; then saida "ok: o site instalado não é provisório e há certificado em $LE_LIVE/$R_DOMINIO; nada a fazer."; return 0; fi
      erro "o site em $NGINX_SITE_DST não foi gerado por este instalador (não tem o cabeçalho '$MARCA_PROVISORIO'); NÃO será tocado."
      erro "ajuste-o à mão ou remova-o para que o instalador o gere; nada foi alterado."
      return 1 ;;
  esac
  saida "Conferindo o DNS de $R_DOMINIO em resolvedores públicos ($DNS_RESOLVERS)..."
  if ! dns_confere; then
    erro "o DNS ainda não aponta para esta VM; nada foi alterado (o HTTPS provisório continua)."
    return 1
  fi
  https_definitivo || { erro "o site provisório continua no ar; nada foi trocado."; return 1; }
  estado_set HTTPS_MODO definitivo
  estado_set ACESSO "https://$R_DOMINIO:$HTTPS_PORT"
  nginx_ativa || return 1
  https_prova definitivo || return 1
  saida "ok: agora acesse https://$R_DOMINIO:$HTTPS_PORT"
}

# =============================================================================
# ETAPA FIREWALL - regra da 44318/tcp para cada rede do painel (só acrescenta)
# =============================================================================
# O comentário é o MESMO que a tela Firewall do produto usa (modules/firewall_manager.py:
# "<rótulo da porta> - <rótulo do tipo de rede>"). Não remove nem altera regra existente
# e não toca nas do baseline (SSH).
ufw_regra_existe() { # $1 = rede CIDR
  local alvo=${1%/32}
  "$CMD_UFW" status 2>/dev/null | awk -v p="$HTTPS_PORT/tcp" -v a="$alvo" \
    '$1 == p && $2 == "ALLOW" { f = $3; if (f == "IN") f = $4; if (f == a) achou = 1 } END { exit achou ? 0 : 1 }'
}

etapa_firewall_run() {
  local e net
  saida "== 9. Firewall (${HTTPS_PORT}/tcp para as redes do painel) =="
  [ "$R_CARREGADAS" = 1 ] || die "sem respostas carregadas (etapa de perguntas)."
  for e in "${R_PAINEL[@]}"; do
    net=${e%% *}
    if ufw_regra_existe "$net"; then
      saida "ok: regra de ${HTTPS_PORT}/tcp para $net já existe."
      continue
    fi
    if executa "$CMD_UFW" allow from "$net" to any port "$HTTPS_PORT" proto tcp comment "$UFW_COMMENT" && ufw_regra_existe "$net"; then
      saida "feito: ${HTTPS_PORT}/tcp liberada para $net (comentário '$UFW_COMMENT')."
    else
      erro "não foi possível criar a regra do UFW para $net."
      RC_FINAL=1
    fi
  done
}

check_firewall() {
  local e net
  carrega_salvas || { item falta "firewall depende das respostas gravadas"; return 0; }
  for e in "${R_PAINEL[@]}"; do
    net=${e%% *}
    if ufw_regra_existe "$net"; then item ok "UFW: ${HTTPS_PORT}/tcp liberada para $net"
    else item falta "UFW: falta ${HTTPS_PORT}/tcp para $net"; fi
  done
}

# =============================================================================
# ETAPA RELATÓRIO FINAL
# =============================================================================
# Antes do deploy (instalação parada no meio) ainda é possível rodar "deploy.sh --check"
# (somente leitura, com trava). Depois dele a árvore é do usuário netbackup e o
# instalador não executa mais nada de lá: o relatório usa só o registro do root.
deploy_check() { # roda "deploy.sh --check" depois de conferir a confiança
  local real nbreal out rc erros npend l
  DEPLOY_RESULT=""
  if [ ! -e "$DEPLOY_SH" ]; then
    saida "deploy.sh ainda não existe ($DEPLOY_SH)."; return 1
  fi
  real="$(realpath -e -- "$DEPLOY_SH")"
  nbreal="$(realpath -m -- "$NB_DIR")"
  case "$real" in
    "$nbreal"/*) ;;
    *) erro "RECUSADO: $DEPLOY_SH aponta para fora de $NB_DIR ($real); não será executado."; return 1 ;;
  esac
  if ! confia "$real"; then
    erro "RECUSADO: deploy.sh não será executado: $MSG_CONFIANCA. Corrija dono/permissões (root, sem escrita para grupo/outros)."
    return 1
  fi
  saida "executando: deploy.sh --check (somente leitura)"
  out="$("$CMD_BASH" "$real" --check 2>&1)"; rc=$?
  saida "$out"
  if [ "$rc" -eq 0 ]; then
    DEPLOY_RESULT="ok"
    saida "deploy.sh --check: ok, sem pendências."
    return 0
  fi
  erros="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*ERRO:' || true)"
  npend="$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*\[falta\]')"
  if [ -n "$erros" ]; then
    DEPLOY_RESULT="erro"
    erro "deploy.sh --check reportou ERRO (código $rc):"
    while IFS= read -r l; do erro "  $l"; done <<<"$erros"
    erro "isto NÃO é pendência de configuração: corrija e rode de novo. A execução termina com código diferente de 0."
    return 1
  elif [ "$npend" -gt 0 ]; then
    DEPLOY_RESULT="pendencias"
    saida "deploy.sh --check: $npend pendência(s), esperadas até o deploy."
    return 0
  fi
  DEPLOY_RESULT="erro"
  erro "deploy.sh --check terminou com código $rc sem itens [falta] reconhecíveis (saída inesperada; veja acima e o log)."
  return 1
}

check_relatorio() {
  if [ "$CHECK_REMOTE" != 1 ]; then return 0; fi
  deploy_estado
  case "$DEPLOY_ESTADO" in
    feito|detectado) item ok "deploy feito: deploy.sh --check não é mais executado pelo instalador (a pasta é do usuário $APP_USER)"; return 0 ;;
    recusa) item falta "$DEPLOY_MOTIVO"; return 0 ;;
  esac
  codigo_estado
  if [ "$CODIGO_ESTADO" != "ok" ]; then item falta "deploy.sh --check não executado (código ausente)"; return 0; fi
  if confia "$(realpath -m -- "$DEPLOY_SH")"; then
    item ok "deploy.sh confiável (root, sem escrita para grupo/outros)"
  else
    item falta "deploy.sh NÃO será executado: $MSG_CONFIANCA"
    return 0
  fi
  deploy_check
  case "$DEPLOY_RESULT" in
    ok) item ok "deploy.sh --check sem pendências" ;;
    pendencias) item aviso "deploy.sh --check com pendências (esperadas até o deploy)" ;;
    *) item falta "deploy.sh --check falhou (ERRO ou saída inesperada)" ;;
  esac
}

resumo_etapas() {
  local e titulo f
  saida "Estado das etapas:"
  for e in "${ETAPAS[@]}"; do
    [ "$e" = "relatorio" ] && continue
    f="check_$e"
    zera_itens; QUIET_ITEMS=1; CHECK_REMOTE=0
    "$f"
    QUIET_ITEMS=0
    titulo="$(titulo_etapa "$e")"
    if [ "$N_FALTA" -gt 0 ]; then saida "  [falta] $titulo ($N_FALTA pendência(s))"
    elif [ "$N_AVISO" -gt 0 ]; then saida "  [ok*]   $titulo (com aviso)"
    else saida "  [ok]    $titulo"; fi
  done
}

titulo_etapa() {
  case "$1" in
    precheck) echo "Pré-checagem" ;;
    perguntas) echo "Respostas da instalação" ;;
    disco) echo "Disco de dados em $OPT_DIR" ;;
    chave) echo "Chave de deploy do GitHub" ;;
    codigo) echo "Código do produto" ;;
    config) echo "Configuração do produto" ;;
    deploy) echo "Deploy do produto (deploy.sh)" ;;
    https) echo "HTTPS (Nginx) na porta $HTTPS_PORT" ;;
    firewall) echo "Firewall (regras da porta $HTTPS_PORT)" ;;
    relatorio) echo "Relatório (deploy.sh --check)" ;;
    *) echo "$1" ;;
  esac
}

# Texto do relatório (stdout). Sem segredos: nada de senha, chave nem e-mail.
relatorio_texto() {
  local hmodo ctipo acesso commit admin e feito_deploy=0
  hmodo="$(estado_get HTTPS_MODO)"; ctipo="$(estado_get CERT_TIPO)"; acesso="$(estado_get ACESSO)"
  commit="$(estado_get PRODUTO_COMMIT)"; admin="$(estado_get ADMIN)"
  deploy_estado
  case "$DEPLOY_ESTADO" in feito|detectado) feito_deploy=1 ;; esac
  printf 'NetBackup Manager - relatório da instalação\n'
  printf '===========================================\n'
  printf 'Instalador ...........: versão %s\n' "$VERSAO"
  printf 'Data .................: %s\n' "$(date '+%Y-%m-%d %H:%M')"
  printf 'Produto (commit) ....: %s\n' "${commit:-desconhecido}"
  printf '\nACESSO\n'
  if [ "$hmodo" = provisorio ] && [ -n "$acesso" ]; then printf '  Acesse %s (aviso do navegador esperado: certificado provisório)\n' "$acesso"
  elif [ -n "$acesso" ]; then printf '  Acesse %s\n' "$acesso"; else printf '  (o HTTPS ainda não foi configurado)\n'; fi
  printf '  Login ...............: admin\n'
  printf '  Senha ...............: a que você digitou no deploy.sh (não é gravada em lugar nenhum)\n'
  printf '\nO QUE FOI FEITO\n'
  printf '  - pré-checagem da VM\n'
  if disco_pronto; then printf '  - disco de dados em %s (LVM %s/%s)\n' "$OPT_DIR" "$VG_NAME" "$LV_NAME"; fi
  printf '  - chave de deploy do GitHub (somente leitura) e código do produto em %s\n' "$NB_DIR"
  if [ "$feito_deploy" = 1 ]; then
    printf '  - configuração do produto (fuso, portas sugeridas, PANEL_HOSTNAME, redes) e deploy.sh concluído\n'
  fi
  case "$hmodo" in
    definitivo) printf '  - HTTPS com certificado %s para %s\n' "$([ "$ctipo" = staging ] && echo 'de TESTE (staging)' || echo 'Let'"'"'s Encrypt')" "${R_DOMINIO:-o painel}" ;;
    provisorio) printf '  - HTTPS PROVISÓRIO (certificado autoassinado) no site do Nginx\n' ;;
    existente) printf '  - HTTPS: já havia um site do Nginx (não alterado)\n' ;;
  esac
  if [ "$R_CARREGADAS" = 1 ] && [ "${#R_PAINEL[@]}" -gt 0 ]; then
    printf '  - firewall: %s/tcp liberada para:\n' "$HTTPS_PORT"
    for e in "${R_PAINEL[@]}"; do printf '      %s\n' "$e"; done
  fi
  printf '\nO QUE FICOU PENDENTE\n'
  local pend=0
  if [ "$feito_deploy" != 1 ]; then printf '  - deploy do produto (deploy.sh) ainda não executado\n'; pend=1; fi
  if [ "$hmodo" = provisorio ]; then
    printf '  - certificado definitivo: aponte o DNS de %s para esta VM e rode: bash instalar.sh --certificado\n' "${R_DOMINIO:-o painel}"
    pend=1
  fi
  if [ "$ctipo" = staging ]; then
    printf '  - o certificado é de TESTE (staging): rode sem LE_STAGING=1 para emitir o definitivo\n'; pend=1
  fi
  if [ "$feito_deploy" = 1 ] && [ "$admin" != criado ] && [ "$admin" != existente ]; then
    printf '  - criar o administrador: cd %s && sudo -u %s venv/bin/python tools/create_admin.py\n' "$NB_DIR" "$APP_USER"; pend=1
  fi
  if [ -n "$(estado_get CONFIG_MANTIDOS)" ]; then
    printf '  - arquivos de configuração mantidos como estavam (as respostas não foram aplicadas): %s\n' "$(estado_get CONFIG_MANTIDOS)"; pend=1
  fi
  if [ "$pend" = 0 ]; then printf '  (nada)\n'; fi
  printf '\nPRÓXIMOS PASSOS\n'
  printf '  1. Abra o endereço de acesso acima e entre com o login admin.\n'
  printf '  2. No painel, ligue os módulos opcionais conforme a necessidade: backup externo,\n'
  printf '     Telegram, e-mail, monitor etc. (nenhum vem ligado).\n'
  printf '  3. Cadastre os equipamentos (portas sugeridas já configuradas).\n'
  printf '  4. Confira a tela Firewall do painel (as regras criadas aqui aparecem lá).\n'
}

etapa_relatorio_run() {
  local texto
  saida "== 10. Relatório =="
  deploy_estado
  case "$DEPLOY_ESTADO" in
    pendente) deploy_check || RC_FINAL=1 ;;
  esac
  saida ""
  resumo_etapas
  saida ""
  texto="$(relatorio_texto)"
  printf '%s\n' "$texto" | escreve_arq "$RELATORIO_TXT" 600 || die "não foi possível gravar $RELATORIO_TXT."
  saida "$texto"
  saida ""
  saida "Relatório gravado em $RELATORIO_TXT (modo 600)."
  saida "Log desta execução: ${LOG_FILE}"
}

# =============================================================================
# MODOS
# =============================================================================
modo_check() {
  local e total=0
  CHECK_REMOTE=1
  saida "Modo --check (somente leitura: nada será alterado)"
  for e in "${ETAPAS[@]}"; do
    saida "== $(titulo_etapa "$e") =="
    "check_$e"
  done
  total=$N_FALTA
  saida ""
  saida "Resumo: ${N_OK} ok, ${N_AVISO} aviso(s), ${N_FALTA} falta(m)."
  [ "$total" -eq 0 ]
}

modo_status() {
  CHECK_REMOTE=0
  saida "Modo --status (somente leitura, sem acessar a rede)"
  resumo_etapas
  return 0
}

abre_log() {
  local base n=1
  [ -d "$LOG_DIR" ] || die "pasta do log inexistente: $LOG_DIR"
  base="$LOG_DIR/netbackup-instalacao-$(date +%Y%m%d_%H%M%S)"
  LOG_FILE="$base.log"
  while [ -e "$LOG_FILE" ]; do n=$((n + 1)); LOG_FILE="${base}_$n.log"; done
  ( umask 077; : >"$LOG_FILE" ) || die "não foi possível criar o log em $LOG_FILE"
  chmod 600 -- "$LOG_FILE"
  registra "NetBackup Instalador versão $VERSAO (modo $MODO)"
  saida "Log: $LOG_FILE"
  export GIT_PAGER=cat GIT_TERMINAL_PROMPT=0
}

modo_executar() {
  local e
  abre_log
  GIT_SSH_COMMAND="$(git_ssh_cmd)"; export GIT_SSH_COMMAND
  for e in "${ETAPAS[@]}"; do
    "etapa_${e}_run"
  done
  return "$RC_FINAL"
}

uso() {
  cat <<EOF
Uso: sudo bash instalar.sh [opção]

  (sem opção)          instala do começo ao fim: pré-checagem, perguntas, disco
                       opcional, chave de deploy, código, configuração, deploy.sh,
                       HTTPS, firewall e relatório; pode ser repetido (retoma)
  --respostas ARQUIVO  usa um arquivo CHAVE=valor (sem segredos) em vez de perguntar
  --certificado        troca o HTTPS provisório pelo certificado Let's Encrypt
                       (depois que o DNS apontar para a VM)
  --check              só leitura: informa ok/falta por item, não altera nada
  --status             só leitura: resumo do que está pronto (sem rede)
  -h, --help           esta ajuda

Variável útil: LE_STAGING=1 usa o ambiente de TESTE do Let's Encrypt (bancada).
Software proprietário, uso sob licença.
EOF
}

main() {
  MODO="executar"
  local modo_dado=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check|--status|--certificado|-h|--help)
        if [ "$modo_dado" = 1 ]; then printf 'ERRO: argumentos demais.\n' >&2; exit 2; fi
        modo_dado=1
        case "$1" in
          --check) MODO="check" ;;
          --status) MODO="status" ;;
          --certificado) MODO="certificado" ;;
          *) MODO="ajuda" ;;
        esac ;;
      --respostas)
        if [ "$#" -lt 2 ] || [ -z "$2" ] || [ -n "$RESPOSTAS_ARQ" ]; then
          printf 'NetBackup Instalador versão %s\n' "$VERSAO"
          printf 'ERRO: --respostas precisa de um ARQUIVO (uma vez só).\n' >&2; exit 2
        fi
        RESPOSTAS_ARQ="$2"; shift ;;
      *) printf 'NetBackup Instalador versão %s\n' "$VERSAO"
         printf 'ERRO: opção desconhecida: %s\n' "$1" >&2; uso >&2; exit 2 ;;
    esac
    shift
  done
  if [ -n "$RESPOSTAS_ARQ" ] && [ "$MODO" != "executar" ]; then
    printf 'ERRO: --respostas só vale na instalação completa.\n' >&2; exit 2
  fi

  printf 'NetBackup Instalador versão %s\n' "$VERSAO"
  if [ "$MODO" = "ajuda" ]; then uso; exit 0; fi

  exige_root
  exige_instalador_confiavel

  case "$MODO" in
    check) modo_check; exit $? ;;
    status) modo_status; exit $? ;;
    certificado) modo_certificado; exit $? ;;
    executar) modo_executar; exit $? ;;
  esac
}

main "$@"
