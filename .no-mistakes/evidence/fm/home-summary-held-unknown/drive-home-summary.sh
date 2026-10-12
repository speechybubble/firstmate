#!/usr/bin/env bash
# Disposable live drive of fm-fleet-snapshot.sh --secondmate-home-summary.
# Builds a throwaway FM_HOME whose scouts have no running worker (fake tmux lists
# no windows) and prints the real CLI's home summary for each case.
set -u
ROOT=$1; CASE=$2
H=$(mktemp -d /tmp/fm-live-home.XXXXXX); trap 'rm -rf "$H"' EXIT
mkdir -p "$H/state" "$H/data" "$H/projects/wt" "$H/config" "$H/bin"
cat > "$H/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in list-windows|list-sessions) exit 0;; display-message) exit 1;; esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$H/bin/no-mistakes"
chmod +x "$H/bin/"*
scout() {  # id status-line
  printf 'window=firstmate:fm-%s\nworktree=%s/projects/wt\nproject=alpha\nharness=claude\nkind=scout\n' "$1" "$H" > "$H/state/$1.meta"
  printf '%s\n' "$2" > "$H/state/$1.status"
}
{
  echo '## In flight'
  case "$CASE" in
    incident|mixed)
      echo '- [ ] trelume-thoughts-reading - Read thoughts (repo: alpha) (kind: scout) (hold: backlog hold until captain picks up) (hold-kind: external) (since 2026-10-01)'
      echo '- [ ] website-process-revision - Process revision (repo: alpha) (kind: scout) (since 2026-10-01)';;
  esac
  case "$CASE" in
    mixed) echo '- [ ] lost-scout - Unknown with no hold (repo: alpha) (kind: scout) (since 2026-10-01)';;
    noagent) echo '- [ ] noagent-scout - Detail-text only (repo: alpha) (kind: scout) (since 2026-10-01)';;
  esac
  printf '\n## Queued\n\n## Done\n'
} > "$H/data/backlog.md"
case "$CASE" in
  incident|mixed)
    scout trelume-thoughts-reading 'working: reading the thoughts doc'
    scout website-process-revision 'paused: held until the captain reviews the brief';;
esac
case "$CASE" in
  mixed) scout lost-scout 'working: reading';;
  noagent) scout noagent-scout 'no running agent observed';;
esac
echo "### case: $CASE"
PATH="$H/bin:$PATH" FM_HOME="$H" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary \
  | jq '{valid,state,reason,invalidity,
         endpoints:[.endpoints[]|{id,state}],
         holds:[.holds[]|{id,source,reason}]}'
