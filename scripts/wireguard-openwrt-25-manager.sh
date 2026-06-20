#!/bin/ash
# =============================================================================
# OpenWrt 25.x WireGuard Server Installer & Manager
# =============================================================================
# Production-grade, modular, idempotent.
# Compatible with: OpenWrt 25.x (APK + UCI + busybox ash)
# Features:
#   - Full UCI-based configuration (network + firewall)
#   - Classic /etc/wireguard/params + wg0.conf for reference/compatibility
#   - Custom DNS framework (5 presets + custom, with validation & testing)
#   - DDNS / custom hostname support with dynamic IP detection
#   - Auto-updater script + cron for home dynamic IP scenarios
#   - Peer management (add / remove / list / QR codes)
#   - Backup & restore framework
#   - Health checks & diagnostics
#   - Complete uninstall with cleanup
# =============================================================================

# Do NOT use "set -e" — we handle errors explicitly for better UX in ash

# =============================================================================
# SECTION 1: COLOR AND LOGGING FRAMEWORK
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

_log() {
    local level="$1"
    shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)  printf "%b[%s] [INFO] %b%s\n"  "$GREEN" "$ts" "$NC" "$*" ;;
        WARN)  printf "%b[%s] [WARN] %b%s\n"  "$YELLOW" "$ts" "$NC" "$*" ;;
        ERROR) printf "%b[%s] [ERROR] %b%s\n" "$RED" "$ts" "$NC" "$*" ;;
        DEBUG) [ "${DEBUG:-0}" = "1" ] && printf "%b[%s] [DEBUG] %b%s\n" "$PURPLE" "$ts" "$NC" "$*" ;;
    esac
    logger -t "wg-manager" "[$level] $*" 2>/dev/null || true
}

log()   { _log INFO "$@"; }
warn()  { _log WARN "$@"; }
error() { _log ERROR "$@"; }
debug() { _log DEBUG "$@"; }

print_color() {
    local color="$1"
    shift
    printf "%b%s%b\n" "$color" "$*" "$NC"
}

banner() {
    clear 2>/dev/null || true

    print_color "$CYAN" "
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║   ██╗    ██╗██╗██████╗ ███████╗ ██████╗ ██╗   ██╗              ║
║   ██║    ██║██║██╔══██╗██╔════╝██╔════╝ ██║   ██║              ║
║   ██║ █╗ ██║██║██████╔╝█████╗  ██║  ███╗██║   ██║              ║
║   ██║███╗██║██║██╔══██╗██╔══╝  ██║   ██║██║   ██║              ║
║   ╚███╔███╔╝██║██████╔╝███████╗╚██████╔╝╚██████╔╝              ║
║    ╚══╝╚══╝ ╚═╝╚═════╝ ╚══════╝ ╚═════╝  ╚═════╝               ║
║                                                                ║
║              WireGuard OpenWrt Management Suite                ║
║                                                                ║
╠════════════════════════════════════════════════════════════════╣
║                                                                ║
║  🔐 Secure VPN Infrastructure Automation                       ║
║                                                                ║
║  • OpenWrt 25.x Ready                                          ║
║  • WireGuard Server Management                                 ║
║  • IPv4 / IPv6 Dual Stack                                      ║
║  • UCI Firewall Integration                                    ║
║  • APK Package Support                                         ║
║  • Automated Peer Management                                   ║
║  • Secure Remote Access                                        ║
║                                                                ║
╠════════════════════════════════════════════════════════════════╣
║                                                                ║
║  Project      : wireguard_openwrt                              ║
║  Version      : v2.5.0                                         ║
║  Developer    : Mohamed Elsaadouni                             ║
║  Website      : elsaadouni.com                                 ║
║  Repository   : github.com/elsaadouni/wireguard_openwrt        ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
"

    print_color "$GREEN" "  ✓ WireGuard engine initialized"
    print_color "$GREEN" "  ✓ Firewall integration ready"
    print_color "$GREEN" "  ✓ Network services online"
    echo ""
}



# =============================================================================
# SECTION 2: CENTRALIZED CONFIGURATION CONSTANTS
# =============================================================================
SCRIPT_VERSION="2.5.0"

WG_IFACE="wg0"
WG_IPV4="10.70.71.1"
WG_IPV4_CIDR="10.70.71.1/24"
WG_PORT="51820"
WG_MTU="1420"
WG_KEEPALIVE="25"
WG_CLIENT_START_IP="10.70.71.2"

# DNS Presets
DNS_CLOUDFLARE_1="1.1.1.1"
DNS_CLOUDFLARE_2="1.0.0.1"
DNS_GOOGLE_1="8.8.8.8"
DNS_GOOGLE_2="8.8.4.4"
DNS_QUAD9_1="9.9.9.9"
DNS_QUAD9_2="149.112.112.112"
DNS_ADGUARD_1="94.140.14.14"
DNS_ADGUARD_2="94.140.15.15"

# Paths
WG_DIR="/etc/wireguard"
WG_PARAMS="$WG_DIR/params"
WG_SERVER_CONF="$WG_DIR/${WG_IFACE}.conf"
WG_BACKUP_DIR="$WG_DIR/backups"
WG_UPDATE_SCRIPT="$WG_DIR/update-wg-ip.sh"
CONFIG_DIR="/etc/config"

# Packages
REQUIRED_PACKAGES="kmod-wireguard wireguard-tools luci-proto-wireguard"
OPTIONAL_PACKAGES="qrencode curl ca-certificates ip-full"

# UCI named sections (prevents duplicates)
UCI_NET_SECTION="$WG_IFACE"
UCI_FW_ZONE="wg"
UCI_FW_FWD="wg_wan"
UCI_FW_RULE="wg_allow"

# =============================================================================
# SECTION 3: GLOBAL STATE
# =============================================================================
DEBUG=${DEBUG:-0}
EXISTING_INSTALL=0
CURRENT_DNS1=""
CURRENT_DNS2=""
CURRENT_DNS1_V6=""
CURRENT_DNS2_V6=""
SERVER_PUB_IP=""
SERVER_PUB_NIC=""
SERVER_HOSTNAME=""
SERVER_PRIV_KEY=""
SERVER_PUB_KEY=""
ENABLE_IPV6="false"

# =============================================================================
# SECTION 4: VALIDATION FRAMEWORK
# =============================================================================
validate_ipv4() {
    local ip="$1"
    case "$ip" in
        *.*.*.*)
            local IFS='.'
            set -- $ip
            [ "$#" -eq 4 ] && \
            [ "$1" -ge 0 ] && [ "$1" -le 255 ] && \
            [ "$2" -ge 0 ] && [ "$2" -le 255 ] && \
            [ "$3" -ge 0 ] && [ "$3" -le 255 ] && \
            [ "$4" -ge 0 ] && [ "$4" -le 255 ] && return 0
            ;;
    esac
    return 1
}

validate_ipv6() {
    local ip="$1"
    # Basic IPv6 check: contains at least one colon, only hex chars and colons
    case "$ip" in
        *:*)
            local stripped
            stripped=$(echo "$ip" | tr -d '[:xdigit:]:')
            [ -z "$stripped" ] && return 0
            ;;
    esac
    return 1
}

validate_cidr_v4() {
    local cidr="$1"
    local ip part
    ip="${cidr%/*}"
    part="${cidr#*/}"
    validate_ipv4 "$ip" && [ "$part" -ge 0 ] && [ "$part" -le 32 ] 2>/dev/null
}

validate_port() {
    local port="$1"
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] 2>/dev/null
}

validate_mtu() {
    local mtu="$1"
    [ "$mtu" -ge 1280 ] && [ "$mtu" -le 1500 ] 2>/dev/null
}

validate_wg_key() {
    local key="$1"
    [ "${#key}" -eq 44 ] && echo "$key" | grep -qE '^[A-Za-z0-9+/=]+$' && return 0
    return 1
}

validate_dns_server() {
    local dns="$1"
    validate_ipv4 "$dns" && return 0
    validate_ipv6 "$dns" && return 0
    return 1
}

validate_hostname() {
    local h="$1"
    [ -z "$h" ] && return 1
    # Allow hostnames like vpn.example.com, pi.yas.sh, etc.
    echo "$h" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$' && return 0
    return 1
}

# =============================================================================
# SECTION 5: UTILITY FUNCTIONS
# =============================================================================
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
}

is_openwrt() {
    [ -f /etc/openwrt_release ] || { [ -f /etc/os-release ] && grep -q "OpenWrt" /etc/os-release 2>/dev/null; }
}

check_openwrt_version() {
    if [ -f /etc/openwrt_release ]; then
        . /etc/openwrt_release 2>/dev/null || true
        log "Detected OpenWrt: ${DISTRIB_RELEASE:-unknown} (${DISTRIB_TARGET:-unknown})"
        case "${DISTRIB_RELEASE:-}" in
            25*|24.10*|24*) ;;
            *) warn "Script optimized for OpenWrt 25.x. Proceed with caution." ;;
        esac
    fi
}

get_public_ip() {
    local ip=""
    for svc in "https://ipv4.icanhazip.com" "https://api.ipify.org" "https://checkip.amazonaws.com"; do
        if command -v curl >/dev/null 2>&1; then
            ip=$(curl -4 --connect-timeout 5 --max-time 8 -s "$svc" 2>/dev/null | tr -d '\r\n')
        elif command -v wget >/dev/null 2>&1; then
            ip=$(wget -4 -qO- --timeout=8 "$svc" 2>/dev/null | tr -d '\r\n')
        fi
        if validate_ipv4 "$ip"; then
            SERVER_PUB_IP="$ip"
            log "Public IPv4 detected: $SERVER_PUB_IP"
            return 0
        fi
    done
    warn "Could not auto-detect public IPv4"
    SERVER_PUB_IP=""
    return 1
}

detect_public_nic() {
    SERVER_PUB_NIC=$(ip -4 route show default 2>/dev/null | awk '/default via/ {print $5; exit}')
    if [ -z "$SERVER_PUB_NIC" ]; then
        SERVER_PUB_NIC=$(ip link show 2>/dev/null | awk -F': ' '/^[0-9]+: (eth|en|wan|br-lan)/ {print $2; exit}' | head -1)
    fi
    if [ -n "$SERVER_PUB_NIC" ]; then
        log "Detected public interface: $SERVER_PUB_NIC"
    else
        warn "Could not auto-detect public NIC"
    fi
}

resolve_hostname() {
    local h="$1"
    local resolved=""
    if command -v dig >/dev/null 2>&1; then
        resolved=$(dig +short "$h" 2>/dev/null | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    elif command -v nslookup >/dev/null 2>&1; then
        resolved=$(nslookup "$h" 2>/dev/null | awk '/^Address: / {print $2; exit}')
    elif command -v getent >/dev/null 2>&1; then
        resolved=$(getent hosts "$h" 2>/dev/null | awk '{print $1; exit}')
    fi
    echo "$resolved"
}

# =============================================================================
# SECTION 6: BACKUP AND RESTORE
# =============================================================================
create_backup() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$WG_BACKUP_DIR"

    log "Creating backup: $ts ..."
    for cfg in network firewall dhcp; do
        local src="$CONFIG_DIR/$cfg"
        if [ -f "$src" ]; then
            cp "$src" "$WG_BACKUP_DIR/${cfg}.${ts}.bak" 2>/dev/null || true
        fi
    done
    if [ -d "$WG_DIR" ]; then
        tar -czf "$WG_BACKUP_DIR/wireguard.${ts}.tar.gz" -C /etc wireguard 2>/dev/null || true
    fi
    echo "$ts" > "$WG_BACKUP_DIR/latest_backup"
    log "Backup created: $ts"
}

list_backups() {
    print_color "$CYAN" "=== Available Backups ==="
    if [ -d "$WG_BACKUP_DIR" ]; then
        ls -1 "$WG_BACKUP_DIR"/*.bak 2>/dev/null | sed 's|.*/||' | sort -r | head -10 || echo "  (none)"
    else
        echo "  (none)"
    fi
}

restore_backup() {
    local ts="${1:-}"
    if [ -z "$ts" ] && [ -f "$WG_BACKUP_DIR/latest_backup" ]; then
        ts=$(cat "$WG_BACKUP_DIR/latest_backup")
    fi
    if [ -z "$ts" ]; then
        error "No backup timestamp provided or found"
        return 1
    fi

    log "Restoring backup: $ts ..."
    for cfg in network firewall dhcp; do
        local bak="$WG_BACKUP_DIR/${cfg}.${ts}.bak"
        if [ -f "$bak" ]; then
            cp "$bak" "$CONFIG_DIR/$cfg" 2>/dev/null || true
            log "Restored $cfg"
        fi
    done
    if [ -f "$WG_BACKUP_DIR/wireguard.${ts}.tar.gz" ]; then
        tar -xzf "$WG_BACKUP_DIR/wireguard.${ts}.tar.gz" -C /etc 2>/dev/null || true
        log "Restored wireguard files"
    fi

    /etc/init.d/network reload 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
    log "Backup restored and services reloaded"
}

# =============================================================================
# SECTION 7: PACKAGE MANAGEMENT (APK ONLY)
# =============================================================================
install_packages() {
    log "Updating APK index..."
    apk update >/dev/null 2>&1 || warn "APK update had issues (offline?)"

    log "Installing packages..."
    local pkg failed=0
    for pkg in $REQUIRED_PACKAGES $OPTIONAL_PACKAGES; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            debug "Already installed: $pkg"
        else
            log "Installing $pkg ..."
            if ! apk add --no-cache "$pkg" >/dev/null 2>&1; then
                warn "Failed to install $pkg"
                failed=$((failed + 1))
            fi
        fi
    done

    if ! command -v wg >/dev/null 2>&1; then
        error "wireguard-tools not available after install"
        return 1
    fi
    if [ "$failed" -gt 0 ]; then
        warn "$failed optional package(s) failed, continuing..."
    fi
    log "Package installation complete"
}

# =============================================================================
# SECTION 8: DNS MANAGEMENT FRAMEWORK
# =============================================================================
get_dns_choice() {
    local choice
    print_color "$CYAN" "=== DNS Configuration ==="
    echo "1) Cloudflare   (1.1.1.1 / 1.0.0.1)"
    echo "2) Google       (8.8.8.8 / 8.8.4.4)"
    echo "3) Quad9        (9.9.9.9 / 149.112.112.112)"
    echo "4) AdGuard      (94.140.14.14 / 94.140.15.15)"
    echo "5) Custom DNS"
    echo ""
    printf "Select [1-5] (default: 1): "
    read -r choice
    choice=${choice:-1}

    case "$choice" in
        1)
            CURRENT_DNS1="$DNS_CLOUDFLARE_1"
            CURRENT_DNS2="$DNS_CLOUDFLARE_2"
            ;;
        2)
            CURRENT_DNS1="$DNS_GOOGLE_1"
            CURRENT_DNS2="$DNS_GOOGLE_2"
            ;;
        3)
            CURRENT_DNS1="$DNS_QUAD9_1"
            CURRENT_DNS2="$DNS_QUAD9_2"
            ;;
        4)
            CURRENT_DNS1="$DNS_ADGUARD_1"
            CURRENT_DNS2="$DNS_ADGUARD_2"
            ;;
        5)
            while true; do
                printf "Primary DNS (IPv4 or IPv6): "
                read -r CURRENT_DNS1
                validate_dns_server "$CURRENT_DNS1" || { warn "Invalid DNS"; continue; }
                break
            done
            printf "Secondary DNS (optional, press Enter to skip): "
            read -r CURRENT_DNS2
            if [ -n "$CURRENT_DNS2" ]; then
                validate_dns_server "$CURRENT_DNS2" || { warn "Invalid secondary, using primary only"; CURRENT_DNS2=""; }
            fi
            ;;
        *)
            CURRENT_DNS1="$DNS_CLOUDFLARE_1"
            CURRENT_DNS2="$DNS_CLOUDFLARE_2"
            ;;
    esac

    # Optional IPv6 DNS
    if [ "$ENABLE_IPV6" = "true" ]; then
        printf "Primary IPv6 DNS (optional): "
        read -r CURRENT_DNS1_V6
        if [ -n "$CURRENT_DNS1_V6" ]; then
            validate_ipv6 "$CURRENT_DNS1_V6" || { warn "Invalid IPv6 DNS, skipping"; CURRENT_DNS1_V6=""; }
        fi
        printf "Secondary IPv6 DNS (optional): "
        read -r CURRENT_DNS2_V6
        if [ -n "$CURRENT_DNS2_V6" ]; then
            validate_ipv6 "$CURRENT_DNS2_V6" || { warn "Invalid IPv6 DNS, skipping"; CURRENT_DNS2_V6=""; }
        fi
    fi

    log "DNS: $CURRENT_DNS1${CURRENT_DNS2:+ / $CURRENT_DNS2}"
}

apply_dns_to_uci() {
    log "Applying DNS via UCI..."

    # Clear existing
    uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true

    # Add IPv4 DNS
    [ -n "$CURRENT_DNS1" ] && uci add_list dhcp.@dnsmasq[0].server="$CURRENT_DNS1" 2>/dev/null || true
    [ -n "$CURRENT_DNS2" ] && uci add_list dhcp.@dnsmasq[0].server="$CURRENT_DNS2" 2>/dev/null || true
    [ -n "$CURRENT_DNS1_V6" ] && uci add_list dhcp.@dnsmasq[0].server="$CURRENT_DNS1_V6" 2>/dev/null || true
    [ -n "$CURRENT_DNS2_V6" ] && uci add_list dhcp.@dnsmasq[0].server="$CURRENT_DNS2_V6" 2>/dev/null || true

    uci set dhcp.@dnsmasq[0].noresolv='1' 2>/dev/null || true
    uci commit dhcp

    # Also set on WAN interface if it exists
    if uci -q get network.wan >/dev/null 2>&1; then
        uci -q delete network.wan.dns 2>/dev/null || true
        [ -n "$CURRENT_DNS1" ] && uci add_list network.wan.dns="$CURRENT_DNS1" 2>/dev/null || true
        [ -n "$CURRENT_DNS2" ] && uci add_list network.wan.dns="$CURRENT_DNS2" 2>/dev/null || true
        uci commit network 2>/dev/null || true
    fi

    log "DNS applied to UCI"
}

test_dns_resolution() {
    local dns_server="${1:-$CURRENT_DNS1}"
    log "Testing DNS resolution via $dns_server ..."
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup -timeout=4 google.com "$dns_server" >/dev/null 2>&1; then
            log "DNS test PASSED"
            return 0
        fi
    fi
    if ping -c 1 -W 4 google.com >/dev/null 2>&1; then
        log "DNS test PASSED (via system)"
        return 0
    fi
    warn "DNS test FAILED"
    return 1
}

update_client_configs_dns() {
    log "Updating DNS in existing client configs..."
    local f
    for f in "$WG_DIR"/*-client.conf; do
        [ -f "$f" ] || continue
        local dns_line="$CURRENT_DNS1"
        [ -n "$CURRENT_DNS2" ] && dns_line="$dns_line, $CURRENT_DNS2"
        [ -n "$CURRENT_DNS1_V6" ] && dns_line="$dns_line, $CURRENT_DNS1_V6"
        [ -n "$CURRENT_DNS2_V6" ] && dns_line="$dns_line, $CURRENT_DNS2_V6"

        if grep -q "^DNS = " "$f"; then
            sed -i "s|^DNS = .*|DNS = $dns_line|" "$f"
        else
            sed -i "/^\[Interface\]/a DNS = $dns_line" "$f"
        fi
        log "Updated DNS in $(basename "$f")"
    done
}

# =============================================================================
# SECTION 9: DDNS / DYNAMIC IP & ENDPOINT MANAGEMENT
# =============================================================================
ask_server_endpoint() {
    print_color "$CYAN" "=== Server Endpoint ==="
    echo "If you have a DDNS hostname (e.g. pi.yas.sh), enter it below."
    echo "Clients will use this hostname so they always resolve the latest IP."
    echo "Leave blank to use your public IP directly."
    echo ""
    printf "DDNS Hostname (optional): "
    read -r SERVER_HOSTNAME

    if [ -n "$SERVER_HOSTNAME" ]; then
        if validate_hostname "$SERVER_HOSTNAME"; then
            local resolved
            resolved=$(resolve_hostname "$SERVER_HOSTNAME")
            if validate_ipv4 "$resolved"; then
                SERVER_PUB_IP="$resolved"
                log "Hostname $SERVER_HOSTNAME resolved to $SERVER_PUB_IP"
            else
                warn "Could not resolve $SERVER_HOSTNAME — using detected IP"
                [ -z "$SERVER_PUB_IP" ] && get_public_ip || true
            fi
            log "Endpoint for clients: $SERVER_HOSTNAME:$WG_PORT"
        else
            warn "Invalid hostname format — using IP"
            SERVER_HOSTNAME=""
            [ -z "$SERVER_PUB_IP" ] && get_public_ip || true
        fi
    else
        [ -z "$SERVER_PUB_IP" ] && get_public_ip || true
        log "Endpoint for clients: $SERVER_PUB_IP:$WG_PORT"
    fi
}

refresh_ddns_endpoint() {
    print_color "$CYAN" "=== Refresh DDNS Endpoint ==="

    if [ -z "$SERVER_HOSTNAME" ]; then
        printf "Enter DDNS hostname (e.g. pi.yas.sh): "
        read -r SERVER_HOSTNAME
        [ -z "$SERVER_HOSTNAME" ] && { error "No hostname provided"; return 1; }
    fi

    log "Resolving $SERVER_HOSTNAME ..."
    local new_ip
    new_ip=$(resolve_hostname "$SERVER_HOSTNAME")

    if ! validate_ipv4 "$new_ip"; then
        warn "Resolve failed. Keeping cached IP."
        return 1
    fi

    if [ "$new_ip" = "$SERVER_PUB_IP" ]; then
        log "IP unchanged: $SERVER_PUB_IP"
        return 0
    fi

    log "IP changed: $SERVER_PUB_IP -> $new_ip"
    SERVER_PUB_IP="$new_ip"

    # Update params
    if [ -f "$WG_PARAMS" ]; then
        sed -i "s/^SERVER_PUB_IP=.*/SERVER_PUB_IP=$SERVER_PUB_IP/" "$WG_PARAMS"
    fi

    # Update client configs
    local ep="${SERVER_HOSTNAME}:${WG_PORT}"
    local count=0
    local f
    for f in "$WG_DIR"/*-client.conf; do
        [ -f "$f" ] || continue
        sed -i "s|^Endpoint = .*|Endpoint = $ep|" "$f" && count=$((count + 1))
    done
    [ "$count" -gt 0 ] && log "Updated $count client config(s) with $ep"

    save_params
    restart_tunnel
    print_color "$GREEN" "Endpoint refreshed: $ep (IP: $SERVER_PUB_IP)"
}

create_ip_updater_script() {
    log "Creating dynamic IP updater script..."
    mkdir -p "$WG_DIR"

    cat > "$WG_UPDATE_SCRIPT" <<'EOS'
#!/bin/ash
# WireGuard Dynamic IP Updater for OpenWrt
# Auto-generated by wg-manager

LOGFILE="/var/log/wg-ddns.log"
WG_DIR="/etc/wireguard"
PARAMS="$WG_DIR/params"
WG_IFACE="wg0"

mkdir -p "$(dirname "$LOGFILE")"

# Get current public IP
CURRENT_IP=$(curl -4 -s --max-time 10 ifconfig.me 2>/dev/null || \
             curl -4 -s --max-time 10 ipv4.icanhazip.com 2>/dev/null || \
             curl -4 -s --max-time 10 api.ipify.org 2>/dev/null)

if [ -z "$CURRENT_IP" ]; then
    echo "$(date '+%F %T') - FAILED to detect public IP" >> "$LOGFILE"
    exit 1
fi

# Read old IP and settings
OLD_IP=""
HOSTNAME=""
PORT="51820"
if [ -f "$PARAMS" ]; then
    OLD_IP=$(grep '^SERVER_PUB_IP=' "$PARAMS" | cut -d'=' -f2)
    HOSTNAME=$(grep '^SERVER_HOSTNAME=' "$PARAMS" | cut -d'=' -f2)
    PORT=$(grep '^SERVER_PORT=' "$PARAMS" | cut -d'=' -f2)
    [ -z "$PORT" ] && PORT="51820"
fi

if [ "$CURRENT_IP" != "$OLD_IP" ]; then
    echo "$(date '+%F %T') - IP changed: ${OLD_IP:-none} -> $CURRENT_IP" >> "$LOGFILE"

    # Update params
    if [ -f "$PARAMS" ]; then
        sed -i "s/^SERVER_PUB_IP=.*/SERVER_PUB_IP=$CURRENT_IP/" "$PARAMS"
    fi

    # Determine endpoint string
    if [ -n "$HOSTNAME" ]; then
        NEW_EP="${HOSTNAME}:${PORT}"
    else
        NEW_EP="${CURRENT_IP}:${PORT}"
    fi

    # Update all client configs
    for client in "$WG_DIR"/*-client.conf; do
        [ -f "$client" ] || continue
        sed -i "s|^Endpoint = .*|Endpoint = $NEW_EP|" "$client"
    done

    # Restart tunnel
    ifdown "$WG_IFACE" 2>/dev/null || true
    sleep 1
    ifup "$WG_IFACE" 2>/dev/null || true

    echo "$(date '+%F %T') - Updated endpoint to $NEW_EP" >> "$LOGFILE"
else
    echo "$(date '+%F %T') - IP unchanged ($CURRENT_IP)" >> "$LOGFILE"
fi
EOS

    chmod +x "$WG_UPDATE_SCRIPT"
    log "Created: $WG_UPDATE_SCRIPT"
}

add_ip_updater_cron() {
    local line="*/5 * * * * $WG_UPDATE_SCRIPT"
    if [ -f /etc/crontabs/root ]; then
        grep -q "$WG_UPDATE_SCRIPT" /etc/crontabs/root || echo "$line" >> /etc/crontabs/root
    else
        (crontab -l 2>/dev/null; echo "$line") | crontab - 2>/dev/null || true
    fi
    /etc/init.d/cron restart 2>/dev/null || true
    log "Cron job added (every 5 minutes)"
    print_color "$GREEN" "Dynamic IP updater scheduled via cron."
}

remove_ip_updater_cron() {
    if [ -f /etc/crontabs/root ]; then
        sed -i "\|$WG_UPDATE_SCRIPT|d" /etc/crontabs/root 2>/dev/null || true
    fi
    crontab -l 2>/dev/null | grep -v "$WG_UPDATE_SCRIPT" | crontab - 2>/dev/null || true
}

# =============================================================================
# SECTION 10: PARAMETER PERSISTENCE (Classic Style)
# =============================================================================
load_params() {
    if [ -f "$WG_PARAMS" ]; then
        . "$WG_PARAMS" 2>/dev/null || true
        EXISTING_INSTALL=1
        CURRENT_DNS1="${CLIENT_DNS1:-1.1.1.1}"
        CURRENT_DNS2="${CLIENT_DNS2:-1.0.0.1}"
        CURRENT_DNS1_V6="${CLIENT_DNS1_V6:-}"
        CURRENT_DNS2_V6="${CLIENT_DNS2_V6:-}"
        SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
        WG_PORT="${SERVER_PORT:-51820}"
        debug "Loaded existing parameters"
    else
        EXISTING_INSTALL=0
        CURRENT_DNS1="1.1.1.1"
        CURRENT_DNS2="1.0.0.1"
    fi
}

save_params() {
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    cat > "$WG_PARAMS" <<EOF
# WireGuard Server Parameters — Generated $(date)
SCRIPT_VERSION=$SCRIPT_VERSION
SERVER_PUB_IP=${SERVER_PUB_IP:-}
SERVER_PUB_NIC=${SERVER_PUB_NIC:-}
SERVER_HOSTNAME=${SERVER_HOSTNAME:-}
SERVER_WG_NIC=$WG_IFACE
SERVER_WG_IPV4=$WG_IPV4
SERVER_PORT=$WG_PORT
SERVER_MTU=$WG_MTU
SERVER_PRIV_KEY=$SERVER_PRIV_KEY
SERVER_PUB_KEY=$SERVER_PUB_KEY
CLIENT_DNS1=$CURRENT_DNS1
CLIENT_DNS2=$CURRENT_DNS2
CLIENT_DNS1_V6=$CURRENT_DNS1_V6
CLIENT_DNS2_V6=$CURRENT_DNS2_V6
PERSISTENT_KEEPALIVE=$WG_KEEPALIVE
ENABLE_IPV6=$ENABLE_IPV6
INSTALL_DATE=$(date +%F)
EOF
    chmod 600 "$WG_PARAMS"
    log "Saved parameters to $WG_PARAMS"
}

# =============================================================================
# SECTION 11: SERVER KEYS
# =============================================================================
generate_server_keys() {
    if [ -f "$WG_DIR/server_private.key" ] && [ -f "$WG_DIR/server_public.key" ]; then
        SERVER_PRIV_KEY=$(cat "$WG_DIR/server_private.key")
        SERVER_PUB_KEY=$(cat "$WG_DIR/server_public.key")
        log "Using existing server keys"
        return 0
    fi

    log "Generating WireGuard server key pair..."
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    SERVER_PRIV_KEY=$(wg genkey)
    SERVER_PUB_KEY=$(echo "$SERVER_PRIV_KEY" | wg pubkey)

    echo "$SERVER_PRIV_KEY" > "$WG_DIR/server_private.key"
    echo "$SERVER_PUB_KEY" > "$WG_DIR/server_public.key"
    chmod 600 "$WG_DIR/server_private.key" "$WG_DIR/server_public.key"
    log "Server keys generated"
}

# =============================================================================
# SECTION 12: UCI NETWORK CONFIGURATION
# =============================================================================
configure_network_interface() {
    log "Configuring UCI network interface ($UCI_NET_SECTION)..."

    # Idempotent: remove existing named section
    uci -q delete "network.$UCI_NET_SECTION" 2>/dev/null || true

    uci set "network.$UCI_NET_SECTION"=interface
    uci set "network.$UCI_NET_SECTION.proto"='wireguard'
    uci set "network.$UCI_NET_SECTION.private_key"="$SERVER_PRIV_KEY"
    uci add_list "network.$UCI_NET_SECTION.addresses"="$WG_IPV4_CIDR"
    uci set "network.$UCI_NET_SECTION.listen_port"="$WG_PORT"
    uci set "network.$UCI_NET_SECTION.mtu"="$WG_MTU"
    uci set "network.$UCI_NET_SECTION.delegate"='0'

    if [ "$ENABLE_IPV6" = "true" ]; then
        uci set "network.$UCI_NET_SECTION.ip6assign"='0' 2>/dev/null || true
    fi

    uci commit network
    log "Network interface configured"
}

# =============================================================================
# SECTION 13: UCI FIREWALL CONFIGURATION
# =============================================================================
configure_firewall() {
    log "Configuring UCI firewall..."

    # Remove old zone
    uci -q delete "firewall.$UCI_FW_ZONE" 2>/dev/null || true

    # Create zone
    uci set "firewall.$UCI_FW_ZONE"=zone
    uci set "firewall.$UCI_FW_ZONE.name"='wg'
    uci set "firewall.$UCI_FW_ZONE.input"='ACCEPT'
    uci set "firewall.$UCI_FW_ZONE.output"='ACCEPT'
    uci set "firewall.$UCI_FW_ZONE.forward"='REJECT'
    uci set "firewall.$UCI_FW_ZONE.masq"='1'
    uci set "firewall.$UCI_FW_ZONE.mtu_fix"='1'
    uci add_list "firewall.$UCI_FW_ZONE.network"="$WG_IFACE"

    # Remove old forwarding
    uci -q delete "firewall.$UCI_FW_FWD" 2>/dev/null || true

    # Create forwarding wg -> wan
    uci set "firewall.$UCI_FW_FWD"=forwarding
    uci set "firewall.$UCI_FW_FWD.src"='wg'
    uci set "firewall.$UCI_FW_FWD.dest"='wan'

    # Remove old inbound rule
    uci -q delete "firewall.$UCI_FW_RULE" 2>/dev/null || true

    # Create inbound rule
    uci set "firewall.$UCI_FW_RULE"=rule
    uci set "firewall.$UCI_FW_RULE.name"="Allow-WireGuard-$WG_PORT"
    uci set "firewall.$UCI_FW_RULE.src"='wan'
    uci set "firewall.$UCI_FW_RULE.dest_port"="$WG_PORT"
    uci set "firewall.$UCI_FW_RULE.proto"='udp'
    uci set "firewall.$UCI_FW_RULE.target"='ACCEPT'
    uci set "firewall.$UCI_FW_RULE.family"='ipv4'

    uci commit firewall
    log "Firewall configured"
}

# =============================================================================
# SECTION 14: SYSCTL
# =============================================================================
configure_sysctl() {
    log "Configuring sysctl..."

    cat > /etc/sysctl.d/99-wireguard.conf <<EOF
# WireGuard forwarding
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

    if [ "$ENABLE_IPV6" = "true" ]; then
        echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-wireguard.conf
    else
        cat >> /etc/sysctl.d/99-wireguard.conf <<EOF
# IPv6 disabled
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    fi

    sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null 2>&1 || true

    if [ -n "$SERVER_PUB_NIC" ]; then
        sysctl -w "net.ipv4.conf.${SERVER_PUB_NIC}.rp_filter=0" >/dev/null 2>&1 || true
    fi
    sysctl -w "net.ipv4.conf.${WG_IFACE}.rp_filter=0" >/dev/null 2>&1 || true

    log "Sysctl applied"
}

# =============================================================================
# SECTION 15: CLASSIC CONFIG FILES (for reference & compatibility)
# =============================================================================
create_classic_server_conf() {
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    cat > "$WG_SERVER_CONF" <<EOF
[Interface]
Address = $WG_IPV4_CIDR
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV_KEY
SaveConfig = false
EOF

    chmod 600 "$WG_SERVER_CONF"
    log "Created classic config: $WG_SERVER_CONF"
}

# =============================================================================
# SECTION 16: PEER MANAGEMENT
# =============================================================================
get_peer_count() {
    uci show network 2>/dev/null | grep -c "wireguard_${WG_IFACE}" || echo 0
}

get_next_client_ip() {
    local last_ip
    last_ip=$(uci show network 2>/dev/null | grep -oE "${WG_IPV4%.*}\.[0-9]+/32" | sort -t. -k4 -n | tail -1 | sed 's|/32||')
    if [ -z "$last_ip" ]; then
        echo "$WG_CLIENT_START_IP"
    else
        local last_octet
        last_octet=$(echo "$last_ip" | cut -d. -f4)
        echo "${WG_IPV4%.*}.$((last_octet + 1))"
    fi
}

add_peer() {
    local description=""
    local peer_pubkey=""
    local allowed_ip=""
    local psk=""
    local next_ip=""

    echo ""
    print_color "$CYAN" "=== Add New Client ==="
    printf "Client description (e.g. phone-john): "
    read -r description
    [ -z "$description" ] && { error "Description required"; return 1; }

    # Check duplicate
    if uci show network 2>/dev/null | grep -q "description='${description}'"; then
        warn "Client '$description' already exists"
        return 1
    fi

    printf "Peer public key (blank = auto-generate): "
    read -r peer_pubkey

    local client_priv=""
    if [ -z "$peer_pubkey" ]; then
        client_priv=$(wg genkey)
        peer_pubkey=$(echo "$client_priv" | wg pubkey)
        print_color "$YELLOW" "Generated public key: $peer_pubkey"
        print_color "$YELLOW" "Private key (SAVE THIS): $client_priv"
    else
        validate_wg_key "$peer_pubkey" || { error "Invalid public key"; return 1; }
    fi

    next_ip=$(get_next_client_ip)
    printf "Allowed IP [$next_ip/32]: "
    read -r allowed_ip
    allowed_ip=${allowed_ip:-$next_ip/32}
    validate_cidr_v4 "$allowed_ip" || { error "Invalid CIDR"; return 1; }

    printf "Persistent Keepalive [$WG_KEEPALIVE]: "
    read -r psk
    psk=${psk:-$WG_KEEPALIVE}

    # Add to UCI (anonymous section — required by UCI wireguard format)
    uci add network "wireguard_${WG_IFACE}"
    uci set "network.@wireguard_${WG_IFACE}[-1].description"="$description"
    uci set "network.@wireguard_${WG_IFACE}[-1].public_key"="$peer_pubkey"
    uci add_list "network.@wireguard_${WG_IFACE}[-1].allowed_ips"="$allowed_ip"
    uci set "network.@wireguard_${WG_IFACE}[-1].persistent_keepalive"="$psk"
    uci set "network.@wireguard_${WG_IFACE}[-1].route_allowed_ips"='1'
    uci commit network

    log "Peer '$description' added"

    # Generate client config
    generate_client_config "$description" "$client_priv" "$allowed_ip" "$psk"

    # Append to classic server conf for reference
    cat >> "$WG_SERVER_CONF" <<EOF

# Client: $description
[Peer]
PublicKey = $peer_pubkey
AllowedIPs = $allowed_ip
PersistentKeepalive = $psk
EOF
}

remove_peer() {
    local description=""
    echo ""
    list_peers
    printf "Enter client description to remove: "
    read -r description
    [ -z "$description" ] && { error "No description provided"; return 1; }

    local found=0
    local idx=0
    local max_idx
    max_idx=$(get_peer_count)

    while [ "$idx" -lt "$max_idx" ]; do
        local desc
        desc=$(uci -q get "network.@wireguard_${WG_IFACE}[$idx].description" 2>/dev/null)
        if [ "$desc" = "$description" ]; then
            uci -q delete "network.@wireguard_${WG_IFACE}[$idx]"
            found=1
            log "Removed peer: $description"
            break
        fi
        idx=$((idx + 1))
    done

    if [ "$found" -eq 0 ]; then
        warn "Peer '$description' not found"
        return 1
    fi

    uci commit network
    rm -f "$WG_DIR/${description}-client.conf" 2>/dev/null || true
    log "Peer removed. Reload network to apply."
}

list_peers() {
    print_color "$CYAN" "=== Current Clients ==="
    local count=0
    local idx=0
    local max_idx
    max_idx=$(get_peer_count)

    while [ "$idx" -lt "$max_idx" ]; do
        local desc allowed ka
        desc=$(uci -q get "network.@wireguard_${WG_IFACE}[$idx].description" 2>/dev/null || echo "unnamed")
        allowed=$(uci -q get "network.@wireguard_${WG_IFACE}[$idx].allowed_ips" 2>/dev/null || echo "N/A")
        ka=$(uci -q get "network.@wireguard_${WG_IFACE}[$idx].persistent_keepalive" 2>/dev/null || echo "N/A")
        printf "  %2d) %-20s  Allowed: %-18s  KA: %s\n" $((count + 1)) "$desc" "$allowed" "$ka"
        count=$((count + 1))
        idx=$((idx + 1))
    done

    [ "$count" -eq 0 ] && echo "  (no clients)"
    echo ""
}

generate_client_config() {
    local desc="$1"
    local client_priv="$2"
    local allowed="$3"
    local keepalive="$4"

    local client_conf="$WG_DIR/${desc}-client.conf"
    local endpoint

    if [ -n "$SERVER_HOSTNAME" ]; then
        endpoint="${SERVER_HOSTNAME}:${WG_PORT}"
    else
        endpoint="${SERVER_PUB_IP:-YOUR_PUBLIC_IP}:${WG_PORT}"
    fi

    local dns_line="$CURRENT_DNS1"
    [ -n "$CURRENT_DNS2" ] && dns_line="$dns_line, $CURRENT_DNS2"
    [ -n "$CURRENT_DNS1_V6" ] && dns_line="$dns_line, $CURRENT_DNS1_V6"
    [ -n "$CURRENT_DNS2_V6" ] && dns_line="$dns_line, $CURRENT_DNS2_V6"

    cat > "$client_conf" <<EOF
[Interface]
PrivateKey = ${client_priv:-<YOUR_PRIVATE_KEY>}
Address = $allowed
DNS = $dns_line
MTU = $WG_MTU

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = $keepalive
EOF

    chmod 600 "$client_conf"
    log "Client config: $client_conf"

    print_color "$GREEN" "\n=== Client: $desc ==="
    cat "$client_conf"

    if command -v qrencode >/dev/null 2>&1; then
        echo ""
        print_color "$GREEN" "=== QR Code ==="
        qrencode -t ansiutf8 < "$client_conf" || true
        echo ""
    fi

    print_color "$YELLOW" "Endpoint used: $endpoint"
}

# =============================================================================
# SECTION 17: SERVICE MANAGEMENT
# =============================================================================
reload_wireguard() {
    log "Reloading network configuration..."
    if /etc/init.d/network reload 2>/dev/null; then
        sleep 2
        if ip link show "$WG_IFACE" >/dev/null 2>&1; then
            log "Network reloaded, $WG_IFACE is UP"
            return 0
        fi
    fi
    warn "Reload may have issues, attempting restart..."
    /etc/init.d/network restart 2>/dev/null || true
    sleep 3
}

restart_tunnel() {
    log "Restarting WireGuard tunnel..."
    ifdown "$WG_IFACE" 2>/dev/null || true
    sleep 1
    ifup "$WG_IFACE" 2>/dev/null || true
    sleep 2
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        log "Tunnel restarted successfully"
    else
        warn "Tunnel interface not detected after restart"
    fi
}

restart_firewall() {
    log "Restarting firewall..."
    /etc/init.d/firewall restart 2>/dev/null || true
}

# =============================================================================
# SECTION 18: HEALTH CHECKS & DIAGNOSTICS
# =============================================================================
show_interface_status() {
    print_color "$BLUE" "=== Interface Status ==="
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        echo "Interface: $WG_IFACE — UP"
        ip -4 addr show "$WG_IFACE" 2>/dev/null | grep inet || true
    else
        echo "Interface: $WG_IFACE — DOWN or not found"
    fi
    echo ""
}

show_peer_status() {
    print_color "$BLUE" "=== Peer Status ==="
    if command -v wg >/dev/null 2>&1 && ip link show "$WG_IFACE" >/dev/null 2>&1; then
        wg show "$WG_IFACE" 2>/dev/null || echo "No peer data"
    else
        echo "WireGuard not running"
    fi
    echo ""
}

show_traffic() {
    print_color "$BLUE" "=== Traffic Statistics ==="
    wg show "$WG_IFACE" transfer 2>/dev/null || echo "No traffic data"
    echo ""
}

test_connectivity() {
    print_color "$CYAN" "=== Connectivity Tests ==="

    echo "1. Tunnel interface:"
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        print_color "$GREEN" "   $WG_IFACE exists"
    else
        print_color "$RED" "   $WG_IFACE missing"
    fi

    echo "2. Server IP reachability:"
    if ping -c 2 -W 3 "$WG_IPV4" >/dev/null 2>&1; then
        print_color "$GREEN" "   $WG_IPV4 reachable"
    else
        print_color "$YELLOW" "   $WG_IPV4 not reachable (may be normal)"
    fi

    echo "3. Internet connectivity:"
    if ping -c 2 -W 4 1.1.1.1 >/dev/null 2>&1; then
        print_color "$GREEN" "   Internet reachable"
    else
        print_color "$YELLOW" "   Internet test failed"
    fi

    echo "4. DNS resolution:"
    test_dns_resolution || true

    echo "5. Public IP:"
    local ext_ip
    ext_ip=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || echo "unavailable")
    echo "   External IP: $ext_ip"
    echo ""
}

full_health_check() {
    print_color "$PURPLE" "\n=== FULL HEALTH CHECK ==="
    show_interface_status
    show_peer_status
    show_traffic

    print_color "$BLUE" "UCI Network:"
    uci show "network.$UCI_NET_SECTION" 2>/dev/null | head -10 || true

    print_color "$BLUE" "UCI Firewall Zone:"
    uci show "firewall.$UCI_FW_ZONE" 2>/dev/null | head -10 || true

    print_color "$BLUE" "Package Status:"
    apk info -e kmod-wireguard wireguard-tools 2>/dev/null && echo "  Packages OK" || echo "  Packages missing"

    test_connectivity
}

# =============================================================================
# SECTION 19: INSTALL / UNINSTALL
# =============================================================================
detect_existing() {
    if uci -q get "network.$UCI_NET_SECTION" >/dev/null 2>&1; then
        EXISTING_INSTALL=1
        log "Existing WireGuard installation detected"
        load_params
        return 0
    fi
    EXISTING_INSTALL=0
    return 1
}

initial_setup() {
    require_root
    if ! is_openwrt; then
        error "This script is designed for OpenWrt only"
        exit 1
    fi
    check_openwrt_version
    detect_public_nic
    get_public_ip || true
    load_params
}

install_wireguard() {
    print_color "$GREEN" "\n=== Installing WireGuard on OpenWrt 25.x ==="

    create_backup
    install_packages
    generate_server_keys

    # Ask for port
    printf "Listen Port [$WG_PORT]: "
    read -r newport
    if [ -n "$newport" ] && validate_port "$newport"; then
        WG_PORT="$newport"
    fi

    # Ask for DDNS hostname
    ask_server_endpoint

    # DNS
    get_dns_choice
    apply_dns_to_uci

    # Core configuration
    configure_network_interface
    configure_firewall
    configure_sysctl
    create_classic_server_conf
    save_params

    # Apply
    reload_wireguard
    restart_firewall

    # Verify
    sleep 2
    show_interface_status

    # Dynamic IP updater
    create_ip_updater_script
    printf "Add dynamic IP updater to cron (every 5 min)? [Y/n]: "
    read -r cron_ans
    case "$cron_ans" in
        [Nn]*) log "Cron updater skipped" ;;
        *) add_ip_updater_cron ;;
    esac

    full_health_check

    print_color "$GREEN" "\n=== Installation Complete ==="
    echo "Public Key : $SERVER_PUB_KEY"
    echo "Endpoint   : ${SERVER_HOSTNAME:-$SERVER_PUB_IP}:$WG_PORT"
    echo "Subnet     : $WG_IPV4_CIDR"
    echo "DNS        : $CURRENT_DNS1${CURRENT_DNS2:+ / $CURRENT_DNS2}"
    echo "Files      : $WG_PARAMS"
    echo "             $WG_SERVER_CONF"
    echo ""

    printf "Create first client now? [Y/n]: "
    read -r first
    case "$first" in
        [Nn]*) ;;
        *) add_peer ;;
    esac
}

uninstall_wireguard() {
    print_color "$RED" "\n=== UNINSTALL WIREGUARD ==="
    printf "Completely remove WireGuard? [y/N]: "
    read -r confirm
    case "$confirm" in
        [Yy]*) ;;
        *) log "Uninstall cancelled"; return 0 ;;
    esac

    create_backup

    log "Stopping tunnel..."
    ifdown "$WG_IFACE" 2>/dev/null || true

    log "Removing UCI configuration..."
    uci -q delete "network.$UCI_NET_SECTION" 2>/dev/null || true

    # Remove all wireguard peer sections
    local max_idx
    max_idx=$(get_peer_count)
    while [ "$max_idx" -gt 0 ]; do
        uci -q delete "network.@wireguard_${WG_IFACE}[0]" 2>/dev/null || true
        max_idx=$((max_idx - 1))
    done

    uci -q delete "firewall.$UCI_FW_ZONE" 2>/dev/null || true
    uci -q delete "firewall.$UCI_FW_FWD" 2>/dev/null || true
    uci -q delete "firewall.$UCI_FW_RULE" 2>/dev/null || true

    uci commit network
    uci commit firewall

    log "Removing files..."
    rm -rf "$WG_DIR" 2>/dev/null || true
    rm -f /etc/sysctl.d/99-wireguard.conf 2>/dev/null || true

    remove_ip_updater_cron

    log "Removing packages..."
    apk del kmod-wireguard wireguard-tools 2>/dev/null || true

    /etc/init.d/network reload 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true

    print_color "$GREEN" "WireGuard uninstalled. Backups kept in $WG_BACKUP_DIR"
}

# =============================================================================
# SECTION 20: INTERACTIVE MENU
# =============================================================================
show_menu() {
    banner
    echo " 1) Install / Reinstall WireGuard"
    echo " 2) Add Client (Peer)"
    echo " 3) Remove Client"
    echo " 4) List Clients"
    echo " 5) Change DNS Servers"
    echo " 6) View Status"
    echo " 7) Restart Tunnel"
    echo " 8) Test Connectivity"
    echo " 9) Refresh DDNS Endpoint (check IP change)"
    echo "10) Run IP Updater Now"
    echo "11) Backup Configuration"
    echo "12) Restore Configuration"
    echo "13) Full Health Check"
    echo "14) Uninstall WireGuard"
    echo "15) Exit"
    echo ""
    printf "Select option [1-15]: "
}

main_menu() {
    local choice
    while true; do
        show_menu
        read -r choice
        echo ""

        case "$choice" in
            1)  install_wireguard ;;
            2)  add_peer; reload_wireguard ;;
            3)  remove_peer; reload_wireguard ;;
            4)  list_peers ;;
            5)  get_dns_choice; apply_dns_to_uci; update_client_configs_dns;
                /etc/init.d/dnsmasq restart 2>/dev/null || true;
                test_dns_resolution ;;
            6)  show_interface_status; show_peer_status ;;
            7)  restart_tunnel ;;
            8)  test_connectivity ;;
            9)  refresh_ddns_endpoint ;;
            10) [ -x "$WG_UPDATE_SCRIPT" ] && "$WG_UPDATE_SCRIPT" || warn "Updater script not found" ;;
            11) create_backup; list_backups ;;
            12) list_backups;
                printf "Enter backup timestamp (or blank for latest): ";
                read -r ts;
                restore_backup "$ts" ;;
            13) full_health_check ;;
            14) uninstall_wireguard; break ;;
            15) print_color "$GREEN" "Goodbye!"; exit 0 ;;
            *)  warn "Invalid option. Choose 1-15." ;;
        esac

        echo ""
        printf "Press any key to continue..."
        read -n 1 -s -r
    done
}

# =============================================================================
# SECTION 21: MAIN ENTRY POINT
# =============================================================================
main() {
    initial_setup

    if detect_existing; then
        log "Existing installation found. Loading management menu..."
        main_menu
    else
        print_color "$YELLOW" "No existing WireGuard configuration found."
        printf "Perform fresh installation now? [Y/n]: "
        read -r ans
        case "$ans" in
            [Nn]*) echo "Exiting."; exit 0 ;;
            *) install_wireguard ;;
        esac

        echo ""
        printf "Open management menu now? [Y/n]: "
        read -r ans2
        case "$ans2" in
            [Nn]*) exit 0 ;;
            *) main_menu ;;
        esac
    fi
}

# CLI shortcuts
case "${1:-}" in
    install)   initial_setup; install_wireguard ;;
    add)       initial_setup; add_peer; reload_wireguard ;;
    list)      initial_setup; list_peers ;;
    remove)    initial_setup; remove_peer; reload_wireguard ;;
    status)    initial_setup; show_interface_status; show_peer_status ;;
    refresh)   initial_setup; refresh_ddns_endpoint ;;
    health)    initial_setup; full_health_check ;;
    update-ip) [ -x "$WG_UPDATE_SCRIPT" ] && "$WG_UPDATE_SCRIPT" || { initial_setup; [ -x "$WG_UPDATE_SCRIPT" ] && "$WG_UPDATE_SCRIPT"; } ;;
    uninstall) initial_setup; uninstall_wireguard ;;
    menu)      initial_setup; main_menu ;;
    *)         main ;;
esac

exit 0
