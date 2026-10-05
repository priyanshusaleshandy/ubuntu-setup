#!/usr/bin/env bash
# Deploy / Restart On-Prem Telegram Bot Container on Mac Mini M2

set -e

echo "🚀 Deploying onprem-telegram-bot container..."

mkdir -p ~/telegram-bot

# Ensure script file exists locally on Mac Mini
if [ ! -f ~/telegram-bot/bot.py ]; then
    echo "⚠️ ~/telegram-bot/bot.py not found! Please copy bot.py to ~/telegram-bot/bot.py"
    exit 1
fi

docker rm -f onprem-telegram-bot 2>/dev/null || true

docker run -d \
  --name onprem-telegram-bot \
  --restart always \
  -v $HOME/telegram-bot/bot.py:/bot.py \
  python:3.11-alpine sh -c 'apk add --no-cache bash iputils curl && python3 /bot.py'

echo "✅ Container onprem-telegram-bot active and monitoring!"
