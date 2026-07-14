#!/usr/bin/env zsh
# ============================================================================
#  frotadiag.sh · Ecossistema Coelho — diagnóstico canônico único
#  Operador: Dr. Matheus M. Coelho · rev 2.3 · jul 2026
# ----------------------------------------------------------------------------
#  Um script, um repositório (drmcoelho/FrotaDiag), roda idêntico em
#  qualquer Mac. Substitui frota-diag.sh + disk-triage.sh + zshrc-audit.sh.
#
#  SUBCOMANDOS
#    diag [--full]        → saúde da máquina (padrão). Leitura pura.
#    disk [scan|clean]    → espaço em disco. scan=leitura; clean=guiada.
#    zshrc                → censo de dotfiles, segredos SEMPRE redigidos.
#    provision [--yes]    → instala ferramentas ausentes, if-not, perguntando.
#    fleet                → rollup de todos os hosts (lê latest.json no iCloud).
#    schedule [install|uninstall|status] → LaunchAgent nightly de diag.
#    all                  → diag + disk scan + zshrc num relatório único.
#    help
#
#  DOUTRINA
#    · Tudo que só LÊ roda sem perguntar. Tudo que MUTA pergunta antes,
#      subcomando por subcomando, categoria por categoria.
#    · Uma camada que falha não derruba as outras (run_layer isola erro).
#    · Segredo nunca sai em claro em nenhum relatório, nunca.
#    · Saída: terminal colorido + JSON + Markdown em
#        ~/Library/Mobile Documents/com~apple~CloudDocs/FrotaDiag/<host>/
#      com fallback para ~/.local/state/frotadiag/ se iCloud falhar.
# ============================================================================

umask 022

SCRIPT_VERSION="2.3"
# CHANGELOG 2.2→2.3 (frota de verdade — coleta vira sistema que se reporta):
#  A. [fleet] Novo subcomando que lê todos os <host>/latest.json sob ICLOUD_BASE
#     e imprime rollup (veredito, disco, TM, versão do script, staleness por
#     mtime do arquivo). Exit code espelha o contrato do diag: 2 se algum host
#     BAD, 1 se algum WARN. Diretório próprio (_fleet/) fica fora do glob.
#  B. [diff] cmd_diag agora compara o latest.json ANTERIOR com o atual por
#     TRANSIÇÃO DE STATUS por chave (OK→WARN→BAD), determinístico e auditável —
#     nunca por parsing de valores tipo "120h atrás". Primeira execução (sem
#     latest.json) é no-op. Delta vai para terminal e para o Markdown.
#  C. [notify] Notificação dispara SÓ nas chaves que viraram BAD desde a última
#     execução (o conjunto de transição do diff), não em N_BAD>0 — evita
#     re-alarme de BAD persistente (fadiga de alarme). Canal: banner osascript
#     (local) + push opcional via FROTADIAG_NTFY_URL (cobre estar longe da
#     máquina). Silenciável com FROTADIAG_NO_NOTIFY=1.
#  D. [schedule] install|uninstall|status planta/remove um LaunchAgent nightly
#     de diag. install/uninstall MUTAM (plist + launchctl) → confirm() sempre,
#     mesmo tier de disk clean. PATH do plist inclui /opt/homebrew/bin senão
#     jq/smartctl não resolvem sob o agente e o diff quebra silenciosamente.
# CHANGELOG 2.1→2.2 (segunda revisão externa):
#  1. [DISCORDÂNCIA REGISTRADA] Reviewer apontou contradição entre o comentário
#     "disk clean NUNCA herda --yes" e o código, que de fato bypassa SEGURO.
#     A contradição é real, mas o comentário estava errado, não o código:
#     o desenho original (disk-triage.sh, doc de origem) sempre foi
#     "--yes aceita só SEGURO; REVISAR/DESTRUTIVO sempre perguntam,
#     com ou sem --yes" — testado e correto. Corrigido o comentário,
#     mantida a funcionalidade.
#  2. grep -c sem fallback: o mecanismo citado (pipefail derruba a camada)
#     não se sustenta — toda layer_*/scan_zsh_file termina em `return 0`
#     explícito, que isola o exit code intermediário. O risco real e mais
#     estreito é arquivo existente porém ILEGÍVEL (permissão), onde grep
#     em alguma variante de shell pode não emitir nem "0". `|| print 0`
#     é blindagem barata para esse caso; aplicado nos 4 pontos sem fallback.
#  3. redact(): removida também a contagem de caracteres — nome da variável
#     já discrimina o tipo do segredo; comprimento exato era metadado
#     supérfluo e podia ajudar fingerprint do provedor.
#  4. SECRET_VAL_RE endurecido com comprimento mínimo: testado — eliminava
#     falso-positivo real em "desk-analysis", "risk-averse", "flask-app",
#     "task-array" (todos continham "sk-"/prefixos + 1 char, batendo o
#     regex antigo) sem perder detecção dos formatos reais (sk-ant-*,
#     ghp_*, hf_*, AKIA*). AJUSTE FINAL (3ª revisão): limiar de "sk-"
#     subido de 10 para 20 chars — faixa 10–19 ainda deixava passar slugs
#     de tamanho médio ("backup-desk-configuration"); testado, corrigido,
#     chaves reais (Anthropic/OpenAI, 40+ chars) seguem detectadas sem
#     margem alguma de risco.
#  5. provision_one: comentário explícito sobre o uso de eval (necessário
#     pelos comandos com pipe/expansão; aceito como está).
#  7. open Archives: guarda de diretório inexistente com mensagem amigável.
#  8. cmd_all: `|| true` após cmd_diag para não propagar seu exit code
#     não-zero (1/2 por design) numa composição futura com set -e.
emulate -L zsh
setopt pipefail null_glob
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
TS="$(date +%Y%m%d_%H%M%S)"
TS_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"

ICLOUD_BASE="${ICLOUD_BASE:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/FrotaDiag}"
OUT_DIR="$ICLOUD_BASE/$HOST"
STATE_DIR="$HOME/.local/state/frotadiag"
LOG_FILE="$STATE_DIR/frotadiag.log"
mkdir -p "$STATE_DIR"

SCRIPT_PATH="${0:A}"                       # caminho canônico deste arquivo (p/ launchd)
LAUNCH_LABEL="com.coelho.frotadiag"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"

if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_BAD=$'\e[31m'
  C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_BAD=""; C_DIM=""; C_B=""; C_0=""
fi

log() { print -r -- "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"; s="${s//$'\t'/ }"
  print -rn -- "$s"
}

md_escape() {  # escapa pipe e quebra de linha p/ não estourar tabela Markdown
  local s="$1"
  s="${s//|/\\|}"
  s="${s//$'\n'/ }"
  print -rn -- "$s"
}

resolve_out_dir() {
  mkdir -p "$OUT_DIR" 2>/dev/null && return 0
  OUT_DIR="$STATE_DIR/reports/$HOST"; mkdir -p "$OUT_DIR"
  print -- "${C_WARN}▲ iCloud Drive inacessível — relatórios em $OUT_DIR${C_0}"
  log "WARN iCloud indisponivel; fallback $OUT_DIR"
}

# ============================================================== DIAG (saúde)

typeset -a JSON_FIELDS MD_LINES
typeset -i N_OK=0 N_WARN=0 N_BAD=0

emit() {  # emit <OK|WARN|BAD|INFO> <chave> <valor> <label>
  local st="$1" key="$2" val="$3" label="$4" color icon
  case "$st" in
    OK)   color="$C_OK";   icon="●"; (( N_OK++ ));;
    WARN) color="$C_WARN"; icon="▲"; (( N_WARN++ ));;
    BAD)  color="$C_BAD";  icon="✖"; (( N_BAD++ ));;
    *)    color="$C_DIM";  icon="·";;
  esac
  printf "  %s%s%s %-26s %s\n" "$color" "$icon" "$C_0" "$label" "$val"
  JSON_FIELDS+=("\"$key\": {\"status\": \"$st\", \"value\": \"$(json_escape "$val")\"}")
  MD_LINES+=("| $icon | $(md_escape "$label") | $(md_escape "$val") |")
  log "$st $key = $val"
}

section() {
  print -- "\n${C_B}── $1 ──${C_0}"
  MD_LINES+=("" "### $1" "" "| | item | valor |" "|---|---|---|")
}

run_layer() {
  local name="$1" fn="$2"
  if ! "$fn" 2>>"$LOG_FILE"; then
    emit BAD "layer_${name}_error" "camada falhou (ver log)" "$name"
  fi
}

layer_identidade() {
  section "Identidade"
  local model chip osver build
  model="$(sysctl -n hw.model 2>/dev/null)"                 || model="indisponivel"
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"  || chip="indisponivel"
  osver="$(sw_vers -productVersion 2>/dev/null)"            || osver="indisponivel"
  build="$(sw_vers -buildVersion 2>/dev/null)"               || build=""
  emit INFO host   "$HOST"            "hostname"
  emit INFO modelo "$model"           "modelo"
  emit INFO chip   "$chip"            "chip"
  emit INFO macos  "$osver ($build)"  "macOS"

  local boot now up_s up_d
  boot="$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*{ sec = \([0-9]*\),.*/\1/')"
  now="$(date +%s)"
  if [[ -n "$boot" && "$boot" == <-> ]]; then
    up_s=$(( now - boot )); up_d=$(( up_s / 86400 ))
    if (( up_d >= 30 )); then emit WARN uptime "${up_d}d (>=30d: considerar reboot)" "uptime"
    else                      emit OK   uptime "${up_d}d" "uptime"
    fi
  else
    emit WARN uptime "indisponivel" "uptime"
  fi
  return 0
}

layer_memoria() {
  section "Memória"
  local ram free_pct
  ram="$(( $(sysctl -n hw.memsize 2>/dev/null || print 0) / 1073741824 )) GB"
  emit INFO ram_total "$ram" "RAM instalada"
  free_pct="$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {gsub(/%/,"",$2); print $2}')"
  if [[ -n "$free_pct" ]]; then
    if   (( free_pct >= 40 )); then emit OK   mem_livre "${free_pct}%" "memória livre"
    elif (( free_pct >= 20 )); then emit WARN mem_livre "${free_pct}% (pressão moderada)" "memória livre"
    else                            emit BAD  mem_livre "${free_pct}% (pressão alta)" "memória livre"
    fi
  else
    emit WARN mem_livre "indisponivel" "memória livre"
  fi
  return 0
}

layer_disco_saude() {
  section "Disco"
  local line cap used avail pctuse
  # mede o volume Data (onde o uso real mora), não o snapshot selado do Sistema
  line="$(df -H /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $2" "$3" "$4" "$5}')"
  [[ -z "$line" ]] && line="$(df -H / 2>/dev/null | awk 'NR==2 {print $2" "$3" "$4" "$5}')"
  if [[ -n "$line" ]]; then
    read -r cap used avail pctuse <<< "$line"
    local pct="${pctuse%\%}"
    if   (( pct <= 80 )); then emit OK   disco_uso "$used / $cap usados · $avail livres ($pctuse)" "uso do disco"
    elif (( pct <= 90 )); then emit WARN disco_uso "$used / $cap · $avail livres ($pctuse)" "uso do disco"
    else                       emit BAD  disco_uso "$used / $cap · $avail livres ($pctuse) — crítico" "uso do disco"
    fi
  else
    emit WARN disco_uso "indisponivel" "uso do disco"
  fi

  local smart_du
  smart_du="$(diskutil info disk0 2>/dev/null | awk -F': *' '/SMART Status/ {print $2}' | xargs)"
  case "$smart_du" in
    Verified)         emit OK   smart_diskutil "Verified" "SMART (diskutil)";;
    "")               emit WARN smart_diskutil "indisponivel" "SMART (diskutil)";;
    "Not Supported")  emit INFO smart_diskutil "Not Supported (normal em alguns NVMe)" "SMART (diskutil)";;
    *)                emit BAD  smart_diskutil "$smart_du" "SMART (diskutil)";;
  esac

  if command -v smartctl >/dev/null 2>&1; then
    local health wear
    health="$(smartctl -H /dev/disk0 2>/dev/null | awk -F': *' '/overall-health/ {print $2}')"
    wear="$(smartctl -a /dev/disk0 2>/dev/null | awk -F': *' '/Percentage Used/ {print $2; exit}')"
    if [[ -n "$health" ]]; then
      [[ "$health" == "PASSED" ]] && emit OK  smart_health "PASSED${wear:+ · desgaste $wear}" "SMART (smartctl)" \
                                   || emit BAD smart_health "$health" "SMART (smartctl)"
    else
      emit INFO smart_health "sem leitura (pode exigir sudo)" "SMART (smartctl)"
    fi
  else
    emit INFO smartctl_presente "ausente — 'provision' instala" "smartmontools"
  fi
  return 0
}

layer_energia_termico() {
  section "Energia e térmico"
  local therm cpu_lim
  therm="$(pmset -g therm 2>/dev/null)"
  cpu_lim="$(print -r -- "$therm" | awk -F'= *' '/CPU_Speed_Limit/ {print $2}' | xargs)"
  if [[ -n "$cpu_lim" ]]; then
    if (( cpu_lim >= 100 )); then emit OK therm "sem throttling (CPU limit ${cpu_lim}%)" "térmico"
    else                          emit WARN therm "THROTTLING ativo — CPU limitada a ${cpu_lim}%" "térmico"
    fi
  else
    emit INFO therm "sem dado de limite (normal em alguns Apple Silicon)" "térmico"
  fi

  local batt
  batt="$(pmset -g batt 2>/dev/null | awk -F'\t' '/InternalBattery/ {print $2}' | cut -d';' -f1,2 | xargs)"
  if [[ -n "$batt" ]]; then
    emit INFO bateria "$batt" "bateria"
    local cyc
    cyc="$(system_profiler SPPowerDataType 2>/dev/null | awk -F': *' '/Cycle Count/ {print $2; exit}')"
    [[ -n "$cyc" ]] && emit INFO ciclos "$cyc ciclos" "ciclos de bateria"
  else
    emit INFO bateria "sem bateria (desktop)" "bateria"
  fi

  local slp
  slp="$(pmset -g 2>/dev/null | awk '$1=="sleep" {print $2; exit}')"
  [[ -n "$slp" ]] && emit INFO sleep_cfg "sleep=${slp} (0 = nunca dorme)" "config de sleep"
  return 0
}

layer_timemachine() {
  section "Time Machine"
  local dest last stamp epoch now age_h
  dest="$(tmutil destinationinfo 2>/dev/null | awk -F': *' '/^Name/ {print $2; exit}')"
  if [[ -z "$dest" ]]; then
    emit WARN tm_destino "nenhum destino configurado" "destino TM"
    return 0
  fi
  emit INFO tm_destino "$dest" "destino TM"
  last="$(tmutil latestbackup 2>/dev/null | tail -1)"
  if [[ -z "$last" || "$last" == *"No machine directory"* ]]; then
    emit WARN tm_ultimo "sem backup localizável (Terminal precisa de Acesso Total ao Disco?)" "último backup"
    return 0
  fi
  stamp="$(basename "$last" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}')"
  if [[ -n "$stamp" ]]; then
    epoch="$(date -j -f '%Y-%m-%d-%H%M%S' "$stamp" +%s 2>/dev/null)"
    now="$(date +%s)"
    if [[ -n "$epoch" ]]; then
      age_h=$(( (now - epoch) / 3600 ))
      if   (( age_h <= 26 ));  then emit OK   tm_idade "${age_h}h atrás" "último backup"
      elif (( age_h <= 168 )); then emit WARN tm_idade "${age_h}h atrás (>1 dia)" "último backup"
      else                          emit BAD  tm_idade "$(( age_h / 24 ))d atrás — cofre defasado" "último backup"
      fi
      return 0
    fi
  fi
  emit INFO tm_idade "$last" "último backup"
  return 0
}

layer_seguranca_rede() {
  section "Segurança e malha"
  local fv ssh_on ts_bin ts_st
  fv="$(fdesetup status 2>/dev/null)"
  [[ "$fv" == *"On"* ]] && emit OK filevault "ativo" "FileVault" \
                        || emit WARN filevault "${fv:-indisponivel}" "FileVault"

  ssh_on="$(systemsetup -getremotelogin 2>/dev/null | awk -F': *' '{print $2}')"
  if [[ "$ssh_on" != On && "$ssh_on" != Off ]]; then
    if nc -z -G 1 localhost 22 >/dev/null 2>&1; then ssh_on="On (porta 22)"
    else ssh_on="Off (porta 22 fechada)"; fi
  fi
  case "$ssh_on" in
    On*)  emit OK   ssh "ativo ${ssh_on#On}" "Login Remoto (SSH)";;
    Off*) emit WARN ssh "desligado — coleta remota precisa dele" "Login Remoto (SSH)";;
    *)    emit INFO ssh "indeterminado" "Login Remoto (SSH)";;
  esac

  ts_bin="$(command -v tailscale 2>/dev/null)"
  [[ -z "$ts_bin" && -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]] \
    && ts_bin="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  if [[ -n "$ts_bin" ]]; then
    ts_st="$("$ts_bin" status --peers=false 2>/dev/null | head -1)"
    if [[ -z "$ts_st" ]]; then
      emit WARN tailscale "instalado, sem status" "Tailscale"
    elif print -r -- "$ts_st" | grep -qiE 'logged out|stopped|needslogin'; then
      emit WARN tailscale "$ts_st — malha fora; logar no app" "Tailscale"
    else
      emit OK tailscale "$ts_st" "Tailscale"
    fi
  else
    emit WARN tailscale "ausente" "Tailscale"
  fi
  return 0
}

layer_agentes() {
  section "LaunchAgents (não-Apple)"
  local agents n
  agents="$(launchctl list 2>/dev/null | awk 'NR>1 && $3 !~ /^com\.apple\./ {print $3}' | sort)"
  n="$(print -r -- "$agents" | grep -c . 2>/dev/null)"; n="${n:-0}"
  emit INFO agentes_n "$n agentes de terceiros carregados" "total"
  print -r -- "$agents" | head -12 | while IFS= read -r a; do
    [[ -n "$a" ]] && printf "    %s%s%s\n" "$C_DIM" "$a" "$C_0" && MD_LINES+=("| · | agente | \`$a\` |")
  done
  return 0
}

layer_inventario() {
  section "Inventário de ferramentas"
  local -a tools=(brew git python3 node claude smartctl jq tmux mosh ollama gh)
  local t p v
  for t in "${tools[@]}"; do
    p="$(command -v "$t" 2>/dev/null)"
    if [[ -n "$p" ]]; then
      case "$t" in
        brew)    v="$(brew --version 2>/dev/null | head -1)";;
        claude)  v="$(claude --version 2>/dev/null | head -1)";;
        python3) v="$(python3 --version 2>/dev/null)";;
        node)    v="$(node --version 2>/dev/null)";;
        gh)      v="$(gh --version 2>/dev/null | head -1)";;
        *)       v="presente";;
      esac
      emit OK "tool_$t" "${v:-presente} ($p)" "$t"
    else
      emit WARN "tool_$t" "ausente" "$t"
    fi
  done
  return 0
}

layer_updates() {
  section "Atualizações do sistema (--full)"
  local out
  out="$(softwareupdate -l 2>&1)"
  if print -r -- "$out" | grep -q "No new software available"; then
    emit OK sw_update "sistema em dia" "softwareupdate"
  elif print -r -- "$out" | grep -q "Label:"; then
    local n; n="$(print -r -- "$out" | grep -c 'Label:')"; n="${n:-0}"
    emit WARN sw_update "$n atualização(ões) pendente(s)" "softwareupdate"
  else
    emit INFO sw_update "sem resposta conclusiva (rede?)" "softwareupdate"
  fi
  return 0
}

# --- diff temporal + notificação (ambos só LEEM/emitem → não perguntam) -------

_rank() { case "$1" in BAD) print 3;; WARN) print 2;; *) print 1;; esac }  # OK=INFO=1

notify() {  # notify <titulo> <mensagem>. Banner local + push opcional. Nunca falha a camada.
  [[ "${FROTADIAG_NO_NOTIFY:-0}" == 1 ]] && return 0
  local title="$1" msg="$2"
  osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1
  [[ -n "${FROTADIAG_NTFY_URL:-}" ]] && curl -fsS -m 5 -H "Title: $title" -d "$msg" "$FROTADIAG_NTFY_URL" >/dev/null 2>&1
  log "notify: $title — $msg"
  return 0
}

# diff_and_flag <json_anterior> <json_atual>
#   Compara status por chave (transição), imprime delta, anexa ao Markdown e
#   preenche o global NEW_BAD_KEYS com as chaves que VIRARAM BAD (p/ notify).
diff_and_flag() {
  typeset -ga NEW_BAD_KEYS=()
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$1" ]] || return 0                 # primeira execução: sem anterior, no-op
  typeset -A olds
  local key st old
  while IFS=$'\t' read -r key st; do
    [[ -n "$key" ]] && olds[$key]="$st"
  done < <(jq -r '.camadas|to_entries[]|"\(.key)\t\(.value.status)"' "$1" 2>/dev/null)
  typeset -a reg imp
  while IFS=$'\t' read -r key st; do
    [[ -z "$key" ]] && continue
    old="${olds[$key]:-}"
    if [[ -z "$old" ]]; then                # chave nova: só reporta se preocupante
      if [[ "$st" == BAD || "$st" == WARN ]]; then
        reg+=("$key: novo → $st")
        [[ "$st" == BAD ]] && NEW_BAD_KEYS+=("$key$(_val_of "$2" "$key")")
      fi
      continue
    fi
    [[ "$st" == "$old" ]] && continue
    if (( $(_rank "$st") > $(_rank "$old") )); then
      reg+=("$key: $old → $st")
      [[ "$st" == BAD && "$old" != BAD ]] && NEW_BAD_KEYS+=("$key$(_val_of "$2" "$key")")
    elif (( $(_rank "$st") < $(_rank "$old") )); then
      imp+=("$key: $old → $st")
    fi
  done < <(jq -r '.camadas|to_entries[]|"\(.key)\t\(.value.status)"' "$2" 2>/dev/null)

  (( ${#reg} + ${#imp} == 0 )) && return 0
  print -- "\n${C_B}── Mudanças desde a última execução ──${C_0}"
  MD_LINES+=("" "### Mudanças desde a última execução" "")
  local l
  for l in "${reg[@]}"; do print -- "  ${C_BAD}▼${C_0} $l"; MD_LINES+=("- ▼ $(md_escape "$l")"); done
  for l in "${imp[@]}"; do print -- "  ${C_OK}▲${C_0} $l"; MD_LINES+=("- ▲ $(md_escape "$l")"); done
  return 0
}

_val_of() {  # " (valor)" da chave no json, ou vazio
  local v; v="$(jq -r ".camadas[\"$2\"].value // \"\"" "$1" 2>/dev/null)"
  [[ -n "$v" ]] && print -rn -- " ($v)"
}

write_diag_reports() {
  resolve_out_dir
  local json_path="$OUT_DIR/diag_${TS}.json"
  local md_path="$OUT_DIR/relatorio_${TS}.md"

  {
    print -r -- "{"
    print -r -- "  \"schema\": \"frotadiag/v2\","
    print -r -- "  \"host\": \"$(json_escape "$HOST")\","
    print -r -- "  \"timestamp\": \"$TS_ISO\","
    print -r -- "  \"script_version\": \"$SCRIPT_VERSION\","
    print -r -- "  \"resumo\": {\"ok\": $N_OK, \"warn\": $N_WARN, \"bad\": $N_BAD},"
    print -r -- "  \"camadas\": {"
    local i last=$(( ${#JSON_FIELDS[@]} ))
    for (( i=1; i<=last; i++ )); do
      print -rn -- "    ${JSON_FIELDS[$i]}"
      (( i < last )) && print -r -- "," || print -r -- ""
    done
    print -r -- "  }"
    print -r -- "}"
  } > "$json_path"
  diff_and_flag "$OUT_DIR/latest.json" "$json_path"   # lê o latest ANTERIOR antes de sobrescrever
  cp -f "$json_path" "$OUT_DIR/latest.json"

  {
    print -r -- "# Diagnóstico · $HOST"
    print -r -- ""
    print -r -- "**Quando:** $TS_ISO · **script** v$SCRIPT_VERSION"
    print -r -- ""
    print -r -- "**Resumo:** ● $N_OK ok · ▲ $N_WARN atenção · ✖ $N_BAD críticos"
    for l in "${MD_LINES[@]}"; do print -r -- "$l"; done
  } > "$md_path"
  cp -f "$md_path" "$OUT_DIR/latest.md"

  print -- "\n${C_B}Relatórios:${C_0}"
  print -- "  JSON  $json_path"
  print -- "  MD    $md_path"
}

cmd_diag() {
  local full=0
  [[ "${1:-}" == "--full" ]] && full=1
  log "=== diag start host=$HOST full=$full ==="
  print -- "${C_B}frotadiag v$SCRIPT_VERSION · $HOST · $(date '+%d/%m/%Y %H:%M')${C_0}"

  run_layer identidade       layer_identidade
  run_layer memoria          layer_memoria
  run_layer disco            layer_disco_saude
  run_layer energia_termico  layer_energia_termico
  run_layer timemachine      layer_timemachine
  run_layer seguranca_rede   layer_seguranca_rede
  run_layer agentes          layer_agentes
  run_layer inventario       layer_inventario
  (( full )) && run_layer updates layer_updates

  print -- "\n${C_B}RESUMO:${C_0} ${C_OK}● $N_OK ok${C_0} · ${C_WARN}▲ $N_WARN atenção${C_0} · ${C_BAD}✖ $N_BAD críticos${C_0}"
  write_diag_reports
  if (( ${#NEW_BAD_KEYS[@]} > 0 )); then
    # título ASCII de propósito: vira header HTTP 'Title:' no push ntfy, onde
    # bytes não-ASCII (ex.: ✖) são obs-text e podem ser rejeitados/manglados
    # por proxies — mataria o canal que justamente cobre "longe da máquina".
    # O detalhe (com acento/símbolo) vai no corpo, que é UTF-8 e seguro.
    notify "frotadiag BAD: $HOST" "novos criticos: ${(j:; :)NEW_BAD_KEYS}"
  fi
  log "=== diag end ok=$N_OK warn=$N_WARN bad=$N_BAD ==="
  (( N_BAD  > 0 )) && return 2
  (( N_WARN > 0 )) && return 1
  return 0
}

# =========================================================== DISK (espaço)

bytes_of() {
  local p="$1"
  [[ -e "$p" ]] || { print 0; return; }
  local kb; kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
  print $(( ${kb:-0} * 1024 ))
}

human_bytes() {
  local b=$1
  if   (( b >= 1073741824 )); then printf "%.1f GB" $(( b / 1073741824.0 ))
  elif (( b >= 1048576 ));    then printf "%.0f MB" $(( b / 1048576.0 ))
  else                             printf "%d KB" $(( b / 1024 ))
  fi
}

data_free() {
  local out
  out="$(df -H /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4" livres de "$2" ("$5" usado)"}')"
  print -r -- "${out:-indisponivel}"
}

typeset -A CAT_BYTES CAT_DESC CAT_RISK

measure_disk_categories() {
  local b=0
  b=$(( $(bytes_of "$HOME/Library/Developer/CoreSimulator") + $(bytes_of "/Library/Developer/CoreSimulator/Volumes") ))
  CAT_BYTES[simuladores]=$b;              CAT_DESC[simuladores]="Simuladores iOS (runtimes + devices)";               CAT_RISK[simuladores]="DESTRUTIVO"
  CAT_BYTES[deriveddata]=$(bytes_of "$HOME/Library/Developer/Xcode/DerivedData")
  CAT_DESC[deriveddata]="Xcode DerivedData (builds intermediários)"; CAT_RISK[deriveddata]="SEGURO"
  b=$(( $(bytes_of "$HOME/Library/Developer/Xcode/iOS DeviceSupport") + $(bytes_of "$HOME/Library/Developer/Xcode/watchOS DeviceSupport") ))
  CAT_BYTES[devicesupport]=$b;            CAT_DESC[devicesupport]="Xcode DeviceSupport (símbolos de iOS antigos)";    CAT_RISK[devicesupport]="SEGURO"
  CAT_BYTES[xcodearchives]=$(bytes_of "$HOME/Library/Developer/Xcode/Archives")
  CAT_DESC[xcodearchives]="Xcode Archives (builds arquivados)";      CAT_RISK[xcodearchives]="REVISAR"
  if command -v brew >/dev/null 2>&1; then CAT_BYTES[brewcache]=$(bytes_of "$(brew --cache 2>/dev/null)")
  else CAT_BYTES[brewcache]=0; fi
  CAT_DESC[brewcache]="Cache do Homebrew";                            CAT_RISK[brewcache]="SEGURO"
  CAT_BYTES[usercaches]=$(bytes_of "$HOME/Library/Caches")
  CAT_DESC[usercaches]="~/Library/Caches";                            CAT_RISK[usercaches]="SEGURO"
  CAT_BYTES[userlogs]=$(bytes_of "$HOME/Library/Logs")
  CAT_DESC[userlogs]="~/Library/Logs";                                CAT_RISK[userlogs]="SEGURO"
  CAT_BYTES[trash]=$(bytes_of "$HOME/.Trash")
  CAT_DESC[trash]="Lixeira";                                          CAT_RISK[trash]="REVISAR"
  CAT_BYTES[ollama]=$(bytes_of "$HOME/.ollama/models")
  CAT_DESC[ollama]="Modelos Ollama";                                  CAT_RISK[ollama]="DESTRUTIVO"
  local snaps; snaps="$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine')"; snaps="${snaps:-0}"
  CAT_BYTES[tmsnapshots]=-1
  CAT_DESC[tmsnapshots]="Snapshots locais TM (${snaps:-0} — 'purgeable')"; CAT_RISK[tmsnapshots]="REVISAR"
}

cmd_disk_scan() {
  print -- "${C_B}disk scan · $HOST${C_0} · Volume Data: $(data_free)\n"
  print -- "${C_DIM}Medindo (du pode levar ~1 min)...${C_0}\n"
  measure_disk_categories
  local total=0 k
  for k in ${(k)CAT_BYTES}; do (( CAT_BYTES[$k] > 0 )) && total=$(( total + CAT_BYTES[$k] )); done
  printf "  %-10s %-46s %10s\n" "RISCO" "CATEGORIA" "TAMANHO"
  printf "  %s\n" "$(printf '─%.0s' {1..70})"
  for k in ${(k)CAT_BYTES}; do print -r -- "${CAT_BYTES[$k]} $k"; done | sort -rn | while read -r b k; do
    (( b == 0 )) && continue
    local risk="${CAT_RISK[$k]}"; local color=""
    case "$risk" in SEGURO) color="$C_OK";; REVISAR) color="$C_WARN";; DESTRUTIVO) color="$C_BAD";; esac
    if (( b < 0 )); then printf "  %s%-10s%s %-46s %10s\n" "$color" "$risk" "$C_0" "${CAT_DESC[$k]}" "n/d"
    else                 printf "  %s%-10s%s %-46s %10s\n" "$color" "$risk" "$C_0" "${CAT_DESC[$k]}" "$(human_bytes $b)"
    fi
  done
  print -- "\n  ${C_B}Recuperável somando tudo: ~$(human_bytes $total)${C_0}"
  print -- "\nPróximo passo: ${C_B}./frotadiag.sh disk clean${C_0}"
}

confirm() { local ans; read -r "ans?  → $1 [s/N] "; [[ "$ans" == [sSyY]* ]]; }
# confirm_auto: só o 'provision' pode pular pergunta com --yes.
# disk clean também aceita --yes, mas por desenho ele só dispensa
# a pergunta OUTER de categorias SEGURO (ver clean_category); REVISAR e
# DESTRUTIVO sempre caem em confirm() puro, nunca em confirm_auto() —
# --yes não os alcança em nenhuma hipótese.
confirm_auto() { (( ${AUTO_YES:-0} == 1 )) && return 0; confirm "$1"; }

clean_category() {
  local k="$1" b="${CAT_BYTES[$k]}" risk="${CAT_RISK[$k]}"
  (( b == 0 )) && return 0
  local size_h; (( b > 0 )) && size_h="$(human_bytes $b)" || size_h="n/d"
  print -- "\n${C_B}${CAT_DESC[$k]}${C_0} — $size_h [${risk}]"
  local go=0
  if [[ "$risk" == "SEGURO" && $AUTO_YES == 1 ]]; then go=1
  elif confirm "limpar esta categoria?"; then go=1; fi
  (( go )) || { print -- "    ${C_DIM}pulado${C_0}"; return 0; }

  case "$k" in
    simuladores)
      xcrun simctl delete unavailable 2>>"$LOG_FILE"
      print -- "    ${C_DIM}Runtimes instalados:${C_0}"; xcrun simctl runtime list 2>/dev/null
      print -- "    Remover: ${C_B}xcrun simctl runtime delete <identifier>${C_0}"
      ;;
    deriveddata)     rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/* 2>>"$LOG_FILE"; print -- "    ${C_OK}limpo${C_0}";;
    devicesupport)   rm -rf "$HOME/Library/Developer/Xcode/iOS DeviceSupport"/* "$HOME/Library/Developer/Xcode/watchOS DeviceSupport"/* 2>>"$LOG_FILE"; print -- "    ${C_OK}limpo${C_0}";;
    xcodearchives)
      local arch_dir="$HOME/Library/Developer/Xcode/Archives"
      if [[ -d "$arch_dir" ]]; then
        open "$arch_dir" 2>/dev/null
        print -- "    ${C_DIM}Finder aberto — revise manualmente${C_0}"
      else
        print -- "    ${C_DIM}Nenhum archive encontrado ainda (pasta não existe)${C_0}"
      fi
      ;;
    brewcache)       brew cleanup --prune=all 2>>"$LOG_FILE" | tail -1; print -- "    ${C_OK}limpo${C_0}";;
    usercaches)
      du -sk "$HOME/Library/Caches"/* 2>/dev/null | sort -rn | head -8 | awk '{printf "      %6.1f MB  %s\n", $1/1024, $2}'
      confirm "apagar TODO o ~/Library/Caches?" && { rm -rf "$HOME/Library/Caches"/* 2>>"$LOG_FILE"; print -- "    ${C_OK}limpo${C_0}"; }
      ;;
    userlogs) rm -rf "$HOME/Library/Logs"/* 2>>"$LOG_FILE"; print -- "    ${C_OK}limpo${C_0}";;
    trash)    confirm "ESVAZIAR a Lixeira?" && { rm -rf "$HOME/.Trash"/* 2>>"$LOG_FILE"; print -- "    ${C_OK}esvaziada${C_0}"; };;
    ollama)   ollama list 2>/dev/null; print -- "    Remover: ${C_B}ollama rm <modelo>${C_0}";;
    tmsnapshots)
      tmutil listlocalsnapshots / 2>/dev/null | sed 's/^/      /'
      print -- "    Afinar: ${C_B}sudo tmutil thinlocalsnapshots / 40000000000 4${C_0}"
      ;;
  esac
  return 0
}

cmd_disk_clean() {
  AUTO_YES=0; [[ "${1:-}" == "--yes" ]] && AUTO_YES=1
  print -- "${C_B}Limpeza guiada${C_0} — antes: $(data_free)"
  measure_disk_categories
  local -a ordem=(deriveddata devicesupport brewcache userlogs usercaches trash xcodearchives tmsnapshots simuladores ollama)
  local k; for k in "${ordem[@]}"; do clean_category "$k"; done
  print -- "\n${C_B}Depois:${C_0} $(data_free)"
}

cmd_disk() {
  case "${1:-scan}" in
    scan)  cmd_disk_scan;;
    clean) shift 2>/dev/null; cmd_disk_clean "$@";;
    *) print -- "disk: use scan|clean" >&2; return 64;;
  esac
}

# ========================================================== ZSHRC (censo)

SECRET_RE='(API[_-]?KEY|APIKEY|TOKEN|SECRET|PASSW|PASSWD|BEARER|CREDENTIAL|PRIVATE[_-]?KEY|ANTHROPIC|OPENAI|HF_|GITHUB_PAT)'
SECRET_VAL_RE='(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|hf_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})'

redact() { print -rn -- "REDACTED"; }

scan_zsh_file() {
  local f="${1/#\~/$HOME}" depth="${2:-0}"
  local name="" val=""
  [[ -f "$f" ]] || return 0
  local lines mtime
  lines=$(wc -l < "$f" | tr -d ' ')
  mtime=$(stat -f '%Sm' -t '%Y-%m-%d' "$f" 2>/dev/null)
  ZMD+=("" "#### \`${f/#$HOME/~}\` — $lines linhas · modificado $mtime" "")
  local hits=0
  while IFS= read -r ln; do
    if print -r -- "$ln" | grep -qE "$SECRET_RE" || print -r -- "$ln" | grep -qE "$SECRET_VAL_RE"; then
      (( hits++ ))
      name="$(print -r -- "$ln" | sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p')"
      if [[ -n "$name" ]]; then
        val="$(print -r -- "$ln" | sed -E 's/^[^=]*=//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//')"
        ZMD+=("- 🔑 **segredo**: \`$name\` = \`$(redact "$val")\`")
      else
        ZMD+=("- 🔑 **segredo (linha)**: \`$(redact "$ln")\`")
      fi
    fi
  done < "$f"
  (( hits == 0 )) && ZMD+=("- sem segredos detectados")

  local n_alias n_export n_func n_path
  n_alias=$(grep -cE '^[[:space:]]*alias '   "$f" 2>/dev/null); n_alias="${n_alias:-0}"
  n_export=$(grep -cE '^[[:space:]]*export ' "$f" 2>/dev/null); n_export="${n_export:-0}"
  n_func=$(grep -cE '^[[:space:]]*(function |[A-Za-z_][A-Za-z0-9_]*\(\))' "$f" 2>/dev/null); n_func="${n_func:-0}"
  n_path=$(grep -cE 'PATH='                   "$f" 2>/dev/null); n_path="${n_path:-0}"
  ZMD+=("- estrutura: $n_alias aliases · $n_export exports · $n_func funções · $n_path linhas de PATH")

  local al; al="$(grep -E '^[[:space:]]*alias ' "$f" 2>/dev/null | sed -E 's/^[[:space:]]*alias ([^=]+)=.*/\1/' | tr '\n' ' ')"
  [[ -n "$al" ]] && ZMD+=("- aliases: \`$al\`")

  grep -nE '(oh-my-zsh|zinit|antigen|zplug|starship|p10k|powerlevel|brew shellenv|conda init|nvm)' "$f" 2>/dev/null \
    | sed -E 's/^([0-9]+):(.*)$/- framework\/env (linha \1): `\2`/' \
    | while IFS= read -r l; do ZMD+=("${l[1,180]}"); done

  if (( depth < 1 )); then
    grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$f" 2>/dev/null \
      | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//; s/[[:space:]].*$//' \
      | while IFS= read -r src; do
          src="${src#\"}"; src="${src%\"}"
          src="${src#\'}"; src="${src%\'}"
          src="${src/#\~/$HOME}"; src="${src//\$HOME/$HOME}"
          src="${src//\$\{HOME\}/$HOME}"
          ZMD+=("- ↳ **source**: \`${src/#$HOME/~}\`")
          scan_zsh_file "$src" 1
        done
  fi
  return 0
}

cmd_zshrc() {
  resolve_out_dir
  local md_path="$OUT_DIR/zshrc_audit_${TS}.md"
  typeset -ga ZMD=()
  ZMD+=("# Censo zsh · $HOST" "" "**Quando:** $TS_ISO · shell: $ZSH_VERSION" "" \
        "## Arquivos de inicialização (ordem de carga)" "" "| arquivo | existe | papel |" "|---|---|---|")
  local spec f role ex
  for spec in \
    "$HOME/.zshenv|sempre — vars universais" \
    "$HOME/.zprofile|login — PATH/ambiente (brew shellenv mora aqui)" \
    "$HOME/.zshrc|interativo — aliases, prompt, plugins" \
    "$HOME/.zlogin|login, após zshrc" \
    "$HOME/.zlogout|saída de login"; do
    f="${spec%%|*}"; role="${spec#*|}"
    [[ -f "$f" ]] && ex="✅" || ex="—"
    ZMD+=("| \`${f/#$HOME/~}\` | $ex | $role |")
  done
  ZMD+=("" "## Conteúdo (segredos REDIGIDOS)")
  for f in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.zlogin"; do
    scan_zsh_file "$f" 0
  done
  if [[ -f "$HOME/.zsh_history" ]]; then
    ZMD+=("" "#### Histórico" "- \`~/.zsh_history\`: $(wc -l < "$HOME/.zsh_history" | tr -d ' ') linhas ($(du -h "$HOME/.zsh_history" | awk '{print $1}'))")
  fi
  printf '%s\n' "${ZMD[@]}" > "$md_path"
  cp -f "$md_path" "$OUT_DIR/latest-zshrc.md"
  print -- "Censo gravado: $md_path"
  print -- "              ${OUT_DIR}/latest-zshrc.md"
}

# ======================================================== PROVISION (if-not)

provision_one() {
  # eval é necessário aqui: os comandos de instalação legitimamente usam
  # pipe (curl | bash) e expansão de variável de shell. Todos os comandos
  # são internos e fixos neste arquivo — nunca vêm de input externo/rede —
  # então o risco prático de injeção é nulo. Documentado por transparência.
  local check="$1" name="$2"; shift 2
  if eval "$check" >/dev/null 2>&1; then
    print -- "  ${C_OK}●${C_0} $name já instalado"; return 0
  fi
  print -- "  ${C_WARN}▲${C_0} $name ausente"
  if confirm_auto "instalar $name agora?"; then
    print -- "    ${C_DIM}\$ $*${C_0}"
    if eval "$@"; then print -- "  ${C_OK}●${C_0} $name instalado"; log "provision ok: $name"
    else print -- "  ${C_BAD}✖${C_0} falha ($name)"; log "provision FALHOU: $name"; return 1
    fi
  else
    print -- "    ${C_DIM}pulado${C_0}"
  fi
  return 0
}

cmd_provision() {
  AUTO_YES=0; [[ "${1:-}" == "--yes" ]] && AUTO_YES=1
  print -- "${C_B}Provisionamento if-not · $HOST${C_0}\n"

  if xcode-select -p >/dev/null 2>&1; then
    print -- "  ${C_OK}●${C_0} Xcode Command Line Tools já instalado"
  else
    print -- "  ${C_WARN}▲${C_0} Xcode CLT ausente"
    confirm_auto "disparar 'xcode-select --install'?" && xcode-select --install
    print -- "    ${C_DIM}Conclua o diálogo e rode 'provision' de novo.${C_0}"
    return 1
  fi

  provision_one 'command -v brew' "Homebrew" \
    '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' || true
  [[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
  if ! command -v brew >/dev/null 2>&1; then
    print -- "  ${C_BAD}✖${C_0} sem Homebrew não dá pra seguir"; return 1
  fi

  provision_one 'command -v smartctl' "smartmontools" 'brew install smartmontools'
  provision_one 'command -v jq'       "jq"            'brew install jq'
  provision_one 'command -v tmux'     "tmux"           'brew install tmux'
  provision_one 'command -v mosh'     "mosh"           'brew install mosh'
  provision_one 'command -v gh'       "GitHub CLI"     'brew install gh'
  provision_one 'command -v claude'   "Claude Code"    'curl -fsSL https://claude.ai/install.sh | bash'

  print -- "\n${C_B}Concluído.${C_0} Rode 'diag' de novo para confirmar o inventário."
}

# =============================================================== FLEET (rollup)

cmd_fleet() {
  if ! command -v jq >/dev/null 2>&1; then
    print -- "${C_WARN}▲ fleet precisa do jq — rode './frotadiag.sh provision'${C_0}"
    return 1
  fi
  local base="$ICLOUD_BASE"
  [[ -d "$base" ]] || base="$STATE_DIR/reports"
  print -- "${C_B}fleet · rollup${C_0} · $base\n"
  printf "  %-1s %-16s %-8s %-26s %-9s %s\n" "" "HOST" "VEREDITO" "DISCO" "TM" "VER"
  printf "  %s\n" "$(printf '─%.0s' {1..78})"

  local now; now="$(date +%s)"
  typeset -a FMD
  FMD=("# Fleet · rollup" "" "**Quando:** $TS_ISO · base: \`$base\`" "" \
       "| | host | veredito | disco | TM | versão | idade |" "|---|---|---|---|---|---|---|")
  local n=0 any_bad=0 any_warn=0
  local f host ok warn bad ver disco_v tm_s mtime age_h icon overall age_lbl
  for f in "$base"/*/latest.json; do
    [[ -f "$f" ]] || continue
    [[ "${f:h:t}" == "_fleet" ]] && continue          # nunca agrega a própria saída
    host="$(jq -r '.host // ""' "$f" 2>/dev/null)" || continue
    [[ -z "$host" ]] && continue                       # arquivo meio-escrito / inválido
    ok="$(jq -r '.resumo.ok   // 0'  "$f" 2>/dev/null)"
    warn="$(jq -r '.resumo.warn // 0' "$f" 2>/dev/null)"
    bad="$(jq -r '.resumo.bad  // 0'  "$f" 2>/dev/null)"
    ver="$(jq -r '.script_version // "?"' "$f" 2>/dev/null)"
    disco_v="$(jq -r '.camadas.disco_uso.value // "n/d"' "$f" 2>/dev/null)"
    tm_s="$(jq -r '.camadas.tm_idade.status // .camadas.tm_ultimo.status // .camadas.tm_destino.status // "?"' "$f" 2>/dev/null)"
    mtime="$(stat -f %m "$f" 2>/dev/null || print 0)"
    age_h=$(( (now - mtime) / 3600 ))
    if   (( bad  > 0 )); then icon="${C_BAD}✖${C_0}";  overall="BAD";  any_bad=1
    elif (( warn > 0 )); then icon="${C_WARN}▲${C_0}"; overall="WARN"; any_warn=1
    else                      icon="${C_OK}●${C_0}";   overall="OK"
    fi
    if   (( age_h >= 168 )); then age_lbl="${C_BAD}$(( age_h/24 ))d${C_0}"
    elif (( age_h >= 48 ));  then age_lbl="${C_WARN}${age_h}h${C_0}"
    else                          age_lbl="${age_h}h"
    fi
    printf "  %s %-16.16s %-8s %-26.26s %-9s %-4s %b\n" "$icon" "$host" "$overall" "$disco_v" "$tm_s" "$ver" "$age_lbl"
    FMD+=("| $overall | \`$host\` | $overall | $(md_escape "$disco_v") | $tm_s | $ver | ${age_h}h |")
    (( n++ ))
  done

  if (( n == 0 )); then
    print -- "  ${C_DIM}nenhum host com latest.json encontrado${C_0}"
    return 0
  fi
  print -- "\n  ${C_B}$n host(s)${C_0} · ${C_BAD}✖ = crítico${C_0} · idade = desde a última coleta (>48h suspeito de offline)"

  # snapshot Markdown do rollup, fora do glob de hosts
  local fdir="$base/_fleet"
  if mkdir -p "$fdir" 2>/dev/null; then
    printf '%s\n' "${FMD[@]}" > "$fdir/fleet_${TS}.md"
    cp -f "$fdir/fleet_${TS}.md" "$fdir/latest.md"
    print -- "  rollup: $fdir/latest.md"
  fi

  (( any_bad ))  && return 2
  (( any_warn )) && return 1
  return 0
}

# ============================================================= SCHEDULE (launchd)

schedule_status() {
  if [[ -f "$LAUNCH_PLIST" ]]; then
    print -- "  ${C_OK}●${C_0} plist: $LAUNCH_PLIST"
    if launchctl print "gui/$UID/$LAUNCH_LABEL" >/dev/null 2>&1; then
      print -- "  ${C_OK}●${C_0} job carregado no launchd"
    else
      print -- "  ${C_WARN}▲${C_0} plist existe mas o job não está carregado"
    fi
  else
    print -- "  ${C_DIM}sem agendamento instalado${C_0}"
  fi
  return 0
}

schedule_install() {  # schedule_install [hora 0-23]
  local hour="${1:-9}"
  if [[ "$hour" != <-> ]] || (( hour < 0 || hour > 23 )); then
    print -- "hora inválida: $hour (use 0–23)" >&2; return 64
  fi
  print -- "${C_B}Agendar diag nightly${C_0}"
  print -- "  comando: $SCRIPT_PATH diag  ·  todo dia às $(printf '%02d' "$hour"):00"
  print -- "  plist:   $LAUNCH_PLIST"
  confirm "instalar o LaunchAgent?" || { print -- "    ${C_DIM}cancelado${C_0}"; return 0; }

  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCH_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_PATH</string>
    <string>diag</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>0</integer></dict>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StandardOutPath</key><string>$STATE_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/launchd.err.log</string>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$UID/$LAUNCH_LABEL" 2>/dev/null   # idempotente: descarrega antes
  if launchctl bootstrap "gui/$UID" "$LAUNCH_PLIST" 2>/dev/null; then
    print -- "  ${C_OK}●${C_0} agendado (bootstrap)"
  elif launchctl load "$LAUNCH_PLIST" 2>/dev/null; then
    print -- "  ${C_OK}●${C_0} agendado (load — launchctl legado)"
  else
    print -- "  ${C_BAD}✖${C_0} plist escrito mas launchctl recusou carregar (ver $STATE_DIR/launchd.err.log)"
    return 1
  fi
  log "schedule install hora=$hour"
  return 0
}

schedule_uninstall() {
  if [[ ! -f "$LAUNCH_PLIST" ]]; then
    print -- "  ${C_DIM}nada a remover${C_0}"; return 0
  fi
  confirm "remover o LaunchAgent e apagar o plist?" || { print -- "    ${C_DIM}cancelado${C_0}"; return 0; }
  launchctl bootout "gui/$UID/$LAUNCH_LABEL" 2>/dev/null || launchctl unload "$LAUNCH_PLIST" 2>/dev/null
  rm -f "$LAUNCH_PLIST"
  print -- "  ${C_OK}●${C_0} removido"
  log "schedule uninstall"
  return 0
}

cmd_schedule() {
  case "${1:-status}" in
    install)   shift 2>/dev/null; schedule_install "$@";;
    uninstall) schedule_uninstall;;
    status)    schedule_status;;
    *) print -- "schedule: use install [hora] | uninstall | status" >&2; return 64;;
  esac
}

# =============================================================== ALL / MAIN

cmd_all() {
  cmd_diag "$@" || true   # cmd_diag retorna 1/2 por desenho (warn/bad); não deve derrubar 'all'
  print -- ""
  cmd_disk_scan
  print -- ""
  cmd_zshrc
}

case "${1:-diag}" in
  diag)      shift 2>/dev/null; cmd_diag "$@";;
  disk)      shift 2>/dev/null; cmd_disk "$@";;
  zshrc)     shift 2>/dev/null; cmd_zshrc "$@";;
  provision) shift 2>/dev/null; cmd_provision "$@";;
  fleet)     shift 2>/dev/null; cmd_fleet "$@";;
  schedule)  shift 2>/dev/null; cmd_schedule "$@";;
  all)       shift 2>/dev/null; cmd_all "$@";;
  help|-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,2\}//';;
  *) print -- "subcomando desconhecido: $1 (use: diag | disk | zshrc | provision | fleet | schedule | all | help)" >&2; exit 64;;
esac
