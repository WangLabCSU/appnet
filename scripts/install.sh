#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."

echo "=== Installing Caddy ==="
if ! command -v caddy &> /dev/null; then
    echo "Caddy not found, installing..."
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy
else
    echo "Caddy is already installed"
fi

echo -e "\n=== Installing Node.js dependencies for demo apps ==="
for app in apps/*/; do
    if [ -f "$app/package.json" ]; then
        echo "Installing dependencies for $(basename "$app")"
        cd "$app" && npm install && cd - > /dev/null
    fi
done

echo -e "\n✅ Installation complete!"
