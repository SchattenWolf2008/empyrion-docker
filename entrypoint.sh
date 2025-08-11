#!/bin/bash -ex

export HOME=/home/container
cd "$HOME"

# -------- helpers --------
q() { printf %s "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }      # YAML escape
bool() { [ "$1" = "1" ] && echo "true" || echo "false"; }  # 0/1 -> true/false

# Make sure Steam dir exists (persistent under Pterodactyl)
mkdir -p "$HOME/Steam"

# -------- workshop runscript (optional) --------
if [ -n "$SCENARIO_WORKSHOP_ID" ]; then
  printf 'workshop_download_item 383120 %s\n' "$SCENARIO_WORKSHOP_ID" > "$HOME/Steam/add_scenario.txt"
  if [ -z "$STEAMCMD" ]; then
    STEAMCMD="+runscript $HOME/Steam/add_scenario.txt"
  else
    STEAMCMD="$STEAMCMD +runscript $HOME/Steam/add_scenario.txt"
  fi
fi

# -------- beta flag --------
BETACMD=""
[ "$BETA" = "1" ] && BETACMD="-beta experimental"

# -------- paths --------
BASE_DIR="$HOME/Steam/steamapps/common/Empyrion - Dedicated Server"
GAMEDIR="$BASE_DIR/DedicatedServer"
CFG_DIR="$BASE_DIR"
CFG_GEN="$CFG_DIR/dedicated-generated.yaml"
mkdir -p "$CFG_DIR" "$GAMEDIR/Logs"

# -------- generate dedicated-generated.yaml --------
{
  echo "ServerConfig:"
  echo "    Srv_Port: ${SRV_PORT:-30000}"
  echo "    Srv_Name: \"$(q "$SERVER_NAME")\""
  [ -n "$SRV_PASSWORD" ] && echo "    Srv_Password: \"$(q "$SRV_PASSWORD")\""
  echo "    Srv_MaxPlayers: ${MAX_PLAYERS}"
  echo "    Srv_ReservePlayfields: ${SRV_RESERVE_PLAYFIELDS}"
  [ -n "$SRV_DESCRIPTION" ] && echo "    Srv_Description: \"$(q "$SRV_DESCRIPTION")\""
  echo "    Srv_Public: $(bool "$SRV_PUBLIC")"
  [ -n "$SRV_STOP_PERIOD" ] && echo "    Srv_StopPeriod: ${SRV_STOP_PERIOD}"
  echo "    Tel_Enabled: $(bool "$TELNET_ENABLED")"
  echo "    Tel_Port: ${TELNET_PORT}"
  [ -n "$TELNET_PASSWORD" ] && echo "    Tel_Pwd: \"$(q "$TELNET_PASSWORD")\""
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
  [ -n "$PLAYER_LOGIN_VIP_NAMES" ] && echo "    PlayerLoginVipNames: \"$(q "$PLAYER_LOGIN_VIP_NAMES")\""
  echo "    EnableDLC: $(bool "$ENABLE_DLC")"
  echo
  echo "GameConfig:"
  echo "    GameName: \"$(q "$GAME_NAME")\""
  echo "    Mode: ${GAME_MODE}"
  [ -n "$WORLD_SEED" ] && echo "    Seed: ${WORLD_SEED}"
  echo "    CustomScenario: \"$(q "$SCENARIO_NAME")\""
} > "$CFG_GEN"

EXTRA_ARGS=""
[ "$USE_PANEL_CONFIG" = "1" ] && EXTRA_ARGS="-dedicated $(basename "$CFG_GEN")"

# -------- SteamCMD wrappers --------
STEAMCMD_BIN="/opt/steamcmd/steamcmd.sh"
SCMD="stdbuf -oL -eL $STEAMCMD_BIN"   # line-buffer stdout/stderr so logs stream

tail_scmd_logs_start() {
  SCMD_ERR="$HOME/Steam/logs/stderr.txt"
  mkdir -p "$(dirname "$SCMD_ERR")"
  : > "$SCMD_ERR" || true
  tail -F "$SCMD_ERR" 2>/dev/null & TAILPID=$!
}
tail_scmd_logs_stop() { [ -n "$TAILPID" ] && kill "$TAILPID" 2>/dev/null || true; unset TAILPID; }

# -------- Steam login flow (cached -> full -> code -> anon) --------
UPDATE_LOGIN_ARGS="+login anonymous"

if [ "$STEAM_LOGIN" = "1" ]; then
  if [ -z "$STEAM_USERNAME" ] || [ -z "$STEAM_PASSWORD" ]; then
    echo "[SteamCMD] STEAM_LOGIN=1 but username or password is empty. Using anonymous."
    $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
  else
    echo "[SteamCMD] Attempting cached login for $STEAM_USERNAME ..."
    tail_scmd_logs_start
    $SCMD +@sSteamCmdForcePlatformType windows +login "$STEAM_USERNAME" +quit | tee /tmp/steam_token_login.log || true
    tail_scmd_logs_stop

    if grep -qi 'Logging in using cached credentials' /tmp/steam_token_login.log && \
       ! grep -qiE 'Steam Guard|Two-factor|enter your password|requires your authorization code|Please confirm the login in the Steam Mobile app' /tmp/steam_token_login.log; then
      echo "[SteamCMD] Cached login OK."
      UPDATE_LOGIN_ARGS="+login $STEAM_USERNAME"
    else
      echo "[SteamCMD] Cached login not available. Doing full login..."
      tail_scmd_logs_start
      $SCMD +@sSteamCmdForcePlatformType windows +login "$STEAM_USERNAME" "$STEAM_PASSWORD" +quit | tee /tmp/steam_login.log || true
      tail_scmd_logs_stop

      HAS_MOBILE=$(grep -qi 'Please confirm the login in the Steam Mobile app' /tmp/steam_login.log; echo $?)
      HAS_CODE=$(grep -qiE 'Steam Guard|Two-factor|requires your authorization code' /tmp/steam_login.log; echo $?)
      MOBILE_OK=$(grep -qi 'Waiting for confirmation...OK' /tmp/steam_login.log; echo $?)
      MOBILE_TIMEOUT=$(grep -qiE 'Timed out waiting for confirmation|Timeout' /tmp/steam_login.log; echo $?)

      if [ "$HAS_MOBILE" = "0" ]; then
        if [ "$MOBILE_OK" = "0" ]; then
          echo "[SteamCMD] Mobile confirmation approved."
          UPDATE_LOGIN_ARGS="+login $STEAM_USERNAME"
        elif [ "$MOBILE_TIMEOUT" = "0" ]; then
          echo "[SteamCMD] Mobile confirmation timed out. Going anonymous for this run."
          $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
          UPDATE_LOGIN_ARGS="+login anonymous"
        else
          echo "[SteamCMD] Mobile confirmation uncertain; using anonymous this run."
          $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
          UPDATE_LOGIN_ARGS="+login anonymous"
        fi

      elif [ "$HAS_CODE" = "0" ]; then
        echo ""
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "/!\\ CAREFUL! DO NOT USE YOUR PERSONAL STEAM ACCOUNT HERE."
        echo "Credentials are stored in plaintext on the server. Use a secondary account."
        echo "You can grant access via Steam Family Sharing if needed."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo ""
        echo "[SteamCMD] Enter Steam Guard code in this console as:  STEAMCODE ABCDEF"
        echo "[SteamCMD] Waiting up to 120 seconds for a code..."

        GUARD_CAPTURE=""
        end=$((SECONDS+120))
        while [ $SECONDS -lt $end ]; do
          if IFS= read -r -t 1 line; then
            case "$line" in
              STEAMCODE\ *) GUARD_CAPTURE="${line#STEAMCODE }"; break ;;
            esac
          fi
        done

        if [ -n "$GUARD_CAPTURE" ]; then
          echo "[SteamCMD] Got code. Retrying login..."
          tail_scmd_logs_start
          $SCMD +@sSteamCmdForcePlatformType windows +set_steam_guard_code "$GUARD_CAPTURE" +login "$STEAM_USERNAME" "$STEAM_PASSWORD" +quit | tee /tmp/steam_login_2.log || true
          tail_scmd_logs_stop
          UPDATE_LOGIN_ARGS="+set_steam_guard_code $GUARD_CAPTURE +login $STEAM_USERNAME $STEAM_PASSWORD"
        else
          echo "[SteamCMD] No code entered. Proceeding ANONYMOUS to avoid hanging the restart."
          $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
          UPDATE_LOGIN_ARGS="+login anonymous"
        fi
      else
        UPDATE_LOGIN_ARGS="+login $STEAM_USERNAME $STEAM_PASSWORD"
      fi
    fi
  fi
else
  $SCMD +@sSteamCmdForcePlatformType windows +logout +quit || true
  $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
  UPDATE_LOGIN_ARGS="+login anonymous"
fi

# -------- Install/Update --------
$SCMD +@sSteamCmdForcePlatformType windows $UPDATE_LOGIN_ARGS +app_update 530870 $BETACMD $STEAMCMD +quit

# -------- Wine/X env --------
rm -f /tmp/.X1-lock
Xvfb :1 -screen 0 800x600x24 &
export WINEDLLOVERRIDES="mscoree,mshtml="
export DISPLAY=:1

# -------- Tail game logs to panel --------
cd "$GAMEDIR"
[ "$1" = "bash" ] && exec "$@"

sh -c 'until [ "`netstat -ntl | tail -n+3`" ]; do sleep 1; done
sleep 5
tail -F Logs/current.log ../Logs/*/*.log 2>/dev/null' &

# -------- Panel console -> Telnet (if enabled) --------
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

# -------- Start server (foreground) --------
exec /usr/lib/wine/wine64 ./EmpyrionDedicated.exe -batchmode -nographics -logFile Logs/current.log $EXTRA_ARGS "$@" &> Logs/wine.log
