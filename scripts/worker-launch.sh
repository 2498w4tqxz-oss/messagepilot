#!/bin/sh
# Install/run only inside the dedicated agent's macOS session.
set -eu
: "MESSAGEPILOT_ROOT:?Set MESSAGEPILOT_ROOT to the installed checkout}"
: "MESSAGEPILOT_ACCOUNT:?Set MESSAGEPILOT_ACCOUNT to the enrolled account ID}"
: "MESSAGEPILOT_NODE:?Set MESSAGEPILOT_NODE to the absolute Node executable}"
# Create this secret manually in the dedicated account's Keychain before using this wrapper.
MP_WORKER_ONE_TOKEN=$(/usr/bin/security find-generic-password -s "messagepilot.worker.$MESSAGEPILOT_ACCOUNT" -w)
export MP_WORKER_ONE_TOKEN
cd "$MESSAGEPILOT_ROOT"
exec "$MESSAGEPILOT_NODE" dist/src/cli.js worker worker.local.json --live
