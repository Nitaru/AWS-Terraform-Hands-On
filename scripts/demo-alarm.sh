#!/usr/bin/env bash
# Prove the alarms are wired to real metrics: break every web instance under traffic, watch the alarms go to ALARM,
# let the Auto Scaling group replace the instances, and watch them return to OK.
# An alarm that has never fired proves nothing, so this is the check that can fail.
set -uo pipefail
cd "$(dirname "$0")/../envs/dev" || exit 1
export AWS_PAGER=""

URL=$(terraform output -raw url)
BASTION=$(terraform output -raw bastion_ip)
KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8)
ALARMS=(tfdemo-unhealthy-hosts tfdemo-elb-5xx tfdemo-target-5xx tfdemo-capacity-below-minimum tfdemo-cpu-high)
MUST_FIRE=(tfdemo-unhealthy-hosts tfdemo-elb-5xx)   # what stopping nginx everywhere has to trigger
LOG=$(mktemp)
FIRED=$(mktemp -d)   # one file per alarm that reached ALARM, holding the seconds it took (portable: macOS bash 3.2 has no associative arrays)
TG=$(aws elbv2 describe-target-groups --names tfdemo-web --query 'TargetGroups[0].TargetGroupArn' --output text)

state() { aws cloudwatch describe-alarms --alarm-names "$1" --query 'MetricAlarms[0].StateValue' --output text; }
healthy() { aws elbv2 describe-target-health --target-group-arn "$TG" --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text; }
all_ok() { local a; for a in "${ALARMS[@]}"; do [ "$(state "$a")" = OK ] || return 1; done; }

# Start from a clean state: two healthy targets and every alarm OK (an alarm from an earlier incident would hide the test).
echo "waiting for 2 healthy targets and every alarm OK..."
for _ in $(seq 1 60); do
  if [ "$(healthy)" -ge 2 ] && all_ok; then break; fi
  sleep 10
done
{ [ "$(healthy)" -ge 2 ] && all_ok; } || { echo "start state is not clean, not running the test"; exit 1; }

echo "alarms before:"
for a in "${ALARMS[@]}"; do printf '  %-34s %s\n' "$a" "$(state "$a")"; done

rows=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=tfdemo-web" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' --output text)
[ "$(printf '%s\n' "$rows" | grep -c .)" -ge 2 ] || { echo "need 2 running web instances"; exit 1; }

# Steady traffic so the load balancer has requests to count.
( while :; do printf '%s %s\n' "$(date +%s)" "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$URL/")" >> "$LOG"; sleep 0.5; done ) &
LOOP=$!
trap 'kill $LOOP 2>/dev/null; rm -rf "$LOG" "$FIRED"' EXIT
sleep 10

T0=$(date +%s)
echo "stopping nginx on every web instance at +0s"
proxy="ssh ${SSH_OPTS[*]} -W %h:%p ubuntu@$BASTION"
while read -r id ip; do
  [ -z "$id" ] && continue
  # -n: ssh must not read the rest of the here-string from stdin, or only the first instance is stopped
  ssh -n "${SSH_OPTS[@]}" -o "ProxyCommand=$proxy" "ubuntu@$ip" 'sudo systemctl stop nginx' && echo "  stopped nginx on $id"
done <<< "$rows"

for _ in $(seq 1 60); do        # up to 10 minutes
  sleep 10
  line="+$(( $(date +%s) - T0 ))s "
  all_ok=1
  for a in "${ALARMS[@]}"; do
    s=$(state "$a")
    line+=" ${a#tfdemo-}=$s"
    if [ "$s" = ALARM ] && [ ! -f "$FIRED/$a" ]; then echo $(( $(date +%s) - T0 )) > "$FIRED/$a"; fi
    [ "$s" != OK ] && all_ok=0
  done
  echo "$line"
  # done when everything we expect has fired and every alarm is back to OK
  fired_all=1; for a in "${MUST_FIRE[@]}"; do [ -f "$FIRED/$a" ] || fired_all=0; done
  if [ "$fired_all" = 1 ] && [ "$all_ok" = 1 ]; then break; fi
done

kill $LOOP 2>/dev/null; wait $LOOP 2>/dev/null
total=$(wc -l < "$LOG" | tr -d ' '); bad=$(awk '$2 != 200' "$LOG" | wc -l | tr -d ' ')
echo
echo "requests sent: $total, not answered with 200: $bad"
rc=0
for a in "${MUST_FIRE[@]}"; do
  if [ -f "$FIRED/$a" ]; then echo "  $a went to ALARM after $(cat "$FIRED/$a")s"; else echo "  $a NEVER fired"; rc=1; fi
done
for a in "${ALARMS[@]}"; do [ "$(state "$a")" = OK ] || { echo "  $a is not back to OK: $(state "$a")"; rc=1; }; done
exit $rc
