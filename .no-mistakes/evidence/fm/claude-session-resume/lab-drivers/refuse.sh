#!/usr/bin/env bash
# refuse.sh <id> <label> <fm-control relaunch args...>: drive a relaunch that must
# refuse before the stop; report agent liveness, typed input, record identity.
id=$1; label=$2; shift 2
LAB=/tmp/rsl/lab; export LAB; R=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M4K823EVWQRYWV0TRYDS48QG; cd /tmp/rsl
WT=$(sed -n 's/^worktree=//p' $LAB/home/state/$id.meta)
PP=$(./lab.sh ltmux display -p -t firstmate:fm-$id '#{pane_pid}'); AG=
for f in $LAB/userhome/.claude/sessions/*.json; do p=$(jq -r .pid "$f"); pstree -p $PP | grep -q "($p)" && AG=$p; done
cp $LAB/home/state/$id.meta /tmp/rsl/meta-before; cp $LAB/home/data/$id/brief.md /tmp/rsl/brief-before 2>/dev/null || : > /tmp/rsl/brief-before
J=$LAB/home/state/$id.control-relaunch; if [ -e $J ]; then cp $J /tmp/rsl/j-before; else rm -f /tmp/rsl/j-before; fi
SIDS_BEFORE=$(cat $LAB/userhome/.claude/sessions/*.json | jq -r '"\(.pid) \(.sessionId)"' | sort)
echo "## refusal: $label (task $id, agent pid $AG)"
echo "\$ fm-control.sh $id relaunch $*"
./lab.sh labenv $R/bin/fm-control.sh $id relaunch "$@" 2>&1 | grep -v '^fm-gate-refuse'; echo "rc=${PIPESTATUS[0]}"
sleep 0.5
echo "\$ task agent $AG still alive? $(kill -0 $AG 2>/dev/null && echo yes || echo NO)"
echo "\$ every prior Claude process still alive with the same session? $([ "$SIDS_BEFORE" = "$(cat $LAB/userhome/.claude/sessions/*.json | jq -r '"\(.pid) \(.sessionId)"' | sort)" ] && echo yes || echo NO)"
echo "\$ /exit typed into the pane? $(jq -r 'select(.type=="command") | .text' $LAB/userhome/.claude/projects/*/*.jsonl 2>/dev/null | wc -l) /exit lines total in transcripts"
if [ -e /tmp/rsl/j-before ]; then echo "\$ relaunch journal unchanged (no new transaction)? $(cmp -s /tmp/rsl/j-before $J && echo yes || echo NO)"; else echo "\$ relaunch transaction opened? $([ -e $J ] && echo YES || echo none)"; fi
echo "\$ task record byte-identical? $(cmp -s /tmp/rsl/meta-before $LAB/home/state/$id.meta && echo yes || echo NO)"
echo "\$ brief byte-identical? $(cmp -s /tmp/rsl/brief-before $LAB/home/data/$id/brief.md && echo yes || echo NO)"
echo
