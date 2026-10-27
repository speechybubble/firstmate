#!/usr/bin/env bash
# Live drive: real fm-teardown.sh against a disposable lab home, real tmux worker
# window on a private lab socket, real chrome-devtools-axi bridges + headless Chrome.
set -u
WT_SRC=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M5Y8R7P0QZBST14F2P0Q8VA1
cd "$WT_SRC"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/bhome" "$LAB/data/task-x1" "$LAB/other-home"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX
REALNPM="$HOME/.npm"
echo "== lab home: $LAB"
# --- task fixture: project, origin, landed worktree branch
git init -q --bare "$LAB/origin.git"; git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/_seed" 2>/dev/null
git -C "$LAB/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$LAB/_seed" push -q origin main; rm -rf "$LAB/_seed"
git clone -q "$LAB/origin.git" "$LAB/project"; git -C "$LAB/project" remote set-head origin main
git -C "$LAB/project" worktree add -q -b fm/task-x1 "$LAB/wt" main
git -C "$LAB/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "shippable work"
git -C "$LAB/wt" push -q origin fm/task-x1; git -C "$LAB/project" fetch -q origin
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$LAB/wt" \
  "project=$LAB/project" "kind=ship" "mode=no-mistakes" "spawn_gen=lab-task-x1" > "$LAB/state/task-x1.meta"
touch "$LAB/state/.last-watcher-beat"
# Hermetic stubs only for external services (GitHub, no-mistakes daemon, worktree pool).
printf '#!/usr/bin/env bash\ncase "$1 $2" in "pr list") echo "count: 0 (showing first 0)"; echo "pull_requests[]: []";; "pr view") exit 1;; esac\nexit 0\n' > "$LAB/fakebin/gh-axi"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/fakebin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/fakebin/no-mistakes"
# treehouse return happens after the first browser pass and before the worker's
# window closes; the stub has the still-live worker start a NEW real bridge then.
cat > "$LAB/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
echo "[lab] worker starts late-sess while teardown is mid-flight" >&2
( cd "$LAB/data/task-x1" && env HOME="$LAB/bhome" npm_config_cache="$REALNPM" FM_TASK_ID=task-x1 FM_HOME="$LAB" \
  CHROME_DEVTOOLS_AXI_SESSION=late-sess CHROME_DEVTOOLS_AXI_PORT=9433 \
  timeout 120 chrome-devtools-axi open 'data:text/html,late' >/dev/null 2>&1 )
exit 0
SH
chmod +x "$LAB/fakebin/"*
# --- worker window on the lab tmux socket, env like a real worker
tmux new-session -d -s firstmate -n fm-task-x1 -c "$LAB/data/task-x1" \
  -e FM_TASK_ID=task-x1 -e FM_HOME="$LAB" -e HOME="$LAB/bhome" -e npm_config_cache="$REALNPM" \
  "CHROME_DEVTOOLS_AXI_SESSION=own-sess CHROME_DEVTOOLS_AXI_PORT=9431 chrome-devtools-axi open 'data:text/html,own' > $LAB/own-open.log 2>&1; echo worker-idle; sleep 3600"
# --- bridges that must survive: same task id but another home; no task id at all
( cd "$LAB/other-home" && env HOME="$LAB/bhome" npm_config_cache="$REALNPM" FM_TASK_ID=task-x1 FM_HOME="$LAB/other-home" \
  CHROME_DEVTOOLS_AXI_SESSION=foreign-sess CHROME_DEVTOOLS_AXI_PORT=9434 chrome-devtools-axi open 'data:text/html,foreign' >/dev/null 2>&1 )
( cd "$LAB" && env -u FM_TASK_ID HOME="$LAB/bhome" npm_config_cache="$REALNPM" FM_HOME="$LAB" \
  CHROME_DEVTOOLS_AXI_SESSION=plain-sess CHROME_DEVTOOLS_AXI_PORT=9435 chrome-devtools-axi open 'data:text/html,plain' >/dev/null 2>&1 )
for _ in $(seq 120); do grep -q . "$LAB/own-open.log" 2>/dev/null && tmux capture-pane -p -t firstmate:fm-task-x1 | grep -q worker-idle && break; sleep 1; done
echo "== operator's pre-existing bridges (must be untouched):"
PRE=$(ps -eo pid=,args= | awk '/chrome-devtools-axi-bridge/ {print $1}' | sort)
echo "== fleet browser listing BEFORE teardown (FM_HOME=$LAB):"
FM_HOME="$LAB" bin/fm-browser-sessions.sh list
echo "== fm-teardown.sh task-x1 (real, tmux backend on lab socket)"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" bin/fm-teardown.sh task-x1
echo "teardown exit=$?"
sleep 1
echo "== tmux windows after teardown:"; tmux list-windows -a 2>&1
echo "== fleet browser listing AFTER teardown:"
FM_HOME="$LAB" bin/fm-browser-sessions.sh list
echo "== any process still carrying FM_TASK_ID=task-x1 and FM_HOME=$LAB:"
for f in /proc/[0-9]*/environ; do
  if grep -qaz "^FM_TASK_ID=task-x1$" "$f" 2>/dev/null && grep -qaz "^FM_HOME=$LAB$" "$f" 2>/dev/null; then p=${f#/proc/}; echo "  SURVIVOR ${p%/environ}: $(tr '\0' ' ' < /proc/${p%/environ}/cmdline | cut -c1-120)"; fi
done; echo "  (end)"
POST=$(ps -eo pid=,args= | awk '/chrome-devtools-axi-bridge/ {print $1}' | sort)
echo "== operator bridges still alive:"; for p in $(ps -eo pid=,args= | awk '/chrome-devtools-axi-bridge/ {print $1}'); do tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -q "^HOME=$LAB/bhome$" || echo "  $p (not lab)"; done
echo "== stop the surviving lab bridges via operator path"
FM_HOME="$LAB/other-home" bin/fm-browser-sessions.sh stop task-x1; echo "stop other-home exit=$?"
for s in plain-sess foreign-sess; do HOME="$LAB/bhome" CHROME_DEVTOOLS_AXI_SESSION=$s timeout 30 chrome-devtools-axi stop >/dev/null 2>&1; done
for f in /proc/[0-9]*/environ; do grep -qaz "^HOME=$LAB/bhome$" "$f" 2>/dev/null && { p=${f#/proc/}; kill -9 ${p%/environ} 2>/dev/null; echo "  reaped leftover lab pid ${p%/environ}"; }; done
tmux kill-server 2>/dev/null
rm -rf "$LAB"; echo "== lab removed"
