#!/usr/bin/env bash
# =============================================================================
# NetBackup Manager - instalador (FASE 3a: preparar a VM até o código estar no lugar)
#
# Software proprietário, uso sob licença. Este arquivo é só o instalador.
#
# Uso:  sudo bash instalar.sh [--check | --status | -h | --help]
#
# Organização (para a Fase 3b encaixar):
#   - cada etapa tem  check_<etapa>  (SÓ LEITURA, imprime ok/falta/aviso por item)
#     e  etapa_<etapa>_run  (age, depois de conferir o estado: idempotente);
#   - a lista ETAPAS define a ordem; a 3b acrescenta etapas (configuração,
#     certificado, firewall, admin) neste mesmo arquivo, sem mexer nas atuais;
#   - estado conferível: --check (detalhado) e --status (resumo, sem rede).
# =============================================================================
set -u
export LC_ALL=C

VERSAO="0.1.0-dev"

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

# Ordem das etapas (a 3b acrescenta aqui: config, certificado, firewall, admin).
ETAPAS=(precheck disco chave codigo relatorio)

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
  dono="$(stat -c '%u' -- "$1" 2>/dev/null)" || { MSG_CONFIANCA="não foi possível ler o dono de $1"; return 1; }
  modo="$(stat -c '%a' -- "$1" 2>/dev/null)" || { MSG_CONFIANCA="não foi possível ler as permissões de $1"; return 1; }
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
# é exigido se houver disco candidato e o disco de dados ainda não estiver pronto).
PROGRAMAS=(
  "CMD_GIT|git|base" "CMD_SSH|openssh-client|base" "CMD_SSH_KEYSCAN|openssh-client|base"
  "CMD_SSH_KEYGEN|openssh-client|base" "CMD_LSBLK|util-linux|base" "CMD_WIPEFS|util-linux|base"
  "CMD_BLKID|util-linux|base" "CMD_FINDMNT|util-linux|base" "CMD_MOUNT|util-linux|base"
  "CMD_TIMEOUT|coreutils|base" "realpath|coreutils|base" "stat|coreutils|base"
  "awk|mawk ou gawk|base" "sed|sed|base"
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
      item falta "programa '$cmd' ausente (instale o pacote: $pacote)"
      faltando=1
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
  local dev="$1" n=0 mp wf
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
  return 1
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
  local f ncand
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
  saida "== 2. Disco de dados em $OPT_DIR (opcional) =="
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
      item falta "a chave de deploy ainda não lê o repositório (cadastrada no GitHub?)"
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
  saida "== 3. Chave de deploy do GitHub (somente leitura) =="
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
  codigo_estado
  case "$CODIGO_ESTADO" in
    ausente) item falta "código do produto ausente ($NB_DIR)" ;;
    ok) item ok "código do produto em $NB_DIR: $(codigo_commit)" ;;
    *) item falta "$CODIGO_MOTIVO" ;;
  esac
}

etapa_codigo_run() {
  local livre
  saida "== 4. Código do produto =="
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
# ETAPA 5 - RELATÓRIO FINAL (deploy.sh --check, só leitura, com trava)
# =============================================================================
deploy_check() { # roda "deploy.sh --check" depois de conferir a confiança
  local real nbreal out rc
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
  saida "deploy.sh --check terminou com código $rc (falta de configuração é esperada nesta fase)."
  return 0
}

check_relatorio() {
  if [ "$CHECK_REMOTE" != 1 ]; then return 0; fi
  codigo_estado
  if [ "$CODIGO_ESTADO" != "ok" ]; then item falta "deploy.sh --check não executado (código ausente)"; return 0; fi
  if confia "$(realpath -m -- "$DEPLOY_SH")"; then
    item ok "deploy.sh confiável (root, sem escrita para grupo/outros)"
  else
    item falta "deploy.sh NÃO será executado: $MSG_CONFIANCA"
    return 0
  fi
  deploy_check || item falta "deploy.sh --check não pôde ser executado"
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
    disco) echo "Disco de dados em $OPT_DIR" ;;
    chave) echo "Chave de deploy do GitHub" ;;
    codigo) echo "Código do produto" ;;
    relatorio) echo "Relatório (deploy.sh --check)" ;;
    *) echo "$1" ;;
  esac
}

etapa_relatorio_run() {
  saida "== 5. Relatório =="
  deploy_check || RC_FINAL=1
  saida ""
  resumo_etapas
  saida ""
  saida "O que foi feito: pré-checagem, disco de dados (se escolhido), chave de deploy somente leitura e código em $NB_DIR."
  saida "O que falta (Fase 3b): configuração (domínio, redes do painel, fuso, portas), deploy, certificado, firewall e usuário administrador."
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

modo_executar() {
  local e
  local base n=1
  [ -d "$LOG_DIR" ] || die "pasta do log inexistente: $LOG_DIR"
  base="$LOG_DIR/netbackup-instalacao-$(date +%Y%m%d_%H%M%S)"
  LOG_FILE="$base.log"
  while [ -e "$LOG_FILE" ]; do n=$((n + 1)); LOG_FILE="${base}_$n.log"; done
  ( umask 077; : >"$LOG_FILE" ) || die "não foi possível criar o log em $LOG_FILE"
  chmod 600 -- "$LOG_FILE"
  registra "NetBackup Instalador versão $VERSAO (modo executar)"
  saida "Log: $LOG_FILE"
  export GIT_PAGER=cat GIT_TERMINAL_PROMPT=0
  GIT_SSH_COMMAND="$(git_ssh_cmd)"; export GIT_SSH_COMMAND
  for e in "${ETAPAS[@]}"; do
    "etapa_${e}_run"
  done
  return "$RC_FINAL"
}

uso() {
  cat <<EOF
Uso: sudo bash instalar.sh [opção]

  (sem opção)   executa a preparação da VM (pré-checagem, disco opcional,
                chave de deploy, código do produto); pode ser repetido
  --check       só leitura: informa ok/falta por item, não altera nada
  --status      só leitura: resumo do que está pronto (sem rede)
  -h, --help    esta ajuda

Software proprietário, uso sob licença.
EOF
}

main() {
  case "${1:-}" in
    "") MODO="executar" ;;
    --check) MODO="check" ;;
    --status) MODO="status" ;;
    -h|--help) MODO="ajuda" ;;
    *) printf 'NetBackup Instalador versão %s\n' "$VERSAO"
       printf 'ERRO: opção desconhecida: %s\n' "$1" >&2; uso >&2; exit 2 ;;
  esac
  [ "$#" -le 1 ] || { printf 'ERRO: argumentos demais.\n' >&2; exit 2; }

  printf 'NetBackup Instalador versão %s\n' "$VERSAO"
  if [ "$MODO" = "ajuda" ]; then uso; exit 0; fi

  exige_root
  exige_instalador_confiavel

  case "$MODO" in
    check) modo_check; exit $? ;;
    status) modo_status; exit $? ;;
    executar) modo_executar; exit $? ;;
  esac
}

main "$@"
