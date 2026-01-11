#!/bin/bash
set -e

# Update system and install Xray
echo "Updating package list..."
apt update -y

echo "Installing dependencies..."
apt install -y jq openssl curl

echo "Installing Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Generate UUID and save to file
echo "Generating UUID..."
xray uuid > uuid.txt
echo "UUID saved to uuid.txt"

# Generate X25519 key pair and save to file
echo "Generating X25519 key pair..."
xray x25519 > x25519.txt
echo "Key pair saved to x25519.txt"

# Extract public key for later use
grep -o 'Public key: .*' x25519.txt | cut -d' ' -f3 > pubkey.txt
echo "Public key extracted to pubkey.txt"

# Check for HTTP/2 support
echo "Checking HTTP/2 support..."
http2_check=$(curl -I --tlsv1.3 --http2 https://cloudflare.com 2>/dev/null | grep -i "HTTP/2")
if [[ -z "$http2_check" ]]; then
    echo "WARNING: HTTP/2 not detected in curl test!"
else
    echo "✓ HTTP/2 supported"
fi

# Check for TLS 1.3 support
echo "Checking TLS 1.3 support..."
tls13_check=$(openssl s_client -connect cloudflare.com:443 -brief 2>&1 | grep -i "TLSv1.3")
if [[ -z "$tls13_check" ]]; then
    echo "WARNING: TLSv1.3 not detected in openssl test!"
else
    echo "✓ TLSv1.3 supported"
fi

# Create symlink to config
echo "Creating symlink to config.json..."
ln -sf /usr/local/etc/xray/config.json ./config.json

# Get a Cloudflare domain for testing
CLOUDFLARE_DOMAIN="www.cloudflare.com"
echo "Using domain: $CLOUDFLARE_DOMAIN"

# Read generated values
UUID=$(cat uuid.txt | tr -d '[:space:]')
PRIVATE_KEY=$(grep -o 'Private key: .*' x25519.txt | cut -d' ' -f3)
PUBLIC_KEY=$(cat pubkey.txt | tr -d '[:space:]')

# Create config.json
echo "Creating config.json..."
cat > /usr/local/etc/xray/config.json <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$CLOUDFLARE_DOMAIN:443",
                    "serverNames": [
                        "$CLOUDFLARE_DOMAIN",
                        "www.$CLOUDFLARE_DOMAIN"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOF

# Create add_new.sh script
echo "Creating add_new.sh script..."
cat > add_new.sh <<'EOF'
#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <tag-name-for-link>"
    exit 1
fi

TAG="$1"

CONFIG="/usr/local/etc/xray/config.json"
UUID_FILE="./uuid.txt"
PUBKEY_FILE="./pubkey.txt"

# 1) Generate shortId and add to config
NEW_SID=$(openssl rand -hex 6)
jq --arg sid "$NEW_SID" '.inbounds[0].streamSettings.realitySettings.shortIds += [$sid]' \
   "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

# 2) Restart xray
systemctl restart xray

# 3) Collect values
UUID=$(cat "$UUID_FILE" | tr -d '[:space:]')
IP=$(hostname -I | awk '{print $1}')
PUBKEY=$(cat "$PUBKEY_FILE" | tr -d '[:space:]')
SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
SID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[-1]' "$CONFIG")

# 4) Print link
echo "vless://${UUID}@${IP}:443?type=tcp&security=reality&pbk=${PUBKEY}&fp=chrome&sni=${SNI}&sid=${SID}&flow=xtls-rprx-vision#${TAG}"
EOF

# Make add_new.sh executable
chmod +x add_new.sh

# Restart Xray service
echo "Restarting Xray service..."
systemctl restart xray

# Enable Xray to start on boot
systemctl enable xray

# Show current status
echo "Xray service status:"
systemctl status xray --no-pager -l

# Generate first link
echo -e "\nGenerating first link with tag 'main':"
./add_new.sh main

echo -e "\nSetup completed!"
echo "Files created:"
echo "  - uuid.txt (contains UUID)"
echo "  - x25519.txt (contains private/public keys)"
echo "  - pubkey.txt (contains public key only)"
echo "  - add_new.sh (script to generate new client links)"
echo ""
echo "To generate new client links, run: ./add_new.sh <tag-name>"
echo "Example: ./add_new.sh new-client"
