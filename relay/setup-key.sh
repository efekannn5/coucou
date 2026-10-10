#!/bin/sh
# Creates the key that signs the Mac's requests to your relay, and puts it in
# the two places that need it: the Worker (secret RELAY_KEY) and the Mac's
# Keychain (account phoneRelayKey). The key is never written to disk, never
# shown and never passed on a command line: both copies go through stdin.
# Run it again to rotate the key.
set -eu
cd "$(dirname "$0")"

SERVICE="fr.louisraille.NotchBuddy"   # Keychain service of the Mac app (ClaudeService.swift)
ACCOUNT="phoneRelayKey"

KEY=$(openssl rand -hex 32)

printf '%s' "$KEY" | npx wrangler secret put RELAY_KEY
printf 'add-generic-password -U -s %s -a %s -w %s\n' "$SERVICE" "$ACCOUNT" "$KEY" | security -i >/dev/null

unset KEY
echo "Relay key set in the Worker and in the Keychain."
echo "The first time Coucou reads it, macOS asks: click Always Allow."
