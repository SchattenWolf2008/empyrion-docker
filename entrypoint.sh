#!/bin/bash -ex

export HOME=/home/container
cd "$HOME"

# ---------- Persist Steam data across rebuilds ----------
# Use a persistent dir and symlink $HOME/Steam -> /mnt/server/steam
PERSIST_STEAM="/mnt/server/steam"
mkdir -p "$PERSIST_STEAM"

if [ -e "$HOME/Steam" ] && [ ! -L "$HOME/Steam" ]; then
  # Move existing Steam dir to persistent location (first run)
  mv "$HOME/Steam" "$PERSIST_STEAM"/
fi
if [ ! -e "$HOME/Steam" ]; then
  ln -s "$PERSIST_STEAM" "$HOME/Steam"
fi

# Helper for YAML escaping
q() { printf %s "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Helper to convert 0/1 → true/false
bool() { [ "$1" = "1" ] && echo "true" || echo "false"; }

# Workshop scenario (+runscript for steamcmd)
if [ -n "$SCENARIO_WORKSHOP_ID" ]; then
  mkdir -p "$HOME/Steam"
  printf 'workshop_download_item 383120 %s\n' "$SCENARIO_WORKSHOP_ID" > "$HOME/Steam/add_scenario.txt"
  if [ -z "$STEAMCMD" ]; then
    STEAMCMD="+runscript $HOME/Steam/add_scenario.txt"
  else
    STEAMCMD="$STEAMCMD +runscript $HOME/Steam/add_scenario.txt"
  fi
fi

# Beta flag
BETACMD=""
if [ "$BETA" = "1" ]; then
  BETACMD="-beta experimental"
fi

# Game dirs
BASE_DIR="$HOME/Steam/steamapps/common/Empyrion - Dedicated Server"
GAMEDIR="$BASE_DIR/DedicatedServer"

# === Generate dedicated-generated.yaml from panel vars ===
CFG_DIR="$BASE_DIR"
CFG_GEN="$CFG_DIR/dedicated-generated.yaml"
mkdir -p "$CFG_DIR"

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

# Pass -dedicated only if toggle is 1
EXTRA_ARGS=""
if [ "$USE_PANEL_CONFIG" = "1" ]; then
  EXTRA_ARGS="-dedicated $(basename "$CFG_GEN")"
fi

# SteamCMD binary (+ line-buffer)
STEAMCMD_BIN="/opt/steamcmd/steamcmd.sh"
SCMD="stdbuf -oL -eL $STEAMCMD_BIN"   # force line-by-line stdout/stderr

# --- SteamCMD login flow (token -> full -> anonymous) ---
UPDATE_LOGIN_ARGS="+login anonymous"   # safe default
LOGINUSERS="$HOME/Steam/config/loginusers.vdf"

if [ "$STEAM_LOGIN" = "1" ]; then
  if [ -z "$STEAM_USERNAME" ] || [ -z "$STEAM_PASSWORD" ]; then
    echo "[SteamCMD] STEAM_LOGIN=1 but username or password is empty. Using anonymous."
    $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
  else
    # 1) Token-based login if we appear to have cached credentials
    TOKEN_OK=0
    if [ -f "$LOGINUSERS" ] && grep -qi "\"AccountName\"[[:space:]]*\"$STEAM_USERNAME\"" "$LOGINUSERS"; then
      echo "[SteamCMD] Attempting token login for $STEAM_USERNAME ..."
      $SCMD +@sSteamCmdForcePlatformType windows +login "$STEAM_USERNAME" +quit \
        | tee /tmp/steam_token_login.log || true

      if ! grep -qiE 'Steam Guard|Two-factor|password|enter your password|requires your authorization code|Please confirm the login in the Steam Mobile app' /tmp/steam_token_login.log; then
        TOKEN_OK=1
        UPDATE_LOGIN_ARGS="+login $STEAM_USERNAME"
        echo "[SteamCMD] Token login OK."
      else
        echo "[SteamCMD] Token login not valid; will attempt full login."
      fi
    fi

    # 2) Full login with password if token didn’t work
    if [ "$TOKEN_OK" != "1" ]; then
      $SCMD +@sSteamCmdForcePlatformType windows +login "$STEAM_USERNAME" "$STEAM_PASSWORD" +quit \
        | tee /tmp/steam_login.log || true

      HAS_MOBILE=$(grep -qi 'Please confirm the login in the Steam Mobile app' /tmp/steam_login.log; echo $?)
      HAS_CODE=$(grep -qiE 'Steam Guard|Two-factor|requires your authorization code' /tmp/steam_login.log; echo $?)
      MOBILE_OK=$(grep -qi 'Waiting for confirmation...OK' /tmp/steam_login.log; echo $?)
      MOBILE_TIMEOUT=$(grep -qiE 'Timed out waiting for confirmation|Timeout' /tmp/steam_login.log; echo $?)

      if [ "$HAS_MOBILE" = "0" ]; then
        # Mobile app approval path; steamcmd already waited; just branch on result
        if [ "$MOBILE_OK" = "0" ]; then
          echo "[SteamCMD] Mobile confirmation approved."
          UPDATE_LOGIN_ARGS="+login $STEAM_USERNAME"
        elif [ "$MOBILE_TIMEOUT" = "0" ]; then
          echo "[SteamCMD] Mobile confirmation timed out. Falling back to anonymous."
          $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
          UPDATE_LOGIN_ARGS="+login anonymous"
        else
          echo "[SteamCMD] Mobile confirmation state unclear; using anonymous this run."
          $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
          UPDATE_LOGIN_ARGS="+login anonymous"
        fi

      elif [ "$HAS_CODE" = "0" ]; then
        # Email/2FA code flow (NOT mobile)
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
          STEAM_GUARD_CODE="$GUARD_CAPTURE"
          $SCMD +@sSteamCmdForcePlatformType windows \
            +set_steam_guard_code "$STEAM_GUARD_CODE" \
            +login "$STEAM_USERNAME" "$STEAM_PASSWORD" +quit \
            | tee /tmp/steam_login_2.log || true
          UPDATE_LOGIN_ARGS="+set_steam_guard_code $STEAM_GUARD_CODE +login $STEAM_USERNAME $STEAM_PASSWORD"
        else
          echo "[SteamCMD] No code entered. Proceeding ANONYMOUS to avoid hanging the restart."
          $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
          UPDATE_LOGIN_ARGS="+login anonymous"
        fi

      else
        # No guard required
        UPDATE_LOGIN_ARGS="+login $STEAM_USERNAME $STEAM_PASSWORD"
      fi
    fi
  fi
else
  # If user disabled account login, ensure no old session lingers.
  $SCMD +@sSteamCmdForcePlatformType windows +logout +quit || true
  $SCMD +@sSteamCmdForcePlatformType windows +login anonymous +quit || true
  UPDATE_LOGIN_ARGS="+login anonymous"
fi

# --- Install/Update server with resolved login ---
$SCMD +@sSteamCmdForcePlatformType windows $UPDATE_LOGIN_ARGS +app_update 530870 $BETACMD $STEAMCMD +quit

# Runtime env
mkdir -p "$GAMEDIR/Logs"
rm -f /tmp/.X1-lock
Xvfb :1 -screen 0 800x600x24 &
export WINEDLLOVERRIDES="mscoree,mshtml="
export DISPLAY=:1

# Tail logs to panel (background)
cd "$GAMEDIR"
[ "$1" = "bash" ] && exec "$@"

sh -c 'until [ "`netstat -ntl | tail -n+3`" ]; do sleep 1; done
sleep 5
tail -F Logs/current.log ../Logs/*/*.log 2>/dev/null' &

# Console → Telnet bridge (if enabled)
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

# Start server in foreground so Wings tracks it
exec /usr/lib/wine/wine64 ./EmpyrionDedicated.exe -batchmode -nographics -logFile Logs/current.log $EXTRA_ARGS "$@" &> Logs/wine.log
