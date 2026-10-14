#!/bin/bash
# Saves the Claude API key that Lin Flow's notetaker uses to answer questions about a meeting and
# write its summary, after trying it once.
#
#   bash scripts/setup-claude.sh
#
# It asks for the key, hides it as you paste, asks Claude one tiny question with it, and saves it
# to ~/.config/anthropic/lin-flow-key (readable by you only) only if the answer comes back. The key
# is never printed. Reopen Lin Flow afterwards so it sees the key.

set -u
file="$HOME/.config/anthropic/lin-flow-key"
api="https://api.anthropic.com/v1/messages"

echo
echo "Claude key for Lin Flow's notetaker"
echo "-----------------------------------"
echo "Make one at https://platform.claude.com/settings/keys (API keys start with sk-ant-)."
if [ -s "$file" ]; then
  echo "A key is already saved. Paste a new one to replace it, or press Enter to keep it."
fi

tries=0
while [ $tries -lt 5 ]; do
  tries=$((tries + 1))
  printf "Paste the key and press Enter (it stays hidden): "
  if ! IFS= read -rs key; then echo; echo "No input. Nothing saved."; exit 1; fi
  echo
  key=$(printf '%s' "$key" | tr -d '[:space:]')
  if [ -z "$key" ]; then
    if [ -s "$file" ]; then echo "Kept the saved key."; exit 0; fi
    echo "Nothing pasted. Try again."; continue
  fi

  echo "Trying it..."
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$api" \
    -H "x-api-key: $key" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
    -d '{"model":"claude-opus-5-5","max_tokens":64,"output_config":{"effort":"low"},"messages":[{"role":"user","content":"Say hi."}]}')
  case "$code" in
    200)
      mkdir -p "$(dirname "$file")"
      (umask 077; printf '%s\n' "$key" > "$file")
      echo "It works. Saved. Quit and reopen Lin Flow, then tell Claude it's done."
      exit 0 ;;
    401|403)
      echo "Anthropic turned that key down ($code). Check you copied all of it." ;;
    000)
      echo "No answer from Anthropic. Check the internet connection and run this again."
      exit 1 ;;
    *)
      echo "Anthropic answered $code. Nothing saved. A 400 about credit means the account needs credit."; exit 1 ;;
  esac
done
echo "Five tries. Nothing saved."
exit 1
