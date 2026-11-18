#!/bin/bash
# Reuse the iOS UIKit shell through Mac Catalyst, with separately signed payloads.
set -euo pipefail
export SHELL_PLATFORM=maccatalyst
exec "$(dirname "$0")/build_nxkit_shell.sh" "$@"
