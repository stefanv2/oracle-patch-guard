#!/bin/bash
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec /usr/bin/python3 -I "$(dirname -- "${BASH_SOURCE[0]}")/opg_prepare_cycle.py" "$@"
