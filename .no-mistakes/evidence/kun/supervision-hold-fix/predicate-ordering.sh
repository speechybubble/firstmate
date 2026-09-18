#!/bin/bash
if [[ ${1:-} = */fm-captain-hold.sh && ${2:-} = open && -e "$FM_HOME/race-armed" ]]; then
 if [ "${3:-}" = a ]; then
  /bin/bash "$@"; result=$?; touch "$FM_HOME/first-read"; exit "$result"
 elif [ "${3:-}" = b ]; then
  for ((i=0;i<1000;i++)); do [ ! -e "$FM_HOME/first-read" ] || break; /bin/sleep .01; done
  [ -e "$FM_HOME/first-read" ] || exit 2
  rm "$FM_HOME/race-armed"
  /bin/bash "$FM_ROOT_OVERRIDE/bin/fm-captain-hold.sh" hold a --title 'Synthetic A' --reason 'Hold during second predicate read' >/dev/null || exit 2
 fi
fi
exec /bin/bash "$@"
