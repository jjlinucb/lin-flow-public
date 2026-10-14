#!/bin/bash
# Saves the TypeSafe key that scripts/test-plan.py uses, after trying it once.
#
#   bash scripts/setup-typesafe.sh
#
# It asks for the key, hides it as you paste, asks Jev one tiny question with it, and saves it to
# ~/.config/typesafe/key (readable by you only; on Windows, the one in your user profile) only if
# the answer comes back. The key is never printed. Runs on the Mac's /bin/bash 3.2 and in Git Bash.

set -u
# Where scripts/test-plan.py looks. On Windows, Python's ~ is the user profile, while Git Bash's
# $HOME on John's machines is his home share, //fileserver/share, so there the key goes in the
# profile.
home=$HOME
if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then home=$(cygpath -u "$USERPROFILE"); fi
file="$home/.config/typesafe/key"
api="https://api.typesafe.ai/v1/systemone"

echo
echo "TypeSafe key for the Lin Flow test planner"
echo "------------------------------------------"
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
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$api" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d '{"state":"hello","model":"jev-latest","questions":{"q":{"type":"noul","instructions":"Is this a greeting?"}}}')
  case "$code" in
    200)
      mkdir -p "$(dirname "$file")"
      (umask 077; printf '%s\n' "$key" > "$file")
      echo "It works. Saved. You can close this tab and tell Claude it's done."
      exit 0 ;;
    401|403)
      echo "TypeSafe turned that key down ($code). Check you copied all of it." ;;
    000)
      echo "No answer from TypeSafe. Check the internet connection and run this again."
      exit 1 ;;
    *)
      echo "TypeSafe answered $code. Nothing saved."; exit 1 ;;
  esac
done
echo "Five tries. Nothing saved."
exit 1
