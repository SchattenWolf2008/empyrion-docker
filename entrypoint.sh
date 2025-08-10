#!/bin/bash -ex

export HOME=/home/container
cd "$HOME"

# Helper for YAML escaping
q() { printf %s "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Helper to convert 0/1 → true/false
bool() { [ "$1" = "1" ] && echo "true" || echo "false"; }

# Workshop scenario
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

# Install/update server
STEAMCMD_BIN="/opt/steamcmd/steamcmd.sh"
"$STEAMCMD_BIN" +@sSteamCmdForcePlatformType windows +login anonymous +app_update 530870 $BETACMD $STEAMCMD +quit

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

# Console → Telnet bridge (only if Telnet is enabled and port set)
if [ "$TELNET_ENABLED" = "1" ] && [ -n "$TELNET_PORT" ]; then
  echo "[ConsoleBridge] Forwarding panel input to Telnet at 127.0.0.1:$TELNET_PORT"
  (
    # small warm-up so the telnet listener is ready
    sleep 6
    # Read user input from panel console and forward per-command to Telnet
    while IFS= read -r line; do
      # skip blanks
      [ -z "$line" ] && continue

      # open TCP connection
      if exec 3<>/dev/tcp/127.0.0.1/"$TELNET_PORT"; then
        # send password if configured
        if [ -n "$TELNET_PASSWORD" ]; then
          printf "%s\r\n" "$TELNET_PASSWORD" >&3
        fi
        # send the command
        printf "%s\r\n" "$line" >&3

        # read a short response window so the panel shows feedback
        # (increase from 2 to 5 if you want longer output)
        timeout 2 cat <&3 || true

        # close session
        printf "exit\r\n" >&3 || true
        exec 3>&- 3<&-
      else
        echo "[ConsoleBridge] Telnet connect failed (is Telnet enabled and port ${TELNET_PORT} open?)"
        sleep 2
      fi
    done
  ) < /dev/stdin &
fi

# Start server in foreground (so Wings can track it)
exec /usr/lib/wine/wine64 ./EmpyrionDedicated.exe -batchmode -nographics -logFile Logs/current.log $EXTRA_ARGS "$@" &> Logs/wine.log
