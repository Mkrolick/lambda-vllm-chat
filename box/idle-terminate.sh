#!/usr/bin/env bash
# Runs as root every 5 minutes (lambdachat-idle.timer). Terminates this Lambda instance once vLLM has had no requests for
# IDLE_MIN minutes. "Activity" means vLLM's finished-request counter changed, or a request is running or queued.
# If vLLM is down, the box counts as idle too. `touch /var/lib/lambdachat/keep` (lambdachat keepalive on) disables it.
set -u
. /etc/lambdachat/idle.env  # INSTANCE_ID, IDLE_MIN
S=/var/lib/lambdachat
now=$(date +%s)
[ -s "$S/last_active" ] || echo "$now" >"$S/last_active"

metrics=$(curl -fs -m 10 http://127.0.0.1:8000/metrics || true)
sum() { printf '%s\n' "$metrics" | awk -v pat="^vllm:$1[{ ]" '$0 ~ pat {s += $NF} END {printf "%d", s}'; }
done_total=$(sum request_success_total)
in_flight=$(( $(sum num_requests_running) + $(sum num_requests_waiting) ))

if [ "$done_total" != "$(cat "$S/last_count" 2>/dev/null)" ] || [ "$in_flight" -gt 0 ] || [ -e "$S/keep" ]; then
  echo "$now" >"$S/last_active"
fi
echo "$done_total" >"$S/last_count"

idle_min=$(( (now - $(cat "$S/last_active")) / 60 ))
echo "idle ${idle_min}/${IDLE_MIN} min (requests done: $done_total, in flight: $in_flight)"
[ "$IDLE_MIN" -gt 0 ] && [ "$idle_min" -ge "$IDLE_MIN" ] || exit 0

echo "idle for $idle_min min: terminating instance $INSTANCE_ID"
curl -fsS -m 60 -X POST https://cloud.lambda.com/api/v1/instance-operations/terminate \
  -H "Authorization: Bearer $(cat /etc/lambdachat/lambda-api-key)" -H "Content-Type: application/json" \
  -A lambda-vllm-chat -d "{\"instance_ids\": [\"$INSTANCE_ID\"]}"
