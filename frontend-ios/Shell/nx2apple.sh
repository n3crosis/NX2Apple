#!/bin/sh
# Run CLI commands in the signed Catalyst executable.
set -eu
case $0 in
    */*) resource_path=${0%/*} ;;
    *) resource_path=. ;;
esac
resource_dir=$(CDPATH= cd -P -- "$resource_path" && pwd -P)
app="$resource_dir/../MacOS/DmShell"
if [ ! -x "$app" ]; then
    printf '%s\n' 'Run this script from inside the NX2Apple app bundle.' >&2
    exit 69
fi
if [ "$#" -eq 0 ]; then
    set -- --help
fi
case $1 in
    -h|--help|help|--version|version|status|inspect|verify|receive|build|import|list|export|share|set-signing|set-prod-keys) ;;
    *)
        printf '%s\n' 'Unknown command. Run nx2apple.sh --help.' >&2
        exit 64
        ;;
esac
exec "$app" "$@"
