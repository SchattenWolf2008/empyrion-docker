#!/bin/bash
set -e

export HOME="/home/container"
cd "$HOME"

# -------- Helpers --------
q()  { printf %s "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }          # YAML escape
bool(){ [ "$1" = "1" ] && echo true || echo false; }             # 0/1 -> true/false

# -------- Persist Steam files inside mounted dir --------
PERSIST_STEAM="$HOME/steamdata"
mkdir -p "$PERSIST_STEAM"

# Move existing Steam dir into persistence area if it's a real dir
if [ -e "$HOME/Steam" ] && [ ! -L "$HOME/Steam" ]; then
  mv "$HOME/Steam" "$PERSIST_STEAM/Steam"
fi
# Ensure target exists and symlink in place
[ -d "$PERSIST_STEAM/Steam" ] || mkdir -p "$PERSIST_STEAM/Steam"
[ -L "$HOME/Steam" ] || ln -s "$PERSIST_STEAM/Steam" "$HOME/Steam"

STEAMCMD_BIN="/opt/steamcmd/steamcmd.sh"
LOGINUSERS="$HOME/Steam/config/loginusers.vdf"

# -------- Optional workshop scenario --------
STEAMCMD=""
if [ -n "$SCENARIO_WORKSHOP_ID" ]; then
  mkdir -p "$HOME/Steam"
  printf 'workshop_download_item 383120 %s\n' "$SCENARIO_WORKSHOP_ID" > "$HOME/Steam/add_scenario.txt"
  STEAMCMD="+runscript $HOME/Steam/add_scenario.txt"
fi

# -------- Optional beta branch --------
BETACMD=""
[ "$BETA" = "1" ] && BETACMD="-beta experimental"

# -------- Game paths --------
BASE_DIR="$HOME/Steam/steamapps/common/Empyrion - Dedicated Server"
GAMEDIR="$BASE_DIR/DedicatedServer"

# -------- Generate dedicated-generated.yaml from panel vars --------
CFG_GEN="$BASE_DIR/dedicated-generated.yaml"
mkdir -p "$BASE_DIR"

{
  echo "ServerConfig:"
  echo "    Srv_Port: ${SRV_PORT:-30000}"
  echo "    Srv_Name: \"$(q "${SERVER_NAME}")\""
  [ -n "$SRV_PASSWORD" ] && echo "    Srv_Password: \"$(q "${SRV_PASSWORD}")\""
  echo "    Srv_MaxPlayers: ${MAX_PLAYERS}"
  echo "    Srv_ReservePlayfields: ${SRV_RESERVE_PLAYFIELDS}"
  [ -n "$SRV_DESCRIPTION" ] && echo "    Srv_Description: \"$(q "${SRV_DESCRIPTION}")\""
  echo "    Srv_Public: $(bool "$SRV_PUBLIC")"
  [ -n "$SRV_STOP_PERIOD" ] && echo "    Srv_StopPeriod: ${SRV_STOP_PERIOD}"
  echo "    Tel_Enabled: $(bool "$TELNET_ENABLED")"
  echo "    Tel_Port: ${TELNET_PORT}"
  [ -n "$TELNET_PASSWORD" ] && echo "    Tel_Pwd: \"$(q "${TELNET_PASSWORD}")\""
  echo "    EACActive: $(bool "$EAC_ACTIVE")"
  echo "    MaxAllowedSizeClass: ${MAX_ALLOWED_SIZE_CLASS}"
  echo "    AllowedBlueprints: ${ALLOWED_BLUEPRINTS}"
  echo "    HeartbeatServer: ${HEARTBEAT_SERVER}"
  echo "    HeartbeatClient: ${HEARTBEAT_CLIENT}"
  echo "    LogFlags: ${LOG_FLAGS}"
  echo "    DisableSteamFamilySharing: $(bool "$DISABLE_FAMILY_SHARING")"
  echo "    KickPlayerWithPing: ${KICK_PLAYER_WITH_PING}"
  echo "    TimeoutBootingPfServer: ${TIMEOUT_BOOTING_PF}"
  echo "    PlayerLoginParallelCount: ${PLAYER_LOGIN_PARALLEL_COUNT}"
  [ -n "$PLAYER_LOGIN_VIP_NAMES" ] && echo "    PlayerLoginVipNames: \"$(q "${PLAYER_LOGIN_VIP_NAMES}")\""
  echo "    EnableDLC: $(bool "$ENABLE_DLC")"
  echo
  echo "GameConfig:"
  echo "    GameName: \"$(q "${GAME_NAME}")\""
  echo "    Mode: ${GAME_MODE}"
  [ -n "$WORLD_SEED" ] && echo "    Seed: ${WORLD_SEED}"
  echo "    CustomScenario: \"$(q "${SCENARIO_NAME}")\""
} > "$CFG_GEN"

# -------- Steam login flow (live output, mobile auto-detect, code fallback) --------
UPDATE_LOGIN_ARGS="+login anonymous"

if [ -n "$STEAM_USER" ] && [ -n "$STEAM_PASS" ]; then
  TOKEN_OK=0
  if [ -f "$LOGINUSERS" ] && grep -q "$STEAM_USER" "$LOGINUSERS"; then
    TOKEN_OK=1
  fi

  if [ "$TOKEN_OK" = "1" ]; then
    echo "[SteamCMD] Cached login found for $STEAM_USER."
    UPDATE_LOGIN_ARGS="+login $STEAM_USER"
  else
    echo "[SteamCMD] Attempting login for $STEAM_USER (live output)…"
    # Run in foreground with line-buffering so logs stream live
    # Capture to file for pattern checks after it exits.
    stdbuf -oL -eL "$STEAMCMD_BIN" +@sSteamCmdForcePlatformType windows \
      +login "$STEAM_USER" "$STEAM_PASS" +quit | tee /tmp/steam_login.log
    LOGIN_RC=${PIPESTATUS[0]}

    # Pattern detection
    HAS_MOBILE=1; grep -qi 'Please confirm the login in the Steam Mobile app' /tmp/steam_login.log && HAS_MOBILE=0
    MOBILE_OK=1;   grep -qi 'Waiting for confirmation...OK' /tmp/steam_login.log && MOBILE_OK=0
    HAS_CODE=1;    grep -qiE 'Steam Guard|Two-factor|requires your authorization code' /tmp/steam_login.log && HAS_CODE=0
    MOBILE_TIMEOUT=1; grep -qiE 'Timed out waiting for confirmation|Timeout' /tmp/steam_login.log && MOBILE_TIMEOUT=0
    LOGIN_OK=1;    grep -qiE 'Logging in user.*OK|Waiting for user info...OK' /tmp/steam_login.log && LOGIN_OK=0

    # If mobile approved or login success, we're good — no code prompt needed.
    if [ "$MOBILE_OK" = "0" ] || [ "$LOGIN_OK" = "0" ]; then
      echo "[SteamCMD] Mobile confirmation approved (or cached success)."
      UPDATE_LOGIN_ARGS="+login $STEAM_USER"

    # If Steam asks for a code (email/OTP), allow a 120s interactive prompt.
    elif [ "$HAS_CODE" = "0" ] && [ "$MOBILE_TIMEOUT" != "0" ]; then
      echo
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo "/!\\ CAREFUL! DO NOT USE YOUR PERSONAL STEAM ACCOUNT HERE."
      echo "Credentials are stored in plaintext on the server. Use a secondary account."
      echo "You can grant access via Steam Family Sharing if needed."
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo
      echo "[SteamCMD] Enter Steam Guard code in this console as:  STEAMCODE ABCDEF"
      echo "[SteamCMD] Waiting up to 120 seconds for a code…"
      GUARD_CAPTURE=""
      end=$((SECONDS+120))
      while [ $SECONDS -lt $end ]; do
        IFS= read -r -t 1 line || true
        case "$line" in
          STEAMCODE\ *) GUARD_CAPTURE="${line#STEAMCODE }"; break ;;
        esac
      done
      if [ -n "$GUARD_CAPTURE" ]; then
        stdbuf -oL -eL "$STEAMCMD_BIN" +@sSteamCmdForcePlatformType windows \
          +login "$STEAM_USER" "$STEAM_PASS" "$GUARD_CAPTURE" +quit | tee /tmp/steam_login2.log
        UPDATE_LOGIN_ARGS="+login $STEAM_USER"
      else
        echo "[SteamCMD] No guard code entered. Proceeding ANONYMOUS to avoid hanging the restart."
        UPDATE_LOGIN_ARGS="+login anonymous"
      fi

    # If mobile flow timed out or anything else, fall back to anonymous.
    else
      echo "[SteamCMD] No cached login and no mobile/code approval. Proceeding ANONYMOUS."
      UPDATE_LOGIN_ARGS="+login anonymous"
    fi
  fi
fi

# -------- Install/Update server and (optionally) workshop --------
"$STEAMCMD_BIN" +@sSteamCmdForcePlatformType windows \
  $UPDATE_LOGIN_ARGS +app_update 530870 $BETACMD $STEAMCMD +quit

# -------- Runtime env --------
mkdir -p "$GAMEDIR/Logs"
rm -f /tmp/.X1-lock
Xvfb :1 -screen 0 800x600x24 &
export WINEDLLOVERRIDES="mscoree,mshtml="
export DISPLAY=:1

# -------- Tail logs to panel (background) --------
cd "$GAMEDIR"
[ "$1" = "bash" ] && exec "$@"

sh -c 'until [ "`netstat -ntl | tail -n+3`" ]; do sleep 1; done; sleep 5; tail -F Logs/current.log ../Logs/*/*.log 2>/dev/null' &

# -------- Console → Telnet bridge (only if Telnet enabled) --------
if [ "$TELNET_ENABLED" = "1" ] && [ -n "$TELNET_PORT" ]; then
  echo "[ConsoleBridge] Forwarding panel input to Telnet at 127.0.0.1:$TELNET_PORT"
  (
    sleep 6
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if exec 3<>/dev/tcp/127.0.0.1/"$TELNET_PORT"; then
        [ -n "$TELNET_PASSWORD" ] && printf "%s\r\n" "$TELNET_PASSWORD" >&3
        printf "%s\r\n" "$line" >&3
        timeout 2 cat <&3 || true
        printf "exit\r\n" >&3 || true
        exec 3>&- 3<&-
      else
        echo "[ConsoleBridge] Telnet connect failed (is Telnet enabled and port ${TELNET_PORT} open?)"
        sleep 2
      fi
    done
  ) < /dev/stdin &
fi

# -------- Start server (foreground for Wings) --------
exec /usr/lib/wine/wine64 ./EmpyrionDedicated.exe -batchmode -nographics -logFile Logs/current.log -dedicated "$(basename "$CFG_GEN")"
