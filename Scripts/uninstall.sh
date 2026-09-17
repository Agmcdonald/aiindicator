#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "$script_dir/manage/blink_install.py" ]]; then
    manager="$script_dir/manage/blink_install.py"
else
    manager="$script_dir/blink_install.py"
fi
exec /usr/bin/python3 -B "$manager" uninstall "$@"
