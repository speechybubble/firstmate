#!/usr/bin/env bash
# Tear down the disposable fixture named in /tmp/fmlive-roots.
for R in $(cat /tmp/fmlive-roots 2>/dev/null); do
  pkill -f "$R/fb/claude" 2>/dev/null
  [ -x "$R/fb/tmux" ] && "$R/fb/tmux" kill-server 2>/dev/null
  chmod -R u+w "$R" 2>/dev/null; rm -rf "$R"
done
for d in /tmp/fm-live1* /tmp/fm-rsm1*; do [ -e "$d" ] && { chmod -R u+w "$d"; rm -rf "$d"; }; done
: > /tmp/fmlive-roots
