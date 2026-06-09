#!/usr/bin/env bash
set -euo pipefail

# drive-monitor.sh
# Unified drive (SMART) and array (ZFS, mdadm) health monitor with Pushover alerts.
#
# Behavior:
#   - New or changed problems alert immediately (high priority).
#   - The same ongoing problem is re-alerted only once per COOLDOWN_SECONDS.
#   - Recovery (problem -> healthy) sends an "all clear" (info priority).
#   - Maintenance activity (ZFS scrub/resilver, mdadm resync/recovery/check/reshape)
#     can send one-time start/finish info notifications (toggleable).
#   - Each subsystem is auto-skipped if its tool isn't installed.
#
# Intended to run as root from cron. State persists between runs in STATE_DIR.

# ----------------- load env settings -----------------
ENV_FILE="${ENV_FILE:-/etc/drive-monitor.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# ----------------- general config (env-overridable) -----------------
LOGFILE="${LOGFILE:-/var/log/drive-monitor.log}"
STATE_DIR="${STATE_DIR:-/var/lib/drive-monitor}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-21600}" # 6 hours between reminders for the same problem

# Tool paths (auto-detected if not set)
SMARTCTL="${SMARTCTL:-$(command -v smartctl || true)}"
ZPOOL="${ZPOOL:-$(command -v zpool || true)}"
MDADM="${MDADM:-$(command -v mdadm || true)}"
CURL="${CURL:-$(command -v curl || true)}"
LOGGER="${LOGGER:-$(command -v logger || true)}"

# Module toggles (also auto-skipped if the tool is missing)
ENABLE_SMART="${ENABLE_SMART:-1}"
ENABLE_ZFS="${ENABLE_ZFS:-1}"
ENABLE_MDADM="${ENABLE_MDADM:-1}"

# Pushover
PO_TOKEN="${PO_TOKEN:-}"
PO_UK="${PO_UK:-}"
PO_API_URL="${PO_API_URL:-https://api.pushover.net/1/messages.json}"
PO_PRIORITY_ALARM="${PO_PRIORITY_ALARM:-1}"
PO_PRIORITY_INFO="${PO_PRIORITY_INFO:--1}"
PO_SOUND_ALARM="${PO_SOUND_ALARM:-}"
PO_SOUND_INFO="${PO_SOUND_INFO:-}"

# Info-notification toggles for maintenance activity (0/1)
NOTIFY_SCRUB_START="${NOTIFY_SCRUB_START:-1}"
NOTIFY_SCRUB_END="${NOTIFY_SCRUB_END:-1}"
NOTIFY_RESILVER_START="${NOTIFY_RESILVER_START:-1}"
NOTIFY_RESILVER_END="${NOTIFY_RESILVER_END:-1}"
NOTIFY_MD_SYNC_START="${NOTIFY_MD_SYNC_START:-1}"
NOTIFY_MD_SYNC_END="${NOTIFY_MD_SYNC_END:-1}"

# SMART thresholds
SMART_NVME_PCT_USED_MAX="${SMART_NVME_PCT_USED_MAX:-90}"
SMART_NVME_SPARE_MIN="${SMART_NVME_SPARE_MIN:-10}"
SMART_WATCH_ATTRS_REGEX="${SMART_WATCH_ATTRS_REGEX:-^(Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable)\$}"

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"

# ----------------- setup -----------------
mkdir -p "$STATE_DIR"
touch "$LOGFILE" 2>/dev/null || true

# ----------------- helpers -----------------
ts() { date "+%Y-%m-%d %H:%M:%S"; }
now_epoch() { date +%s; }

log() {
  local msg="$1"
  echo "$(ts) - $msg" >> "$LOGFILE" 2>/dev/null || true
  [[ -n "$LOGGER" ]] && "$LOGGER" -t "drive-monitor" -- "$msg" 2>/dev/null || true
}

have() { [[ -n "$1" && -x "$1" ]] || command -v "$1" >/dev/null 2>&1; }

sanitize_key() {
  printf '%s' "$1" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g'
}

state_get() {
  local f="$STATE_DIR/$1"
  [[ -f "$f" ]] && cat "$f" 2>/dev/null || true
}
state_set() {
  local f="$STATE_DIR/$1"
  printf '%s' "$2" > "$f"
}

send_pushover() {
  local title="$1" message="$2" priority="$3" sound="$4"

  if [[ -z "$PO_TOKEN" || -z "$PO_UK" ]]; then
    log "WARN: Pushover not configured (PO_TOKEN/PO_UK missing). Would have sent: $title"
    return 0
  fi
  if [[ -z "$CURL" ]]; then
    log "WARN: curl not found; cannot send Pushover. Would have sent: $title"
    return 0
  fi

  # Pushover message limit is 1024 chars.
  message="${message:0:1000}"

  "$CURL" -sS \
    --form-string "token=${PO_TOKEN}" \
    --form-string "user=${PO_UK}" \
    --form-string "title=${title}" \
    --form-string "message=${message}" \
    --form-string "priority=${priority}" \
    ${sound:+--form-string "sound=${sound}"} \
    "$PO_API_URL" >/dev/null \
    || log "WARN: Pushover send failed for: $title"
}

# Stateful problem/recovery handler for a single subject (device or array).
#   handle_subject <key> <label> <signature> <title> <message>
# An empty signature means "healthy".
handle_subject() {
  local key="$1" label="$2" sig="$3" title="$4" message="$5"
  local state_file="${key}.state" sig_file="${key}.sig" alert_file="${key}.last_alert"
  local prev_state prev_sig last_alert now
  prev_state="$(state_get "$state_file")"; prev_state="${prev_state:-ok}"
  now="$(now_epoch)"

  if [[ -n "$sig" ]]; then
    prev_sig="$(state_get "$sig_file")"
    last_alert="$(state_get "$alert_file")"; last_alert="${last_alert:-0}"

    local do_alert=false reason=""
    if [[ "$prev_state" != "problem" ]]; then
      do_alert=true; reason="new"
    elif [[ "$sig" != "$prev_sig" ]]; then
      do_alert=true; reason="changed"
    elif (( now - last_alert >= COOLDOWN_SECONDS )); then
      do_alert=true; reason="reminder"
    fi

    if $do_alert; then
      send_pushover "$title" "$message" "$PO_PRIORITY_ALARM" "$PO_SOUND_ALARM"
      state_set "$alert_file" "$now"
      log "ALERT($reason): $label"
    else
      log "SUPPRESSED(cooldown ${COOLDOWN_SECONDS}s): $label"
    fi

    state_set "$sig_file" "$sig"
    state_set "$state_file" "problem"
  else
    if [[ "$prev_state" == "problem" ]]; then
      send_pushover "Recovered: $label" "$label is healthy again on ${HOSTNAME_SHORT}." \
        "$PO_PRIORITY_INFO" "$PO_SOUND_INFO"
      log "RECOVERED: $label"
    else
      log "OK: $label"
    fi
    state_set "$sig_file" ""
    state_set "$state_file" "ok"
  fi
}

# One-time start/finish notifications for maintenance activity.
#   handle_activity <key> <label> <current_activity> <detail> <notify_start> <notify_end>
# current_activity is a word like scrub/resilver/resync/recovery/check/reshape, or "none".
handle_activity() {
  local key="$1" label="$2" act="$3" detail="$4" nstart="$5" nend="$6"
  local af="${key}.activity"
  local prev; prev="$(state_get "$af")"; prev="${prev:-none}"

  if [[ "$prev" == "none" && "$act" != "none" ]]; then
    [[ "$nstart" == "1" ]] && {
      send_pushover "${label}: ${act} started" "$detail" "$PO_PRIORITY_INFO" "$PO_SOUND_INFO"
      log "INFO: ${label} ${act} started"
    }
  elif [[ "$prev" != "none" && "$act" == "none" ]]; then
    [[ "$nend" == "1" ]] && {
      send_pushover "${label}: ${prev} finished" "$detail" "$PO_PRIORITY_INFO" "$PO_SOUND_INFO"
      log "INFO: ${label} ${prev} finished"
    }
  fi
  state_set "$af" "$act"
}

# ============================================================
# Module 1: SMART (physical drives)
# ============================================================
smart_scan_devices() {
  "$SMARTCTL" --scan-open 2>/dev/null | awk '
    $1 ~ /^\/dev\// {
      dev=$1; dtype=""
      for (i=1;i<=NF;i++) if ($i=="-d" && (i+1)<=NF) dtype=$(i+1)
      print dev "|" dtype
    }'
}

smart_run_one() {
  local dev="$1" dtype="$2"
  local dopt=()
  [[ -n "$dtype" ]] && dopt=(-d "$dtype")

  local idout health attrs err
  idout="$("$SMARTCTL" "${dopt[@]}" -i "$dev" 2>/dev/null || true)"
  local model serial
  model="$(echo "$idout" | awk -F: '/Device Model|Model Number/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  serial="$(echo "$idout" | awk -F: '/Serial Number/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"

  local hout
  hout="$("$SMARTCTL" "${dopt[@]}" -H "$dev" 2>/dev/null || true)"
  if echo "$hout" | grep -qiE 'PASSED|OK'; then
    health="PASS"
  elif echo "$hout" | grep -qiE 'FAILED|BAD'; then
    health="FAIL"
  else
    health="UNKNOWN"
  fi

  local aout
  aout="$("$SMARTCTL" "${dopt[@]}" -A "$dev" 2>/dev/null || true)"
  attrs="$(echo "$aout" | awk -v re="$SMART_WATCH_ATTRS_REGEX" '
    $0 ~ re {
      attr=$2; raw=$NF; gsub(/^0+/,"0",raw)
      if (raw ~ /^[0-9]+$/ && raw+0 > 0) print attr " " raw
    }')"
  local pct_used spare
  pct_used="$(echo "$aout" | awk -F: '/Percentage Used/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
  spare="$(echo "$aout" | awk -F: '/Available Spare/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
  if [[ "$pct_used" =~ ^[0-9]+$ ]] && (( pct_used >= SMART_NVME_PCT_USED_MAX )); then
    attrs="${attrs:+$attrs$'\n'}Percentage_Used ${pct_used}%"
  fi
  if [[ "$spare" =~ ^[0-9]+$ ]] && (( spare <= SMART_NVME_SPARE_MIN )); then
    attrs="${attrs:+$attrs$'\n'}Available_Spare ${spare}%"
  fi

  local elog
  elog="$("$SMARTCTL" "${dopt[@]}" -l error "$dev" 2>/dev/null || true)"
  if echo "$elog" | grep -qiE 'No Errors Logged|not supported|Unavailable'; then
    err=""
  else
    err="$(echo "$elog" | sed 's/[[:space:]]\+/ /g' | head -n 8 || true)"
  fi

  local reasons=()
  [[ "$health" == "FAIL" ]] && reasons+=("SMART overall health FAILED")
  [[ -n "$attrs" ]] && reasons+=("SMART attributes indicate trouble")
  [[ -n "$err" ]] && reasons+=("SMART error log has entries")

  local key sig
  key="smart_$(sanitize_key "${dev}_${dtype}")"

  if (( ${#reasons[@]} > 0 )); then
    sig="$(printf '%s' "${reasons[*]}|${attrs}|${err}" | cksum | awk '{print $1}')"
    local title message
    title="SMART alert ${HOSTNAME_SHORT}: ${dev} (-d ${dtype:-auto})"
    message="$(cat <<EOF
Host: $HOSTNAME_SHORT
Device: $dev (-d ${dtype:-auto})
Model=${model:-unknown} Serial=${serial:-unknown}
Health: $health
${attrs:+
Bad attributes:
$attrs
}${err:+
Error log excerpt:
$err
}
Reasons: ${reasons[*]}
EOF
)"
    handle_subject "$key" "SMART ${dev}" "$sig" "$title" "$message"
  else
    handle_subject "$key" "SMART ${dev}" "" "" ""
  fi
}

module_smart() {
  [[ "$ENABLE_SMART" == "1" ]] || { log "SMART module disabled."; return 0; }
  if ! have "$SMARTCTL"; then log "SMART module skipped (smartctl not found)."; return 0; fi

  local found=0
  while IFS='|' read -r dev dtype; do
    [[ -e "$dev" ]] || continue
    found=1
    smart_run_one "$dev" "$dtype"
  done < <(smart_scan_devices)
  (( found == 0 )) && log "SMART: no devices discovered."
}

# ============================================================
# Module 2: ZFS pools
# ============================================================
zfs_pools() { "$ZPOOL" list -H -o name 2>/dev/null || true; }

zfs_activity() {
  # Reads full `zpool status` text on stdin; prints activity word or "none".
  awk '
    /^[[:space:]]*scan:/ {
      sub(/^[[:space:]]*scan:[[:space:]]*/,"")
      if ($0 ~ /^scrub in progress/)      { print "scrub"; exit }
      else if ($0 ~ /^scrub paused/)      { print "scrub"; exit }
      else if ($0 ~ /^resilver in progress/) { print "resilver"; exit }
      else { print "none"; exit }
    }'
}

zfs_run_one() {
  local pool="$1"
  local status_x full_status
  status_x="$("$ZPOOL" status -x "$pool" 2>&1 || true)"
  full_status="$("$ZPOOL" status "$pool" 2>&1 || true)"

  local healthy_line="pool '$pool' is healthy"
  local key; key="zfs_$(sanitize_key "$pool")"

  # ---- maintenance activity (info) ----
  local act scan detail nstart nend
  act="$(printf '%s\n' "$full_status" | zfs_activity)"
  act="${act:-none}"
  scan="$(printf '%s\n' "$full_status" | awk -F': ' '/^[[:space:]]*scan:/{print $2; exit}')"
  detail="scan: ${scan:-n/a}"
  if [[ "$act" == "resilver" ]]; then
    nstart="$NOTIFY_RESILVER_START"; nend="$NOTIFY_RESILVER_END"
  else
    nstart="$NOTIFY_SCRUB_START"; nend="$NOTIFY_SCRUB_END"
  fi
  # When ending, the flag should match the activity that just finished.
  local prev_act; prev_act="$(state_get "${key}.activity")"; prev_act="${prev_act:-none}"
  if [[ "$act" == "none" && "$prev_act" == "resilver" ]]; then
    nend="$NOTIFY_RESILVER_END"
  elif [[ "$act" == "none" && "$prev_act" == "scrub" ]]; then
    nend="$NOTIFY_SCRUB_END"
  fi
  handle_activity "$key" "Zpool ${pool}" "$act" "$detail" "$nstart" "$nend"

  # ---- health (problem/recovery) ----
  if [[ "$status_x" == "$healthy_line" ]]; then
    handle_subject "$key" "Zpool ${pool}" "" "" ""
  else
    local sig title message details
    details="$(printf '%s\n' "$full_status" | sed -n '1,60p' || true)"
    sig="$(printf '%s' "$status_x" | cksum | awk '{print $1}')"
    title="Zpool ${pool} unhealthy (${HOSTNAME_SHORT})"
    message="$(cat <<EOF
Host: $HOSTNAME_SHORT
zpool '$pool' is NOT healthy.

zpool status -x:
$status_x

scan: ${scan:-n/a}

zpool status (top):
$details
EOF
)"
    handle_subject "$key" "Zpool ${pool}" "$sig" "$title" "$message"
  fi
}

module_zfs() {
  [[ "$ENABLE_ZFS" == "1" ]] || { log "ZFS module disabled."; return 0; }
  if ! have "$ZPOOL"; then log "ZFS module skipped (zpool not found)."; return 0; fi

  local pools; pools="$(zfs_pools)"
  if [[ -z "$pools" ]]; then log "ZFS: no pools found."; return 0; fi
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    zfs_run_one "$p"
  done <<< "$pools"
}

# ============================================================
# Module 3: mdadm arrays
# ============================================================
md_arrays() {
  [[ -r /proc/mdstat ]] || return 0
  awk '/^md[0-9]+[[:space:]]*:/ {print "/dev/" $1}' /proc/mdstat
}

md_activity() {
  # args: md device name (e.g. md0); reads /proc/mdstat; prints "act|pct" or "none|"
  local name="$1"
  awk -v dev="$name" '
    $0 ~ "^"dev"[[:space:]]*:" { f=1; next }
    f && /(resync|recovery|check|reshape)[[:space:]]*=/ {
      act=""; pct=""
      for (i=1;i<=NF;i++) {
        if ($i ~ /^(resync|recovery|check|reshape)$/) act=$i
        if ($i ~ /%/) pct=$i
      }
      print act "|" pct; exit
    }
    f && /^[[:space:]]*$/ { print "none|"; exit }
    END { if (f==1) print "none|" }
  ' /proc/mdstat | head -n 1
}

md_run_one() {
  local md="$1"
  local name; name="$(basename "$md")"
  local key; key="md_$(sanitize_key "$name")"

  local detail
  detail="$("$MDADM" --detail "$md" 2>/dev/null || true)"

  local state_line failed faulty
  state_line="$(echo "$detail" | awk -F: '/^[[:space:]]*State :/{sub(/^[ \t]+/,"",$2); print $2; exit}')"
  failed="$(echo "$detail" | awk -F: '/Failed Devices :/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
  faulty="$(echo "$detail" | grep -iE 'faulty|removed' | sed 's/[[:space:]]\+/ /g' | head -n 8 || true)"

  # ---- maintenance activity (info) ----
  local actpct act pct detailmsg
  actpct="$(md_activity "$name")"
  act="${actpct%%|*}"; act="${act:-none}"
  pct="${actpct#*|}"
  detailmsg="${name}: ${act}${pct:+ $pct}"
  handle_activity "$key" "mdadm ${name}" "$act" "$detailmsg" \
    "$NOTIFY_MD_SYNC_START" "$NOTIFY_MD_SYNC_END"

  # ---- health (problem/recovery) ----
  local bad=0
  if echo "$state_line" | grep -qiE 'degraded|fail|faulty|inactive|removed|broken'; then bad=1; fi
  if [[ "$failed" =~ ^[0-9]+$ ]] && (( failed > 0 )); then bad=1; fi
  if [[ -n "$faulty" ]]; then bad=1; fi
  if [[ -z "$detail" ]]; then
    log "mdadm ${name}: could not read details (need root?)."
  fi

  if (( bad == 1 )); then
    local sig title message head
    head="$(printf '%s\n' "$detail" | sed -n '1,40p' || true)"
    sig="$(printf '%s' "${state_line}|${failed}|${faulty}" | cksum | awk '{print $1}')"
    title="mdadm ${name} unhealthy (${HOSTNAME_SHORT})"
    message="$(cat <<EOF
Host: $HOSTNAME_SHORT
Array: $md
State: ${state_line:-unknown}
Failed Devices: ${failed:-?}
${faulty:+
Problem devices:
$faulty
}
mdadm --detail (top):
$head
EOF
)"
    handle_subject "$key" "mdadm ${name}" "$sig" "$title" "$message"
  else
    handle_subject "$key" "mdadm ${name}" "" "" ""
  fi
}

module_mdadm() {
  [[ "$ENABLE_MDADM" == "1" ]] || { log "mdadm module disabled."; return 0; }
  if ! have "$MDADM"; then log "mdadm module skipped (mdadm not found)."; return 0; fi
  if [[ ! -r /proc/mdstat ]]; then log "mdadm module skipped (/proc/mdstat unavailable)."; return 0; fi

  local arrays; arrays="$(md_arrays)"
  if [[ -z "$arrays" ]]; then log "mdadm: no arrays found."; return 0; fi
  local a
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    md_run_one "$a"
  done <<< "$arrays"
}

# ============================================================
# main
# ============================================================
main() {
  log "drive-monitor run start on ${HOSTNAME_SHORT}"
  if [[ -z "$PO_TOKEN" || -z "$PO_UK" ]]; then
    log "WARN: Pushover credentials not set; alerts will be logged only."
  fi

  module_smart
  module_zfs
  module_mdadm

  log "drive-monitor run complete on ${HOSTNAME_SHORT}"
}

main "$@"
