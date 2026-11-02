#!/bin/bash
# Stops and removes Lifelog. Your recorded data in ~/Lifelog is left alone (delete it yourself if you want).
UIDN=$(id -u)
for a in com.lifelog.recorder com.lifelog.process com.lifelog.sync; do
  launchctl bootout "gui/$UIDN/$a" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$a.plist"
done
pkill -x Lifelog 2>/dev/null
rm -rf "$HOME/Applications/Lifelog.app" "$HOME/.local/bin/lifelog"
tccutil reset All com.lifelog.recorder >/dev/null 2>&1
echo "Lifelog removed. Data kept at ${LIFELOG_DIR:-$HOME/Lifelog}. Cloud resources (Worker \"lifelog\", D1 \"lifelog\", R2 bucket) are untouched — delete them in the Cloudflare dashboard or with wrangler if you want."
