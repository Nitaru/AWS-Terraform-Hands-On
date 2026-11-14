#!/usr/bin/env bash
# Terminate one web instance under steady traffic and measure what clients see
# and how long the Auto Scaling Group takes to restore full capacity.
set -uo pipefail
cd "$(dirname "$0")/../envs/dev"
export AWS_PAGER=""

URL=$(terraform output -raw url)
TG=$(aws elbv2 describe-target-groups --names tfdemo-web --query 'TargetGroups[0].TargetGroupArn' --output text)
LOG=$(mktemp)

healthy_ids() {
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.Id' --output text | tr '\t' '\n' | grep -c .
}

[ "$(healthy_ids)" -ge 2 ] || { echo "need 2 healthy targets before starting"; exit 1; }

# One request every 0.25 s, each logged as "<epoch> <http code>"; 000 means no answer at all.
( while :; do
    printf '%s %s\n' "$(date +%s)" "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$URL/")" >> "$LOG"
    sleep 0.25
  done ) &
LOOP=$!
trap 'kill $LOOP 2>/dev/null; rm -f "$LOG"' EXIT
sleep 5

VICTIM=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=tfdemo-web" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
T0=$(date +%s)
echo "terminating $VICTIM at +0s"
aws ec2 terminate-instances --instance-ids "$VICTIM" >/dev/null

recovered=""
for _ in $(seq 1 60); do
  sleep 10
  n=$(healthy_ids)
  state=$(aws ec2 describe-instances --instance-ids "$VICTIM" --query 'Reservations[0].Instances[0].State.Name' --output text)
  echo "+$(( $(date +%s) - T0 ))s  healthy targets: $n  (victim: $state)"
  if [ "$n" -ge 2 ] && [ "$state" = terminated ]; then recovered=$(( $(date +%s) - T0 )); break; fi
done
sleep 5
kill $LOOP 2>/dev/null; wait $LOOP 2>/dev/null

total=$(wc -l < "$LOG" | tr -d ' ')
bad=$(awk '$2 != 200' "$LOG" | wc -l | tr -d ' ')
echo
echo "requests sent:        $total"
echo "not answered with 200: $bad"
awk -v t0="$T0" '$2 != 200 { print "  at +" $1 - t0 "s -> " $2 }' "$LOG" | sort -u | head -20
if [ -n "$recovered" ]; then echo "full capacity restored after ${recovered}s"; else echo "capacity NOT restored within 10 minutes"; exit 1; fi
