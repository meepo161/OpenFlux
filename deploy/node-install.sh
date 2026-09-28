#!/bin/sh
# Managed by OpenFlux node-install.sh
#
# Installs one OpenFlux exit channel on a Linux VDS. The "Своя нода" wizard
# of the OpenFlux apps downloads this file by a pinned commit, checks
# its SHA-256 and runs it over SSH. Every channel is independent: its own
# transports (a Yandex document, a Mail.ru document, cups.online rooms, and
# always direct as the backup), key, port and systemd instance
# (openflux-node@<channel>). Nothing outside the paths below is touched, so
# existing services (other OpenFlux installs, Docker, VPNs) keep running.
#
#   /opt/openflux-node/bin/            core binaries (from GitHub Releases)
#   /opt/openflux-node/node-install.sh this script, for the updater
#   /etc/openflux-node/<channel>/      node.conf, encryption-key (0640), port,
#                                      firewall; the directory is 0751 so a
#                                      plain user's plan sees the channel and
#                                      its port but not its secrets
#   /var/lib/openflux-node/<channel>/  cookie store (systemd StateDirectory)
#   /etc/systemd/system/openflux-node@.service
#   /etc/systemd/system/openflux-node-update.{service,timer}
#                                      the core updater, when enabled
#
# Usage: node-install.sh probe
#        node-install.sh plan|status              (config on stdin)
#        node-install.sh apply|remove CONFIG_FILE (run as root)
#        node-install.sh upgrade                  (run as root: move every
#                                                 channel to this core)
#        node-install.sh set-cookies CONFIG_FILE  (run as root: replace a
#                                                 channel's Yandex login)
#        node-install.sh update                   (run as root, by the timer:
#                                                 move every channel to the
#                                                 newest node-v* release)
#        node-install.sh autoupdate on|off        (run as root: the updater)
# The config is "key=value" lines: channel, key, port, the transports
# (vyandex= or its old name url=: a Yandex document; mailru=: a Mail.ru
# public document; cupsonline=: the packed room list), autoupdate=yes|no,
# and optionally cookies: the channel's Yandex sign-in as the core's cookie store JSON,
# base64-encoded. It goes to /var/lib/openflux-node/<channel>/cookies.json
# (0600, owned by the node user) and is never printed. apply and remove
# take it from a 0600 temp file, which they delete after reading, so that
# stdin stays free for `sudo -S` (a wrong sudo password would otherwise make
# sudo read the config as further password attempts). Secrets never appear
# in arguments, so they stay out of ps and shell history.
# Output is one JSON object on stdout.

set -u
umask 077

CORE_VERSION="node-v1.1.0"
SHA_amd64="9ec36c073749c1d02ca163516ba6fc257cc624a69833fb108de65ba4400e8f41"
SHA_arm64="b6d74ae230d9f4711cc4e03ba19d9eb7b4e3987ae6eeb45f86257743da9623ed"
SHA_arm="77c5afa26566db77b465e26bc0bdcde55e9f2babb08b386953a3d2f769667cf8"
# The repository this script and its core come from: the core is one of its
# node-v* releases, and the updater follows them (UPDATE_CONF may override
# that with a "repo=owner/name" line).
RELEASE_REPO="p1neappleXpress/OpenFlux"
GITHUB_API="https://api.github.com"
GITHUB_RAW="https://raw.githubusercontent.com"
GITHUB_WEB="https://github.com"
CORE_BASE="$GITHUB_WEB/$RELEASE_REPO/releases/download/$CORE_VERSION"

BIN_DIR="/opt/openflux-node/bin"
CONF_ROOT="/etc/openflux-node"
STATE_ROOT="/var/lib/openflux-node"
UNIT_FILE="/etc/systemd/system/openflux-node@.service"
UPDATE_SERVICE="/etc/systemd/system/openflux-node-update.service"
UPDATE_TIMER="/etc/systemd/system/openflux-node-update.timer"
UPDATE_CONF="$CONF_ROOT/update.conf"
SELF_COPY="/opt/openflux-node/node-install.sh"
NODE_USER="openflux-node"
MARKER="# Managed by OpenFlux node-install.sh"

# ---- output -----------------------------------------------------------------

# fail STEP MESSAGE: prints the error object and exits. Messages are fixed
# strings or validated values, never secrets.
fail() {
    printf '{"ok":false,"step":"%s","error":"%s"}\n' "$1" "$(json_escape "$2")"
    exit 1
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t\r' '   '
}

json_list() {
    first=1
    printf '['
    for item in "$@"; do
        [ "$first" = 1 ] || printf ','
        printf '"%s"' "$(json_escape "$item")"
        first=0
    done
    printf ']'
}

# ---- environment ------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l|armv6l|armhf) echo arm ;;
        *) echo "" ;;
    esac
}

core_sha() {
    case "$1" in
        amd64) echo "$SHA_amd64" ;;
        arm64) echo "$SHA_arm64" ;;
        arm) echo "$SHA_arm" ;;
    esac
}

downloader() {
    if have curl; then echo curl; elif have wget; then echo wget; else echo ""; fi
}

fetch() { # URL DEST
    case "$(downloader)" in
        curl) curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1" ;;
        wget) wget -q -T 20 -t 3 -O "$2" "$1" ;;
        *) return 1 ;;
    esac
}

sha256_of() {
    if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
    else openssl dgst -sha256 "$1" | sed 's/.*= //'
    fi
}

firewall_kind() {
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then echo firewalld
    else echo none
    fi
}

sudo_mode() {
    if [ "$(id -u)" = 0 ]; then echo root
    elif ! have sudo; then echo none
    elif sudo -n true 2>/dev/null; then echo nopasswd
    else echo password
    fi
}

list_channels() {
    [ -d "$CONF_ROOT" ] || return 0
    for d in "$CONF_ROOT"/*/; do
        [ -d "$d" ] && basename "$d"
    done
}

# version_gt A B: whether release tag A (node-vX.Y.Z) is newer than B. An
# empty or malformed B counts as older than anything.
version_gt() {
    printf '%s\n%s\n' "${1#node-v}" "${2#node-v}" | awk -F. '
        NR == 1 { for (i = 1; i <= 3; i++) a[i] = $i + 0; ok = ($0 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) }
        NR == 2 { for (i = 1; i <= 3; i++) b[i] = $i + 0 }
        END {
            if (!ok) exit 1
            for (i = 1; i <= 3; i++) { if (a[i] > b[i]) exit 0; if (a[i] < b[i]) exit 1 }
            exit 1
        }'
}

# installed_core: the release BIN_DIR/openflux points at, "" if none.
installed_core() {
    target=$(readlink "$BIN_DIR/openflux" 2>/dev/null) || return 0
    case "$target" in
        openflux-node-v*) [ -x "$BIN_DIR/$target" ] && printf '%s' "${target#openflux-}" ;;
    esac
}

# managed_core REPO: installed_core, if this script or the updater put it
# there from REPO's releases (BIN_DIR/.managed lists "repo tag" lines).
# A core from anywhere else counts as none: another repository's release
# numbers, like an old fork's node-v1.4.0, say nothing about REPO's.
managed_core() {
    cur=$(installed_core)
    [ -n "$cur" ] && grep -qsxF "$1 $cur" "$BIN_DIR/.managed" && printf '%s' "$cur"
    return 0
}

# mark_managed REPO TAG: BIN_DIR/openflux-TAG is REPO's release now.
mark_managed() {
    { grep -sv " $2\$" "$BIN_DIR/.managed"; printf '%s %s\n' "$1" "$2"; } > "$BIN_DIR/.managed.new" \
        && mv -f "$BIN_DIR/.managed.new" "$BIN_DIR/.managed"
    # A plain user's plan reads it too.
    chmod 0644 "$BIN_DIR/.managed"
}

# core_to_use: this script's core, or the installed one when the updater has
# already moved the server to a newer release of the same repository (an
# older app must not downgrade every channel).
core_to_use() {
    cur=$(managed_core "$RELEASE_REPO")
    if [ -n "$cur" ] && version_gt "$cur" "$CORE_VERSION"; then printf '%s' "$cur"; else printf '%s' "$CORE_VERSION"; fi
}

autoupdate_on() {
    [ -f "$UPDATE_TIMER" ] && systemctl is-enabled --quiet openflux-node-update.timer 2>/dev/null
}

release_repo() {
    repo=$(sed -n 's/^repo=\([A-Za-z0-9_.-]*\/[A-Za-z0-9_.-]*\)$/\1/p' "$UPDATE_CONF" 2>/dev/null | tail -n 1)
    printf '%s' "${repo:-$RELEASE_REPO}"
}

port_busy() { # PORT
    if have ss; then
        [ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]
    elif have netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q "[:.]$1\$"
    else
        return 1
    fi
}

port_claimed() { # PORT: another of our channels is configured for it
    [ -d "$CONF_ROOT" ] || return 1
    grep -qsx "$1" "$CONF_ROOT"/*/port
}

pick_port() {
    seed=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
    i=0
    while [ $i -lt 200 ]; do
        p=$(( 20000 + (seed + i * 7919) % 40000 ))
        if ! port_busy "$p" && ! port_claimed "$p"; then echo "$p"; return 0; fi
        i=$((i + 1))
    done
    echo ""
}

# ---- input ------------------------------------------------------------------

CHANNEL=""; URL=""; MAILRU=""; CUPS=""; KEY=""; PORT=""; COOKIES=""; AUTOUPDATE=""

# read_config [FILE]: reads stdin, or FILE and then deletes it.
read_config() {
    if [ $# -gt 0 ]; then
        [ -f "$1" ] || fail input "нет файла конфигурации"
        read_config < "$1"
        rm -f "$1"
        return
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            channel=*) CHANNEL=${line#channel=} ;;
            url=*) URL=${line#url=} ;;
            vyandex=*) URL=${line#vyandex=} ;;
            mailru=*) MAILRU=${line#mailru=} ;;
            cupsonline=*) CUPS=${line#cupsonline=} ;;
            key=*) KEY=${line#key=} ;;
            port=*) PORT=${line#port=} ;;
            cookies=*) COOKIES=${line#cookies=} ;;
            autoupdate=*) AUTOUPDATE=${line#autoupdate=} ;;
            "") ;;
            *) fail input "неизвестная строка конфигурации" ;;
        esac
    done
}

valid_channel() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,30}$'; }
valid_key() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }
valid_url() {
    printf '%s' "$1" | grep -Eq '^https://(docs|disk)\.yandex\.(ru|com|by|kz|uz)/edit/d/[A-Za-z0-9_-]{16,200}$'
}
valid_mailru() {
    printf '%s' "$1" | grep -Eq '^https://cloud\.mail\.ru/public/[A-Za-z0-9_-]{2,64}/[A-Za-z0-9_-]{2,128}$'
}
# The cups.online room list: base64url of a JSON list of room ids.
valid_rooms() { [ ${#1} -ge 8 ] && [ ${#1} -le 4096 ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]+$'; }
valid_port() {
    printf '%s' "$1" | grep -Eq '^[0-9]{4,5}$' && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

# check_transports: validates the chosen transports (plan and apply).
check_transports() {
    [ -z "$URL" ] || valid_url "$URL" || fail input "адрес документа должен быть вида https://docs.yandex.ru/edit/d/..."
    [ -z "$MAILRU" ] || valid_mailru "$MAILRU" || fail input "ссылка Mail.ru должна быть вида https://cloud.mail.ru/public/..."
    [ -z "$CUPS" ] || valid_rooms "$CUPS" || fail input "неверный список комнат cups.online"
    [ -z "$COOKIES" ] || [ -n "$URL" ] || fail input "вход в Яндекс нужен только каналу с документом Яндекса"
    case "$AUTOUPDATE" in ""|yes|no) ;; *) fail input "autoupdate: yes или no" ;; esac
}

# transport_names: the channel's transports for people, primary first.
transport_names() {
    names=""
    [ -n "$URL" ] && names="Яндекс Документ"
    [ -n "$MAILRU" ] && names="${names:+$names, }Mail.ru Документ"
    [ -n "$CUPS" ] && names="${names:+$names, }cups.online"
    printf '%s' "$names"
}

# session_context: the encryption context both sides derive, as the core's
# pickSessionContext does: the highest-priority transport's URL, cups.online
# aside. "" leaves node.conf without a URL line (the core's "http://#").
session_context() {
    if [ -n "$URL" ]; then printf '%s' "$URL"; elif [ -n "$MAILRU" ]; then printf '%s' "$MAILRU"; fi
}

# write_cookies: decodes COOKIES into the channel's cookie store, which the
# node loads at start. Needs the node user to exist.
write_cookies() {
    printf '%s' "$COOKIES" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$' || return 1
    [ ${#COOKIES} -le 65536 ] || return 1
    dir="$STATE_ROOT/$CHANNEL"
    # umask 077 would make the parent 0700 and lock the node user out of
    # its own state directory (systemd only creates it when missing).
    mkdir -p "$STATE_ROOT" && chmod 0755 "$STATE_ROOT" || return 1
    mkdir -p "$dir" || return 1
    tmp="$dir/.cookies.json.new"
    if have base64; then
        printf '%s' "$COOKIES" | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    else
        printf '%s' "$COOKIES" | openssl base64 -d -A > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    fi
    head -c 1 "$tmp" | grep -q '{' || { rm -f "$tmp"; return 1; }
    chown "$NODE_USER:$NODE_USER" "$dir" "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$dir/cookies.json"
}

check_channel() {
    [ -n "$CHANNEL" ] || fail input "не указан канал"
    valid_channel "$CHANNEL" || fail input "имя канала: только a-z, 0-9 и дефис, до 31 символа"
}

# ---- commands ---------------------------------------------------------------

cmd_probe() {
    arch=$(detect_arch)
    systemd=false
    [ -d /run/systemd/system ] && have systemctl && systemd=true
    os=""
    [ -r /etc/os-release ] && os=$(. /etc/os-release && printf '%s %s' "${ID:-linux}" "${VERSION_ID:-}")
    autoupdate=false
    autoupdate_on && autoupdate=true
    # shellcheck disable=SC2046
    printf '{"ok":true,"arch":"%s","os":"%s","systemd":%s,"sudo":"%s","downloader":"%s","firewall":"%s","core":"%s","autoupdate":%s,"channels":%s}\n' \
        "$arch" "$(json_escape "$os")" "$systemd" "$(sudo_mode)" "$(downloader)" "$(firewall_kind)" \
        "$(core_to_use)" "$autoupdate" "$(json_list $(list_channels))"
}

# plan: read-only. Tells the app exactly what apply will change.
cmd_plan() {
    read_config
    check_channel
    check_transports
    arch=$(detect_arch)
    [ -n "$arch" ] || fail plan "архитектура $(uname -m) не поддерживается"
    [ -d /run/systemd/system ] && have systemctl || fail plan "на сервере нет systemd"
    [ -n "$(downloader)" ] || fail plan "на сервере нет curl или wget"
    [ -d "$CONF_ROOT/$CHANNEL" ] && fail plan "канал $CHANNEL уже существует на сервере"
    if [ -n "$PORT" ]; then
        valid_port "$PORT" || fail plan "порт должен быть в диапазоне 1024-65535"
        if port_busy "$PORT" || port_claimed "$PORT"; then fail plan "порт $PORT занят"; fi
    else
        PORT=$(pick_port)
        [ -n "$PORT" ] || fail plan "не удалось найти свободный порт"
    fi
    if [ -f "$UNIT_FILE" ] && ! grep -qF "$MARKER" "$UNIT_FILE"; then
        fail plan "$UNIT_FILE создан не мастером OpenFlux, не трогаю его"
    fi

    core=$(core_to_use)
    set --
    id "$NODE_USER" >/dev/null 2>&1 || set -- "$@" "Создать системного пользователя $NODE_USER (без входа и домашней папки)"
    # The installed file counts only if it is this release of RELEASE_REPO
    # (another repository may have a release with the same number).
    if [ "$core" != "$CORE_VERSION" ] || { [ -x "$BIN_DIR/openflux-$core" ] && [ "$(sha256_of "$BIN_DIR/openflux-$core")" = "$(core_sha "$arch")" ]; }; then
        set -- "$@" "Использовать уже установленное ядро OpenFlux $core ($RELEASE_REPO)"
    else
        set -- "$@" "Скачать ядро OpenFlux $core (linux-$arch) из релизов $RELEASE_REPO на GitHub и сверить SHA-256 в $BIN_DIR"
    fi
    set -- "$@" "Создать $CONF_ROOT/$CHANNEL: node.conf и ключ шифрования канала (права 0640)"
    [ -n "$COOKIES" ] && set -- "$@" "Сохранить вход в Яндекс для этого канала в $STATE_ROOT/$CHANNEL/cookies.json (права 0600, только для ноды)"
    [ -f "$UNIT_FILE" ] || set -- "$@" "Установить шаблон systemd $UNIT_FILE"
    names=$(transport_names)
    if [ -n "$names" ]; then
        set -- "$@" "Запустить openflux-node@$CHANNEL: $names и direct на порту $PORT/tcp (резерв)"
    else
        set -- "$@" "Запустить openflux-node@$CHANNEL: только direct на порту $PORT/tcp"
    fi
    case "$(firewall_kind)" in
        ufw) set -- "$@" "Разрешить входящий $PORT/tcp в ufw" ;;
        firewalld) set -- "$@" "Разрешить входящий $PORT/tcp в firewalld" ;;
    esac
    case "$AUTOUPDATE" in
        yes)
            if autoupdate_on; then
                set -- "$@" "Автообновление ядра уже включено на сервере (openflux-node-update.timer)"
            else
                set -- "$@" "Включить автообновление ядра (openflux-node-update.timer): раз в 6 часов проверять релизы node-v* в $(release_repo) на GitHub, сверять SHA-256, перезапускать каналы и откатываться, если нода не поднялась"
            fi ;;
        no)
            autoupdate_on && set -- "$@" "Выключить автообновление ядра на сервере (для всех каналов)" ;;
    esac

    # shellcheck disable=SC2046
    printf '{"ok":true,"channel":"%s","port":%s,"arch":"%s","core":"%s","actions":%s,"untouched":%s}\n' \
        "$CHANNEL" "$PORT" "$arch" "$core" "$(json_list "$@")" "$(json_list $(list_channels))"
}

# Rollback state for apply: what this run created.
CREATED_USER=0; CREATED_UNIT=0; CREATED_BIN=0; CREATED_CONF=0; CREATED_FW=""; STARTED=0

rollback() {
    [ "$STARTED" = 1 ] && systemctl disable --now "openflux-node@$CHANNEL" >/dev/null 2>&1
    case "$CREATED_FW" in
        ufw) ufw delete allow "$PORT/tcp" >/dev/null 2>&1 ;;
        firewalld) firewall-cmd --permanent --remove-port="$PORT/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 ;;
    esac
    [ "$CREATED_CONF" = 1 ] && rm -rf "${CONF_ROOT:?}/$CHANNEL" "${STATE_ROOT:?}/$CHANNEL"
    [ "$CREATED_UNIT" = 1 ] && rm -f "$UNIT_FILE" && systemctl daemon-reload >/dev/null 2>&1
    [ "$CREATED_BIN" = 1 ] && rm -f "$BIN_DIR/openflux-$CORE_VERSION"
    [ "$CREATED_USER" = 1 ] && userdel "$NODE_USER" >/dev/null 2>&1
}

apply_fail() {
    rollback
    fail "$1" "$2"
}

# install_core ARCH: puts this script's core version into BIN_DIR, checked
# against its pinned SHA-256, and points BIN_DIR/openflux at it. Sets
# CREATED_BIN when it downloaded, CORE_ERROR on failure.
CORE_ERROR=""
install_core() {
    mkdir -p "$BIN_DIR" && chmod 0755 /opt/openflux-node "$BIN_DIR"
    # The updater already runs a newer release: keep it.
    [ "$(core_to_use)" = "$CORE_VERSION" ] || return 0
    core="$BIN_DIR/openflux-$CORE_VERSION"
    want=$(core_sha "$1")
    if [ ! -x "$core" ] || [ "$(sha256_of "$core")" != "$want" ]; then
        tmp=$(mktemp "$BIN_DIR/.download.XXXXXX") || { CORE_ERROR="не удалось создать временный файл"; return 1; }
        if ! fetch "$CORE_BASE/openflux-linux-$1" "$tmp"; then
            rm -f "$tmp"
            CORE_ERROR="не удалось скачать ядро с GitHub"
            return 1
        fi
        if [ "$(sha256_of "$tmp")" != "$want" ]; then
            rm -f "$tmp"
            CORE_ERROR="SHA-256 скачанного ядра не совпал, установка остановлена"
            return 1
        fi
        chmod 0755 "$tmp" && mv -f "$tmp" "$core"
        CREATED_BIN=1
    fi
    ln -sfn "openflux-$CORE_VERSION" "$BIN_DIR/openflux"
    mark_managed "$RELEASE_REPO" "$CORE_VERSION"
}

write_unit() {
    cat > "$UNIT_FILE" <<EOF
$MARKER
[Unit]
Description=OpenFlux node channel %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NODE_USER
Group=$NODE_USER
StateDirectory=openflux-node/%i
WorkingDirectory=$STATE_ROOT/%i
ExecStart=$BIN_DIR/openflux --config $CONF_ROOT/%i/node.conf
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$UNIT_FILE"
}

# script_core FILE: the CORE_VERSION a copy of this script pins.
script_core() { sed -n 's/^CORE_VERSION="\(node-v[0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }

# script_repo FILE: the RELEASE_REPO a copy of this script follows.
script_repo() { sed -n 's/^RELEASE_REPO="\([^"]*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }

# install_self FILE: makes FILE the script the updater runs, unless the copy
# there follows the same repository and already pins a newer core (the
# updater put a newer release's script). A script from another repository
# always replaces it: the server now runs that repository's core.
install_self() {
    if [ -f "$SELF_COPY" ] && [ "$(script_repo "$SELF_COPY")" = "$(script_repo "$1")" ] &&
        version_gt "$(script_core "$SELF_COPY")" "$(script_core "$1")"; then
        return 0
    fi
    mkdir -p /opt/openflux-node && chmod 0755 /opt/openflux-node || return 1
    tmp=$(mktemp /opt/openflux-node/.node-install.XXXXXX) || return 1
    if cat "$1" > "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$SELF_COPY"; then return 0; fi
    rm -f "$tmp"
    return 1
}

# enable_updater: openflux-node-update.timer runs "update" from the copy of
# this script: shortly after boot or install, then every 6 hours.
enable_updater() {
    install_self "$0" || return 1
    cat > "$UPDATE_SERVICE" <<EOF
$MARKER
[Unit]
Description=Update the OpenFlux node core to the newest node-v* release
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh $SELF_COPY update
EOF
    cat > "$UPDATE_TIMER" <<EOF
$MARKER
[Unit]
Description=Check for a newer OpenFlux node core

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$UPDATE_SERVICE" "$UPDATE_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 && systemctl enable --now openflux-node-update.timer >/dev/null 2>&1
}

disable_updater() {
    systemctl disable --now openflux-node-update.timer >/dev/null 2>&1
    for f in "$UPDATE_TIMER" "$UPDATE_SERVICE"; do
        [ -f "$f" ] && grep -qF "$MARKER" "$f" && rm -f "$f"
    done
    rm -f "$SELF_COPY"
    systemctl daemon-reload >/dev/null 2>&1
}

# apply_autoupdate: AUTOUPDATE yes turns the updater on (and refreshes the
# script it runs), no turns it off; empty leaves it as it is.
apply_autoupdate() {
    case "$AUTOUPDATE" in
        yes) enable_updater ;;
        no) autoupdate_on && disable_updater; return 0 ;;
        *) autoupdate_on && install_self "$0"; return 0 ;;
    esac
}

# write_node_conf: the channel's node.conf on stdout. Priorities and the
# URL line (the encryption context) match what the app puts into the
# channel's link (provision.ShareLink).
write_node_conf() {
    cat <<EOF
# OpenFlux node channel $CHANNEL, written by node-install.sh
Role = exit
Mode = l4
EncryptionKeyFile = $CONF_ROOT/$CHANNEL/encryption-key
CookieStore = $STATE_ROOT/$CHANNEL/cookies.json
EOF
    context=$(session_context)
    [ -n "$context" ] && printf 'URL = %s\n' "$context"
    [ -n "$URL" ] && printf '\n[Transport vyandex]\nType = vyandex\nPriority = 100\nURL = %s\n' "$URL"
    [ -n "$MAILRU" ] && printf '\n[Transport mailru]\nType = mailru\nPriority = 90\nURL = %s\n' "$MAILRU"
    [ -n "$CUPS" ] && printf '\n[Transport cupsonline]\nType = cupsonline\nPriority = 70\nURL = %s\n' "$CUPS"
    printf '\n[Transport direct]\nType = direct\nPriority = 50\nListen = 0.0.0.0:%s\n' "$PORT"
}

cmd_apply() {
    [ "$(id -u)" = 0 ] || fail apply "нужны права root (sudo)"
    read_config "$@"
    check_channel
    valid_key "$KEY" || fail input "ключ канала должен быть 64 hex-символа"
    check_transports
    valid_port "$PORT" || fail input "не указан порт из плана"
    [ -z "$COOKIES" ] || printf '%s' "$COOKIES" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$' || fail input "cookies должны быть в base64"
    arch=$(detect_arch)
    [ -n "$arch" ] || fail apply "архитектура $(uname -m) не поддерживается"
    [ -d "$CONF_ROOT/$CHANNEL" ] && fail apply "канал $CHANNEL уже существует на сервере"
    if port_busy "$PORT" || port_claimed "$PORT"; then fail apply "порт $PORT занят"; fi
    if [ -f "$UNIT_FILE" ] && ! grep -qF "$MARKER" "$UNIT_FILE"; then
        fail apply "$UNIT_FILE создан не мастером OpenFlux"
    fi

    if ! id "$NODE_USER" >/dev/null 2>&1; then
        nologin=/usr/sbin/nologin
        [ -x "$nologin" ] || nologin=/sbin/nologin
        [ -x "$nologin" ] || nologin=/bin/false
        if have useradd; then
            useradd --system --no-create-home --home-dir /nonexistent --shell "$nologin" "$NODE_USER" \
                || apply_fail user "не удалось создать пользователя $NODE_USER"
        else
            adduser -S -H -D -s "$nologin" "$NODE_USER" 2>/dev/null \
                || apply_fail user "не удалось создать пользователя $NODE_USER"
        fi
        CREATED_USER=1
    fi

    install_core "$arch" || apply_fail download "$CORE_ERROR"

    mkdir -p "$CONF_ROOT" && chmod 0755 "$CONF_ROOT"
    dir="$CONF_ROOT/$CHANNEL"
    mkdir "$dir" || apply_fail config "не удалось создать $dir"
    CREATED_CONF=1
    printf '%s\n' "$KEY" > "$dir/encryption-key"
    write_node_conf > "$dir/node.conf"
    printf '%s\n' "$PORT" > "$dir/port"
    chown -R "root:$NODE_USER" "$dir"
    chmod 0751 "$dir"
    chmod 0640 "$dir/encryption-key" "$dir/node.conf"
    chmod 0644 "$dir/port"
    if [ -n "$COOKIES" ]; then
        write_cookies || apply_fail cookies "не удалось сохранить вход в Яндекс на сервере"
    fi

    if [ ! -f "$UNIT_FILE" ]; then
        write_unit
        CREATED_UNIT=1
    fi
    systemctl daemon-reload || apply_fail systemd "systemctl daemon-reload не удался"

    case "$(firewall_kind)" in
        ufw)
            ufw allow "$PORT/tcp" comment "openflux-node $CHANNEL" >/dev/null 2>&1 \
                || apply_fail firewall "не удалось открыть порт в ufw"
            CREATED_FW=ufw ;;
        firewalld)
            { firewall-cmd --permanent --add-port="$PORT/tcp" && firewall-cmd --reload; } >/dev/null 2>&1 \
                || apply_fail firewall "не удалось открыть порт в firewalld"
            CREATED_FW=firewalld ;;
    esac
    [ -n "$CREATED_FW" ] && printf '%s %s\n' "$CREATED_FW" "$PORT" > "$dir/firewall"

    systemctl enable --now "openflux-node@$CHANNEL" >/dev/null 2>&1 \
        || apply_fail start "не удалось запустить openflux-node@$CHANNEL"
    STARTED=1
    sleep 4
    if ! systemctl is-active --quiet "openflux-node@$CHANNEL"; then
        logs=$(journalctl -u "openflux-node@$CHANNEL" -n 8 -o cat --no-pager 2>/dev/null | tail -n 8)
        apply_fail start "нода не запустилась: $logs"
    fi
    # The channel runs; the updater is extra, and its failure only shows.
    autoupdate=false
    apply_autoupdate
    autoupdate_on && autoupdate=true
    printf '{"ok":true,"channel":"%s","port":%s,"core":"%s","autoupdate":%s}\n' "$CHANNEL" "$PORT" "$(core_to_use)" "$autoupdate"
}

cmd_remove() {
    [ "$(id -u)" = 0 ] || fail remove "нужны права root (sudo)"
    read_config "$@"
    check_channel
    dir="$CONF_ROOT/$CHANNEL"
    [ -d "$dir" ] || fail remove "канала $CHANNEL нет на сервере"
    systemctl disable --now "openflux-node@$CHANNEL" >/dev/null 2>&1
    if [ -f "$dir/firewall" ]; then
        read -r kind port < "$dir/firewall"
        case "$kind" in
            ufw) ufw delete allow "$port/tcp" >/dev/null 2>&1 ;;
            firewalld) firewall-cmd --permanent --remove-port="$port/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 ;;
        esac
    fi
    rm -rf "${CONF_ROOT:?}/$CHANNEL" "${STATE_ROOT:?}/$CHANNEL"
    if [ -z "$(list_channels)" ]; then
        # The last channel is gone: remove everything this script installed.
        disable_updater
        rm -f "$UNIT_FILE"
        systemctl daemon-reload >/dev/null 2>&1
        rm -rf /opt/openflux-node "$CONF_ROOT" "$STATE_ROOT"
        userdel "$NODE_USER" >/dev/null 2>&1
    fi
    printf '{"ok":true,"channel":"%s"}\n' "$CHANNEL"
}

# upgrade: switches every channel to this script's core and restarts the
# running ones. Configs, keys and ports stay as they are.
cmd_upgrade() {
    [ "$(id -u)" = 0 ] || fail upgrade "нужны права root (sudo)"
    [ -n "$(list_channels)" ] || fail upgrade "на сервере нет каналов OpenFlux"
    arch=$(detect_arch)
    [ -n "$arch" ] || fail upgrade "архитектура $(uname -m) не поддерживается"
    install_core "$arch" || fail upgrade "$CORE_ERROR"
    set --
    for ch in $(list_channels); do
        if systemctl is-active --quiet "openflux-node@$ch"; then
            systemctl restart "openflux-node@$ch" || fail upgrade "не удалось перезапустить openflux-node@$ch"
            set -- "$@" "$ch"
        fi
    done
    # Older cores nothing points at any more.
    core=$(core_to_use)
    for old in "$BIN_DIR"/openflux-node-v*; do
        [ "$old" = "$BIN_DIR/openflux-$core" ] || rm -f "$old"
    done
    apply_autoupdate
    printf '{"ok":true,"core":"%s","restarted":%s}\n' "$core" "$(json_list "$@")"
}

# latest_release FILE: the newest node-vX.Y.Z tag in a GitHub releases
# listing (JSON in FILE), prereleases left out.
latest_release() {
    best=""
    # Every release has one tag_name and one prerelease, in either order;
    # the objects nested in it (author, assets) have neither.
    for tag in $(tr ',{}' '\n\n\n' < "$1" | awk '
        function pair() {
            if (tag != "" && pre != "") {
                if (pre == "false" && tag ~ /^node-v[0-9]+\.[0-9]+\.[0-9]+$/) print tag
                tag = ""; pre = ""
            }
        }
        /"tag_name"[ \t]*:/ { tag = $0; sub(/.*"tag_name"[ \t]*:[ \t]*"/, "", tag); sub(/".*/, "", tag); pair() }
        /"prerelease"[ \t]*:[ \t]*false/ { pre = "false"; pair() }
        /"prerelease"[ \t]*:[ \t]*true/ { pre = "true"; pair() }'); do
        version_gt "$tag" "$best" && best=$tag
    done
    printf '%s' "$best"
}

# restart_channels: restarts every enabled or running channel and prints
# their names.
restart_channels() {
    for ch in $(list_channels); do
        if systemctl is-active --quiet "openflux-node@$ch" || systemctl is-enabled --quiet "openflux-node@$ch"; then
            systemctl restart "openflux-node@$ch" >/dev/null 2>&1
            printf '%s\n' "$ch"
        fi
    done
}

# channels_stay_up CHANNEL...: whether each channel is running and did not
# restart during 20 seconds (a crashing core restarts every 5).
channels_stay_up() {
    sleep 3
    pids=""
    for ch in "$@"; do pids="$pids $ch=$(systemctl show -p MainPID --value "openflux-node@$ch" 2>/dev/null)"; done
    sleep 20
    for pair in $pids; do
        ch=${pair%%=*}; pid=${pair#*=}
        systemctl is-active --quiet "openflux-node@$ch" || return 1
        [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" = "$(systemctl show -p MainPID --value "openflux-node@$ch" 2>/dev/null)" ] || return 1
    done
}

# update: what openflux-node-update.timer runs. When RELEASE_REPO has a
# node-v* release newer than the installed core, moves every channel to it:
# the release's own node-install.sh (at its tag) pins the core's SHA-256,
# and the release's SHA256SUMS must say the same. If a channel does not stay
# up on the new core, the previous one comes back and that release is
# skipped from then on.
cmd_update() {
    [ "$(id -u)" = 0 ] || fail update "нужны права root"
    if [ -z "$(list_channels)" ]; then
        printf '{"ok":true,"updated":false,"reason":"на сервере нет каналов"}\n'
        return 0
    fi
    arch=$(detect_arch)
    [ -n "$arch" ] || fail update "архитектура $(uname -m) не поддерживается"
    repo=$(release_repo)
    current=$(managed_core "$repo")
    work=$(mktemp -d /tmp/openflux-node-update.XXXXXX) || fail update "не удалось создать временную папку"
    trap 'rm -rf "$work"' EXIT
    fetch "$GITHUB_API/repos/$repo/releases?per_page=30" "$work/releases.json" \
        || fail update "GitHub не ответил на список релизов $repo"
    latest=$(latest_release "$work/releases.json")
    [ -n "$latest" ] || fail update "в $repo нет релизов node-v*"
    skip="$STATE_ROOT/update-skip"
    if [ -n "$current" ] && ! version_gt "$latest" "$current"; then
        printf '{"ok":true,"updated":false,"core":"%s"}\n' "$current"
        return 0
    fi
    if grep -qsx "$latest" "$skip"; then
        printf '{"ok":true,"updated":false,"core":"%s","skipped":"%s"}\n' "$current" "$latest"
        return 0
    fi

    fetch "$GITHUB_RAW/$repo/$latest/deploy/node-install.sh" "$work/node-install.sh" \
        || fail update "не удалось скачать node-install.sh релиза $latest"
    grep -qxF "$MARKER" "$work/node-install.sh" && [ "$(script_core "$work/node-install.sh")" = "$latest" ] \
        || fail update "node-install.sh в $latest не относится к этому релизу"
    want=$(sed -n "s/^SHA_$arch=\"\([0-9a-f]\{64\}\)\"\$/\1/p" "$work/node-install.sh")
    [ -n "$want" ] || fail update "node-install.sh релиза $latest не знает хеш ядра для $arch"
    base="$GITHUB_WEB/$repo/releases/download/$latest"
    fetch "$base/SHA256SUMS" "$work/SHA256SUMS" || fail update "не удалось скачать SHA256SUMS релиза $latest"
    grep -qx "$want  openflux-linux-$arch" "$work/SHA256SUMS" \
        || fail update "SHA256SUMS релиза $latest расходится с его node-install.sh"
    fetch "$base/openflux-linux-$arch" "$work/core" || fail update "не удалось скачать ядро $latest"
    [ "$(sha256_of "$work/core")" = "$want" ] || fail update "SHA-256 скачанного ядра $latest не совпал"

    new="openflux-$latest"
    mkdir -p "$BIN_DIR" && chmod 0755 /opt/openflux-node "$BIN_DIR"
    cp "$work/core" "$BIN_DIR/.$new.new" && chmod 0755 "$BIN_DIR/.$new.new" && mv -f "$BIN_DIR/.$new.new" "$BIN_DIR/$new" \
        || fail update "не удалось записать ядро в $BIN_DIR"
    prev=$(readlink "$BIN_DIR/openflux" 2>/dev/null)
    ln -sfn "$new" "$BIN_DIR/openflux"
    # shellcheck disable=SC2046
    set -- $(restart_channels)
    if [ $# -gt 0 ] && ! channels_stay_up "$@"; then
        if [ -n "$prev" ] && [ -x "$BIN_DIR/$prev" ]; then
            ln -sfn "$prev" "$BIN_DIR/openflux"
            restart_channels >/dev/null
        fi
        rm -f "$BIN_DIR/$new"
        printf '%s\n' "$latest" >> "$skip"
        fail update "на ядре $latest каналы не поднялись, вернул ${prev#openflux-}; этот релиз больше не ставлю"
    fi
    mark_managed "$repo" "$latest"
    install_self "$work/node-install.sh" || true
    # Keep the previous core for a manual rollback, drop the older ones.
    for old in "$BIN_DIR"/openflux-node-v*; do
        case "${old##*/}" in "$new"|"$prev") ;; *) rm -f "$old" ;; esac
    done
    printf '{"ok":true,"updated":true,"core":"%s","previous":"%s","restarted":%s}\n' \
        "$latest" "$(json_escape "${prev#openflux-}")" "$(json_list "$@")"
}

# set-cookies: replaces a channel's Yandex sign-in and restarts it.
cmd_set_cookies() {
    [ "$(id -u)" = 0 ] || fail set-cookies "нужны права root (sudo)"
    read_config "$@"
    check_channel
    [ -d "$CONF_ROOT/$CHANNEL" ] || fail set-cookies "канала $CHANNEL нет на сервере"
    [ -n "$COOKIES" ] || fail set-cookies "нет cookies"
    write_cookies || fail set-cookies "не удалось сохранить вход в Яндекс на сервере"
    systemctl restart "openflux-node@$CHANNEL" || fail set-cookies "не удалось перезапустить openflux-node@$CHANNEL"
    printf '{"ok":true,"channel":"%s"}\n' "$CHANNEL"
}

# autoupdate on|off: turns the core updater on or off for the whole server,
# e.g. on channels installed before the wizard offered it.
cmd_autoupdate() {
    [ "$(id -u)" = 0 ] || fail autoupdate "нужны права root (sudo)"
    case "${1:-}" in
        on)
            [ -n "$(list_channels)" ] || fail autoupdate "на сервере нет каналов OpenFlux"
            AUTOUPDATE=yes ;;
        off) AUTOUPDATE=no ;;
        *) fail usage "usage: node-install.sh autoupdate on|off" ;;
    esac
    apply_autoupdate || fail autoupdate "не удалось включить openflux-node-update.timer"
    state=false
    autoupdate_on && state=true
    printf '{"ok":true,"autoupdate":%s}\n' "$state"
}

cmd_status() {
    read_config
    check_channel
    [ -d "$CONF_ROOT/$CHANNEL" ] || fail status "канала $CHANNEL нет на сервере"
    state=$(systemctl is-active "openflux-node@$CHANNEL" 2>/dev/null)
    printf '{"ok":true,"channel":"%s","state":"%s"}\n' "$CHANNEL" "$(json_escape "$state")"
}

case "${1:-}" in
    probe) cmd_probe ;;
    plan) cmd_plan ;;
    apply) shift; cmd_apply "$@" ;;
    remove) shift; cmd_remove "$@" ;;
    status) cmd_status ;;
    upgrade) cmd_upgrade ;;
    set-cookies) shift; cmd_set_cookies "$@" ;;
    update) cmd_update ;;
    autoupdate) shift; cmd_autoupdate "$@" ;;
    *) fail usage "usage: node-install.sh probe|plan|apply|remove|status|upgrade|set-cookies|update|autoupdate" ;;
esac
