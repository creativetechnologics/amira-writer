#!/bin/bash
#
# Setup script: configure Garys-Laptop.local for RunPod LORA training
#
# This script pulls credentials and SSH keys from Garys-Server.local so
# the laptop has everything needed to train LORAs via Amira Writer.
#
# Run this ONCE on the laptop, in Terminal:
#   bash "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/setup_laptop_for_lora.command"
#
# What it does:
#   1. Copies the ed25519 SSH keypair (needed to reach RunPod pods that have
#      your public key in their authorized_keys)
#   2. Copies LORA Maker credentials (~/.lora-maker/)
#   3. Tests the RunPod API key
#   4. Reminds you to enter the RunPod key in Amira Writer's API Settings
#      (the HuggingFace token is auto-read from ~/.lora-maker/hf_token)

set -e

SERVER="gary@Garys-Server.local"

echo "═══════════════════════════════════════════════════════════"
echo "  Amira Writer — Laptop LORA Setup"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "This will copy credentials from $SERVER to this laptop."
echo "You'll be prompted for the server password."
echo ""
read -p "Press Enter to continue, or Ctrl-C to cancel... " _

# 1. SSH keys
echo ""
echo "[1/4] Copying SSH keypair from server..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

if [ -f ~/.ssh/id_ed25519 ]; then
    echo "  ⚠️  ~/.ssh/id_ed25519 already exists."
    read -p "  Overwrite? (y/N) " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "  Skipped."
    else
        scp "$SERVER:~/.ssh/id_ed25519" ~/.ssh/id_ed25519
        scp "$SERVER:~/.ssh/id_ed25519.pub" ~/.ssh/id_ed25519.pub
        chmod 600 ~/.ssh/id_ed25519
        chmod 644 ~/.ssh/id_ed25519.pub
        echo "  ✓ SSH keys copied."
    fi
else
    scp "$SERVER:~/.ssh/id_ed25519" ~/.ssh/id_ed25519
    scp "$SERVER:~/.ssh/id_ed25519.pub" ~/.ssh/id_ed25519.pub
    chmod 600 ~/.ssh/id_ed25519
    chmod 644 ~/.ssh/id_ed25519.pub
    echo "  ✓ SSH keys copied."
fi

# 2. LORA Maker credentials
echo ""
echo "[2/4] Copying LORA Maker credentials..."
mkdir -p ~/.lora-maker
scp "$SERVER:~/.lora-maker/runpod_api_key" ~/.lora-maker/runpod_api_key
scp "$SERVER:~/.lora-maker/hf_token" ~/.lora-maker/hf_token
scp "$SERVER:~/.lora-maker/gemini_api_key" ~/.lora-maker/gemini_api_key 2>/dev/null || true
chmod 600 ~/.lora-maker/runpod_api_key ~/.lora-maker/hf_token 2>/dev/null || true
echo "  ✓ Credentials copied to ~/.lora-maker/"

# 3. Test RunPod API
echo ""
echo "[3/4] Testing RunPod API key..."
RUNPOD_KEY=$(cat ~/.lora-maker/runpod_api_key | tr -d '\n ')
if [ -z "$RUNPOD_KEY" ]; then
    echo "  ✗ RunPod API key is empty!"
    exit 1
fi

RESPONSE=$(curl -s -X POST "https://api.runpod.io/graphql" \
    -H "Authorization: Bearer $RUNPOD_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "query { myself { email pods { id name desiredStatus } } }"}')

if echo "$RESPONSE" | grep -q '"errors"'; then
    echo "  ✗ RunPod API rejected the key:"
    echo "$RESPONSE" | python3 -c "import json, sys; print('    ' + json.load(sys.stdin)['errors'][0].get('message','?'))" 2>/dev/null
    exit 1
else
    EMAIL=$(echo "$RESPONSE" | python3 -c "import json, sys; print(json.load(sys.stdin)['data']['myself'].get('email','?'))" 2>/dev/null)
    POD_COUNT=$(echo "$RESPONSE" | python3 -c "import json, sys; print(len(json.load(sys.stdin)['data']['myself'].get('pods',[])))" 2>/dev/null)
    echo "  ✓ RunPod authenticated as: $EMAIL"
    echo "  ✓ Current active pods: $POD_COUNT"
fi

# 4. Reminder for Amira Writer API settings
echo ""
echo "[4/4] Amira Writer keychain setup"
echo ""
echo "  The macOS Keychain is per-machine, so Amira Writer on this laptop"
echo "  needs the RunPod key entered separately. Copy this into the app:"
echo ""
echo "  RunPod API Key:"
echo "    $RUNPOD_KEY"
echo ""
echo "  HuggingFace Token:"
echo "    $(cat ~/.lora-maker/hf_token | tr -d '\n ')"
echo ""
echo "  (Amira Writer reads the HuggingFace token automatically from ~/.lora-maker/hf_token.)"
echo ""
if [ -f ~/.lora-maker/gemini_api_key ]; then
    echo "  Gemini API Key:"
    echo "    $(cat ~/.lora-maker/gemini_api_key | tr -d '\n ')"
    echo ""
fi

echo "═══════════════════════════════════════════════════════════"
echo "  Setup complete!"
echo ""
echo "  Next steps:"
echo "   1. Open Amira Writer on this laptop"
echo "   2. Go to Imagine → Inspector → Tools → Open API Settings"
echo "   3. Paste the RunPod key into the RunPod tab"
echo "   4. The HuggingFace token in ~/.lora-maker/hf_token will be picked up automatically"
echo "   5. Paste the Gemini key into the Gemini tab (if needed)"
echo "   6. Click Save"
echo "   7. You're ready to train LORAs!"
echo "═══════════════════════════════════════════════════════════"
