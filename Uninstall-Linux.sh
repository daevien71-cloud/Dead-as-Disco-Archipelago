#!/usr/bin/env bash
exec python3 "$(dirname "$0")/install/install_linux.py" --uninstall "$@"
