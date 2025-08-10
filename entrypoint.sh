#!/bin/bash -ex

export HOME=/home/container
cd "$HOME"

# 3) Optional: workshop scenario download via STEAMCMD runscript
if [ -n "$SCENARIO_WORKSHOP_ID" ]; then
  mkdir -p "$HOME/Steam"
  printf 'workshop_download_item 383120 %s\n' "$SCENARIO_WORKSHOP_ID" > "$HOME/Steam/add_scenario.txt"
  if [ -z "$STEAMCMD" ]; then
    STEAMCMD="+runscript $HOME/Steam/add_scenario.txt"
  else
    STEAMCMD="$STEAMCMD +runscript $HOME/Steam/add_scenario.txt"
  fi
fi

# 4) Beta flag
BETACMD=""
if [ "$BETA" = "1" ]; then
  BETACMD="-beta experimental"
fi

# 5) Game dir
GAMEDIR="$HOME/Steam/steamapps/common/Empyrion - Dedicated Server/DedicatedServer"

# === Generate dedicated-generated.yaml from panel vars ===
CFG_DIR="$GAMEDIR"
CFG_GEN="$CFG_DIR/dedicated-generated.yaml"
mkdir -p "$CFG_DIR"

q() { printf %s "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

pw=; [ -n "$SRV_PASSWORD" ] && pw="\"$(q "$SRV_PASSWORD")\""
tnpw=; [ -n "$TELNET_PASSWORD" ] && tnpw="\"$(q "$TELNET_PASSWORD")\""
stp=; [ -n "$SRV_STOP_PERIOD" ] && stp="$SRV_STOP_PERIOD"
seed=; [ -n "$WORLD_SEED" ] && seed="$WORLD_SEED"
desc=; [ -n "$SRV_DESCRIPTION" ] && desc="\"$(q "$SRV_DESCRIPTION")\""
vip=; [ -n "$PLAYER_LOGIN_VIP_NAMES" ] && vip="\"$(q "$PLAYER_LOGIN_VIP_NAMES")\""

PORT_VALUE="${SERVER_PORT:-30000}"

cat > "$CFG_GEN" <<EOF
ServerConfig:
    Srv_Port: ${PORT_VALUE}
    Srv_Name: "$(q "$SERVER_NAME")"
    Srv_Password: ${pw}
    Srv_MaxPlayers: ${MAX_PLAYERS}
    Srv_ReservePlayfields: ${SRV_RESERVE_PLAYFIELDS}
    Srv_Description: ${desc}
    Srv_Public: ${SRV_PUBLIC}
    Srv_StopPeriod: ${stp}
    Tel_Enabled: ${TELNET_ENABLED}
    Tel_Port: ${TELNET_PORT}
    Tel_Pwd: ${tnpw}
    EACActive: ${EAC_ACTIVE}
    MaxAllowedSizeClass: ${MAX_ALLOWED_SIZE_CLASS}
    AllowedBlueprints: ${ALLOWED_BLUEPRINTS}
    HeartbeatServer: ${HEARTBEAT_SERVER}
    HeartbeatClient: ${HEARTBEAT_CLIENT}
    LogFlags: ${LOG_FLAGS}
    DisableSteamFamilySharing: ${DISABLE_FAMILY_SHARING}
    KickPlayerWithPing: ${KICK_PLAYER_WITH_PING}
    TimeoutBootingPfServer: ${TIMEOUT_BOOTING_PF}
    PlayerLoginParallelCount: ${PLAYER_LOGIN_PARALLEL_COUNT}
    PlayerLoginVipNames: ${vip}
    EnableDLC: ${ENABLE_DLC}

GameConfig:
    GameName: "$(q "$GAME_NAME")"
    Mode: ${GAME_MODE}
    Seed: ${seed}
    CustomScenario: "$(q "$SCENARIO_NAME")"
EOF

EXTRA_ARGS=""
[ "$USE_PANEL_CONFIG" = "true" ] && EXTRA_ARGS="-dedicated $(basename "$CFG_GEN")"

# 6) Install/Update server
STEAMCMD_BIN="/opt/steamcmd/steamcmd.sh"
"$STEAMCMD_BIN" +@sSteamCmdForcePlatformType windows +login anonymous +app_update 530870 $BETACMD $STEAMCMD +quit

# 7) Prepare runtime env
mkdir -p "$GAMEDIR/Logs"
rm -f /tmp/.X1-lock
Xvfb :1 -screen 0 800x600x24 &
export WINEDLLOVERRIDES="mscoree,mshtml="
export DISPLAY=:1

# 8) Tail logs and start server
cd "$GAMEDIR"
[ "$1" = "bash" ] && exec "$@"

sh -c 'until [ "`netstat -ntl | tail -n+3`" ]; do sleep 1; done
sleep 5
tail -F Logs/current.log ../Logs/*/*.log 2>/dev/null' &

/usr/lib/wine/wine64 ./EmpyrionDedicated.exe -batchmode -nographics -logFile Logs/current.log $EXTRA_ARGS "$@" &> Logs/wine.log
