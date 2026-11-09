#!/usr/bin/env bash
# Prints a warning only when the disk with ~/fraim is more than 85 percent full.
used="$(df -P "$HOME" | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"
[ "${used:-0}" -gt 85 ] && echo "The server disk is ${used} percent full. Ask me what takes the most space."
exit 0
