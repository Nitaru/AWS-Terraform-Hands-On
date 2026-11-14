#!/usr/bin/env bash
# Checks the deployed stack from the outside. Run after `make apply`.
set -uo pipefail
cd "$(dirname "$0")/../envs/dev"

URL=$(terraform output -raw url)
BASTION=$(terraform output -raw bastion_ip)
KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8)
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

echo "Load balancer $URL"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/")" = 200 ] && ok "site answers 200" || bad "site answers 200"

# Two instances in two zones should both receive traffic.
seen=$(for _ in $(seq 1 30); do curl -s "$URL/"; done | sort -u | wc -l | tr -d ' ')
[ "$seen" -ge 2 ] && ok "traffic is spread over $seen instances" || bad "traffic reached only $seen instance"

echo "Web tier"
# Each row is "<id> <public ip> <private ip>". A multi-select keeps null public IPs; a flat
# projection would drop them and let this check pass on an empty list.
rows=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=tfdemo-web" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress||`none`,PrivateIpAddress]' --output text)
count=$(printf '%s\n' "$rows" | grep -c .)
[ "$count" -ge 2 ] && ok "found $count running web instances" || bad "expected >= 2 running web instances, found $count"
while read -r id pub priv; do
  [ -z "$id" ] && continue
  [ "$pub" = "none" ] && ok "$id has no public IP" || bad "$id has public IP $pub"
done <<< "$rows"

echo "Bastion $BASTION"
nc -z -w 5 "$BASTION" 22 && ok "bastion port 22 reachable" || bad "bastion port 22 reachable"

first_priv=$(printf '%s\n' "$rows" | head -1 | awk '{print $3}')
# Control: the private host must NOT answer from the internet, but must answer through the bastion.
nc -z -w 4 "$first_priv" 22 2>/dev/null && bad "private host $first_priv reachable directly" || ok "private host is not reachable directly"
# ProxyCommand (not -J) so the same host-key options apply to the jump connection too.
proxy="ssh ${SSH_OPTS[*]} -W %h:%p ubuntu@$BASTION"
out=$(ssh "${SSH_OPTS[@]}" -o "ProxyCommand=$proxy" "ubuntu@$first_priv" 'hostname; sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin) "' 2>&1)
echo "$out" | grep -q 'passwordauthentication no' && ok "SSH via bastion works; password login is off" || bad "SSH via bastion: $out"
echo "$out" | grep -q 'permitrootlogin no' && ok "root login is off on the private host" || bad "root login is not off"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
