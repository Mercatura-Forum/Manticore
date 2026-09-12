#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <payload-file>" >&2
  exit 2
fi

sha256sum "$1" | awk '{ print $1 }'
