# 🔐 WireGuard OpenWrt Infrastructure Manager

A complete WireGuard VPN management solution for modern OpenWrt routers.

Designed for OpenWrt 25.x using APK package management, UCI firewall integration,
IPv4/IPv6 support, DDNS automation and custom DNS configuration.

🌐 Website  
https://www.elsaadouni.com
https://www.yas.sh

📦 Repository  
https://github.com/elsaadouni/wireguard_openwrt


## ✨ Features

- OpenWrt 25.x compatible
- APK package manager support
- No opkg dependency
- WireGuard server automation
- Firewall4 / nftables integration
- IPv4 + IPv6 ready
- UCI based configuration
- Named UCI sections
- Safe re-runs without duplicates
- Automatic backups
- Health diagnostics
- Peer/client management
- Custom DNS support
- DDNS dynamic endpoint updates


# 🌐 DNS Support

Supports:

- Cloudflare DNS
- Google DNS
- Quad9
- AdGuard DNS
- Custom DNS servers


Custom DNS allows:

- Private DNS resolution
- Home network services
- DNS filtering
- Controlled VPN client resolution


# 🏠 Home Deployment Requirements

If WireGuard is installed at home behind an ISP router:

Port forwarding is required.

Example:

Internet
 |
 |
ISP Router
 |
UDP 51820 Forward
 |
OpenWrt WireGuard Server
 |
VPN Clients


Router forwarding:

Protocol:
UDP

External Port:
51820

Internal Port:
51820

Destination:
OpenWrt WAN IP


# 🌍 DDNS Support

For users without static public IP:

Example:

vpn.example.com

The system:

- checks public IP every 5 minutes
- detects changes
- updates WireGuard endpoints
- refreshes client configurations
- logs updates


# 🚀 Installation

Copy script:

scripts/wireguard-openwrt-25-manager.sh


Run:

chmod +x wireguard-openwrt-25-manager.sh

./wireguard-openwrt-25-manager.sh


CLI:

./wireguard-openwrt-25-manager.sh install

./wireguard-openwrt-25-manager.sh status

./wireguard-openwrt-25-manager.sh health

./wireguard-openwrt-25-manager.sh uninstall



## Author

Elsaadouni

https://Elsaadouni.com

