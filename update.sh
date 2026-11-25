#!/bin/sh
# vpn-exit nightly updater. Runs inside the `updater` service
# (docker:cli image, host docker socket, stack dir mounted at its host path).
#
# Each run:
#   1. snapshot current images as rollback tags
#   2. pull floating tags (tailscale:stable, gluetun:v3)
#   3. recreate vpn/tailscale/fixup if anything changed (or if stack is down)
#   4. verify: VPN egress IP != home IP, tailscale Running + advertising exit,
#      fixup routing rules present
#   5. on failed verify after an update: restore previous images, recreate, re-verify
#   6. write secret-free status JSON (point your monitoring at it)
set -u

STACK_DIR=${STACK_DIR:?STACK_DIR required}
STATUS_DIR=${STATUS_DIR:-/status}
PROJECT=${PROJECT:-vpn-exit}
TRACKED_IMAGES=${TRACKED_IMAGES:-"tailscale/tailscale:stable qmcgaw/gluetun:v3"}
SERVICES="vpn tailscale fixup"

cd "$STACK_DIR" || { echo "no stack dir"; exit 1; }
dc() { docker compose -p "$PROJECT" "$@"; }
log() { echo "[updater $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }
rb_tag() { echo "$PROJECT-rollback:$(echo "$1" | tr '/:' '__')"; }
img_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

VERIFY_ERR=""
VPN_IP=""
TS_VERSION=""
GLUETUN_VERSION=""

verify_once() {
  VERIFY_ERR=""
  rules=$(dc exec -T vpn ip rule show 2>/dev/null)
  if ! echo "$rules" | grep -q 'iif tailscale0 lookup 51820' \
     || ! echo "$rules" | grep -q '^40:.*fwmark 0x80000/0xff0000 lookup main'; then
    VERIFY_ERR="$VERIFY_ERR routing_rules_missing"
  fi
  # Kill switch: forwarded traffic must not have a default-accept path.
  dc exec -T vpn iptables-legacy -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP' \
    || VERIFY_ERR="$VERIFY_ERR forward_not_fail_closed"

  VPN_IP=$(dc exec -T vpn wget -qO- -T 10 https://api.ipify.org 2>/dev/null | tr -cd '0-9a-fA-F.:')
  HOME_IP=$(wget -qO- -T 10 https://api.ipify.org 2>/dev/null | tr -cd '0-9a-fA-F.:')
  if [ -z "$VPN_IP" ]; then
    VERIFY_ERR="$VERIFY_ERR vpn_no_egress"
  elif [ -n "$HOME_IP" ] && [ "$VPN_IP" = "$HOME_IP" ]; then
    VERIFY_ERR="$VERIFY_ERR vpn_ip_equals_home_ip"
  fi

  st=$(dc exec -T tailscale tailscale status --json 2>/dev/null)
  echo "$st" | grep -q '"BackendState": *"Running"' || VERIFY_ERR="$VERIFY_ERR tailscale_not_running"
  dc exec -T tailscale tailscale debug prefs 2>/dev/null | grep -q '0.0.0.0/0' \
    || VERIFY_ERR="$VERIFY_ERR exit_node_not_advertised"

  TS_VERSION=$(dc exec -T tailscale tailscale version 2>/dev/null | head -n1 | tr -cd '0-9a-zA-Z.-')
  GLUETUN_VERSION=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' qmcgaw/gluetun:v3 2>/dev/null | tr -cd '0-9a-zA-Z.-')
  [ -z "$VERIFY_ERR" ]
}

verify() {
  # Re-check the WHOLE stack, not only routing. Tailscale may still be joining
  # its control plane after Docker reports the container started.
  verify_deadline=$(( $(date +%s) + ${VERIFY_TIMEOUT_SECONDS:-180} ))
  verify_attempt=0
  while :; do
    verify_attempt=$((verify_attempt + 1))
    if verify_once; then
      log "verify passed on attempt $verify_attempt"
      return 0
    fi
    verify_now=$(date +%s)
    if [ "$verify_now" -ge "$verify_deadline" ]; then
      log "verify timed out after $verify_attempt checks:$VERIFY_ERR"
      return 1
    fi
    log "waiting for stack (check $verify_attempt):$VERIFY_ERR"
    verify_wait=${VERIFY_INTERVAL_SECONDS:-10}
    verify_remaining=$((verify_deadline - verify_now))
    [ "$verify_wait" -gt "$verify_remaining" ] && verify_wait=$verify_remaining
    sleep "$verify_wait"
  done
}

write_status() { # result detail
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  tmp="$STATUS_DIR/.update-status.json.tmp"
  cat > "$tmp" <<EOF
{
  "checked_at": "$now",
  "result": "$1",
  "detail": "$(echo "$2" | sed 's/^ *//')",
  "updated": $UPDATED,
  "tailscale_version": "$TS_VERSION",
  "gluetun_version": "$GLUETUN_VERSION",
  "vpn_egress_ok": $([ -n "$VPN_IP" ] && echo true || echo false),
  "tracked_images": "$TRACKED_IMAGES"
}
EOF
  # Status dir must be root-owned (monitoring reads only). Never chown/follow into
  # a dir the less-privileged side can write: symlink planting = root write.
  chmod 0644 "$tmp"
  mv -f "$tmp" "$STATUS_DIR/update-status.json"
  log "status: $1 $2"
}

run_once() {
  UPDATED=false
  if [ "$(stat -c %u "$STATUS_DIR" 2>/dev/null)" != "0" ] || [ -L "$STATUS_DIR/update-status.json" ]; then
    log "refusing: $STATUS_DIR must be root-owned and status file not a symlink"; return
  fi
  log "run start"

  # 1. rollback snapshot
  for img in $TRACKED_IMAGES; do
    id=$(img_id "$img")
    [ -n "$id" ] && docker image tag "$img" "$(rb_tag "$img")"
    eval "OLD_$(echo "$img" | tr '/:.-' '____')=\"$id\""
  done

  # 2. pull
  if ! dc pull -q $SERVICES; then
    verify
    write_status "pull_failed" "docker pull failed; still on previous images. $VERIFY_ERR"
    return
  fi

  # 3. changed?
  changed=""
  for img in $TRACKED_IMAGES; do
    eval "old=\$OLD_$(echo "$img" | tr '/:.-' '____')"
    [ "$old" != "$(img_id "$img")" ] && changed="$changed $img"
  done
  running=$(dc ps --status running -q $SERVICES 2>/dev/null | wc -l)

  if [ -z "$changed" ] && [ "$running" -ge 3 ]; then
    if verify; then write_status "ok" "no new images"; else write_status "unhealthy" "$VERIFY_ERR"; fi
    return
  fi

  [ -n "$changed" ] && { UPDATED=true; log "new images:$changed"; } || log "stack not fully running ($running/3); starting"
  dc up -d --wait --wait-timeout 180 $SERVICES || log "up returned non-zero"

  if verify; then
    write_status "ok" "$([ -n "$changed" ] && echo "updated:$changed" || echo "restarted stack")"
    docker image prune -f >/dev/null 2>&1
    return
  fi

  # 5. rollback
  first_err="$VERIFY_ERR"
  if [ -n "$changed" ]; then
    log "verify failed ($first_err); rolling back"
    for img in $changed; do docker image tag "$(rb_tag "$img")" "$img"; done
    dc up -d --force-recreate --wait --wait-timeout 180 $SERVICES || true
    if verify; then
      write_status "rolled_back" "new images failed verify ($first_err); previous images restored and healthy"
    else
      write_status "failed" "update failed ($first_err) and rollback unhealthy ($VERIFY_ERR)"
    fi
  else
    write_status "unhealthy" "$first_err"
  fi
}

case "${1:-loop}" in
  once) run_once ;;
  check)
    # Health check only: no pull, no recreate, no status write.
    if verify; then echo "CHECK ok ts=$TS_VERSION"; exit 0; fi
    echo "CHECK failed:$VERIFY_ERR"; exit 1 ;;
  loop)
    sleep "${START_DELAY:-120}"
    [ "${RUN_ON_START:-1}" = "1" ] && run_once
    while true; do
      # Sleep until next RUN_HOUR local (TZ is a POSIX string; no tzdata needed).
      h=$(expr "$(date +%H)" + 0); m=$(expr "$(date +%M)" + 0); s=$(expr "$(date +%S)" + 0)
      now=$((h * 3600 + m * 60 + s)); target=$((${RUN_HOUR:-4} * 3600))
      wait=$((target - now)); [ $wait -le 60 ] && wait=$((wait + 86400))
      log "next run in ${wait}s"
      sleep "$wait"
      run_once
    done ;;
esac
