# AWS Terraform Hands-On

[![ci](https://github.com/Nitaru/AWS-Terraform-Hands-On/actions/workflows/ci.yml/badge.svg)](https://github.com/Nitaru/AWS-Terraform-Hands-On/actions/workflows/ci.yml)

A small, production-shaped AWS stack written as Terraform modules: a VPC with public and private
subnets, a locked-down bastion, and an Auto Scaling web tier behind an Application Load Balancer.
It was applied to a real AWS account, tested from the outside, stress-tested by killing an instance,
and destroyed again. The numbers below are measurements from that run.

```
                     internet
                        │
          ┌─────────────┴─────────────┐
          │ HTTP :80                  │ SSH :22, one admin IP only
          ▼                           ▼
 ┌─────────────────── VPC 10.20.0.0/16 ─────────────────────────────────────┐
 │  public subnets (2 AZs)                                                  │
 │   ┌──────────────────────┐          ┌─────────────┐   ┌──────────────┐   │
 │   │ Application Load     │          │ Bastion     │   │ NAT gateway  │   │
 │   │ Balancer             │          │ (t3.micro)  │   │ (outbound)   │   │
 │   └──────────┬───────────┘          └──────┬──────┘   └──────▲───────┘   │
 │              │ :80, only from the ALB      │ :22, only from  │           │
 │  private subnets (2 AZs)                   │ the bastion     │           │
 │   ┌──────────▼────────────────────────────▼─────────────────┴────────┐   │
 │   │ Auto Scaling Group, 2-4 x t3.micro (nginx), CPU target 50%       │   │
 │   │ no public IPs, IMDSv2 only, encrypted volumes                    │   │
 │   └──────────────────────────────────────────────────────────────────┘   │
 │   VPC flow logs -> CloudWatch (kept 1 year)                              │
 └──────────────────────────────────────────────────────────────────────────┘
```

## Run it

Needs Terraform >= 1.10, the AWS CLI with credentials configured, and an SSH key pair.

```sh
cp envs/dev/terraform.tfvars.example envs/dev/terraform.tfvars   # set your IP as x.x.x.x/32 and your public key
make bootstrap BUCKET=<globally-unique-name>   # one-time: S3 bucket for remote state
make init      BUCKET=<same-name>
make plan
make apply
make test                                      # 11 checks against the live stack
make demo-alarm                                # break every web instance, watch the alarms fire and clear
make destroy                                   # stop paying
```

`make check` runs everything CI runs (`fmt`, `validate`, a Checkov security scan and 17 offline module tests) and needs no AWS account.

## What it demonstrates

| Topic | How |
|---|---|
| **Modules** | [`network`](modules/network), [`bastion`](modules/bastion) and [`app`](modules/app), composed by [`envs/dev`](envs/dev). |
| **Remote state** | S3 bucket with versioning, encryption, TLS-only policy and public access blocked. Locking uses S3's native lockfile, so there is no DynamoDB table. Bucket name is passed at init time, so no account details live in Git. |
| **Network segmentation** | Web instances sit in private subnets with no public IP. Only the load balancer can reach port 80 and only the bastion can reach port 22, both by security-group reference rather than CIDR. |
| **Bastion hardening** | SSH from one admin address only (the module refuses `0.0.0.0/0`), key-only login, no root login, fail2ban, IMDSv2. Same approach as my [Linux project](https://github.com/Nitaru/Linux-Hands-On). |
| **Auto Scaling** | Launch template, rolling instance refresh (never below 50% healthy), CPU target tracking, ELB-based health checks. |
| **Security baseline** | Encrypted volumes, IMDSv2 required, default security group emptied, VPC flow logs, invalid-header dropping on the ALB. |
| **Policy as code** | Checkov in CI: 100 Terraform checks pass, 0 fail, 9 are skipped (plus 43 on the workflows). Every skip has its reason written in the code next to the resource. |
| **Monitoring** | Five CloudWatch alarms (unhealthy targets, load balancer 5xx, instance 5xx, capacity below the minimum, high CPU) that all notify one SNS topic, and a four-panel dashboard. `make demo-alarm` proves they are wired to real metrics. See the alarm test below. |
| **Honest testing** | [`scripts/verify.sh`](scripts/verify.sh) checks the stack from outside, and [`scripts/demo-selfheal.sh`](scripts/demo-selfheal.sh) kills an instance under load and measures what clients see. |

## Measured results

One real run in `eu-north-1`:

| What | Result |
|---|---|
| Resources created | 37 |
| First `apply` | about 2.5 minutes before it failed (see below), 2 minutes for the retry |
| Slowest resources | ALB 2m24s, NAT gateway 1m45s |
| New instances passing ALB health checks | under a minute after launch |
| `verify.sh` | 11 passed, 0 failed (9 before the monitoring checks were added) |
| `destroy` | 37 resources in 1m42s, then confirmed with the AWS API: 0 instances, NAT gateways, load balancers, Elastic IPs, VPCs or ASGs left |
| Cost | the stack ran for roughly 30 minutes. At about $0.12 to $0.15 per hour (NAT gateway, ALB, public IPv4 addresses, three t3.micro), that is well under $1. This is an estimate from list prices, not a number from the bill. |

### Self-healing test

`scripts/demo-selfheal.sh` sends a request every 0.25 s, terminates one of the two web instances,
and waits for the Auto Scaling Group to recover.

| What | Result |
|---|---|
| Capacity back to 2 healthy instances | **102 seconds** |
| Requests sent | 210 |
| Requests that did not get a 200 | **11 (5.2%)** |
| When they failed | between +2 s and +22 s after the kill: 502 first, then timeouts |

So the stack heals itself, but it is **not zero-downtime for an abrupt instance loss**. I first
explained the failed requests as the load balancer sending traffic to a dead target until its health check
has failed twice, and predicted that a 5 s interval would roughly halve them. **I tested that and it was wrong**
([docs/health-check-experiment.md](docs/health-check-experiment.md)): at 10 s, 10 of 322 requests failed between +2 s and +16 s; at 5 s,
10 of 395 failed between +2 s and +15 s. The same number, so the health check is not what limits it
(the failures also stop at about 9 s, before two 10 s checks could even fail). I did not find the real cause; the likely one is
the time between terminating an instance and the Auto Scaling group taking it out of the load balancer, which I did not measure.
This is different from a planned rollout, where connection draining and
the rolling refresh keep traffic clean. My [Kubernetes project](https://github.com/Nitaru/Kubernetes-Hands-On)
covers the planned-rollout case with measured zero failed requests.

### Alarm test

`make demo-alarm` stops nginx on every web instance while sending a request every half second, then watches the alarms until they
have fired and cleared. One run on 2026-11-18:

| What | Result |
|---|---|
| `tfdemo-unhealthy-hosts` went to ALARM | after **17 s** |
| `tfdemo-elb-5xx` went to ALARM | after **43 s** |
| Every alarm back to OK | after about **7.7 minutes**, once the Auto Scaling group had replaced the instances |
| Requests that did not get a 200 | **283 of 647** during that outage |

The two alarms that had to fire did. The other three (instance 5xx, capacity, CPU) stayed OK, which is also right: nginx was
stopped, so no instance returned 5xx, the group kept its instances until their health checks failed, and CPU was idle. The test fails if
a required alarm never fires or one does not return to OK. **Not covered:** the SNS topic has no subscriber, so nothing was actually
delivered to a person, and one run is one run. My first attempt at this script was wrong in three ways (it needed bash 4,
`ssh` swallowed the second instance's address from stdin, and an alarm left over from the bootstrap hid the start state); all fixed.

## Things that went wrong, and what they taught me

- **On a fresh apply the first web instances can boot before the NAT route exists.** The Auto Scaling group was created 19 s into the apply, the NAT
  gateway only after 1m55s, so the first two instances had no way out to install nginx. The console showed `Failed to run module scripts_user`, both
  instances failed their health checks, and the group replaced them after about 4 and 6 minutes (the replacements were fine). `depends_on = [module.network]`
  on the app and bastion modules fixes the order. Checked with a second fresh apply: the group history shows 0 terminations and both instances became
  healthy on their own. One run each, and the cause is the best reading of the order and the failed script, not something I captured from the instance's own log.
- **The first `apply` failed at the Auto Scaling Group** with "Access denied when attempting to assume
  role AWSServiceRoleForAutoScaling". On a new account AWS creates that service-linked role the first
  time Auto Scaling is used, and it had not propagated when the group launched. The role appeared a
  moment later, the group's later scaling activities succeeded, but Terraform had already marked the
  group as tainted. Planning again showed "replace the ASG", and the retry worked. Declaring
  `aws_iam_service_linked_role` in Terraform would avoid it on a fresh account.
- **My first verification check could never fail.** The probe that asked "do the web instances have
  a public IP?" used a flat JMESPath projection, which silently drops null values. The instances had no
  public IP, so the query returned nothing, the loop ran zero times and the check "passed". It now
  requires finding the expected instances and checks each one by ID. A check that has never been shown
  to fail proves nothing.
- **`ssh -J` does not pass host-key options to the jump host.** The bastion hop failed with "Host key
  verification failed" until I used an explicit `ProxyCommand`.
- **Homebrew had no `tflint` package and a numpy link conflict broke `checkov`.** Checkov runs from an
  isolated virtualenv instead, and `tflint` runs in CI.
- **Some Checkov findings were false positives.** It flagged "ingress from 0.0.0.0/0 to port 22" on a
  rule whose source is a security group. Those are skipped with a note, not hidden: the rule is the
  proof the other way round, because `verify.sh` shows the private host is not reachable directly but
  is reachable through the bastion.

## Design decisions and trade-offs

- **One NAT gateway, not one per AZ.** It halves the cost for a demo. If its zone fails, private
  instances lose outbound internet but keep serving traffic. `enable_nat = false` removes it entirely.
- **SSH through a bastion rather than only SSM.** This repo is part of a Linux and bastion-host
  portfolio, so the SSH path is the point. SSM Session Manager would remove the open port.
- **Plain HTTP on the load balancer.** There is no domain in the demo, so there is no certificate.
- **Instances configured with user data.** Simple and testable here. Ansible, as in the
  [Linux project](https://github.com/Nitaru/Linux-Hands-On), is the next step.

## What I would change for production

| Gap | Fix |
|---|---|
| HTTP only | ACM certificate, HTTPS listener, redirect on port 80, TLS 1.2+ policy |
| No WAF or access logs | AWS WAF on the ALB, ALB access logs to S3 |
| Open SSH port on the bastion | SSM Session Manager and no inbound port |
| Flow logs not KMS-encrypted | Customer-managed KMS key |
| Single NAT gateway | One per AZ |
| Admin-wide credentials used for the demo | A scoped Terraform role, and GitHub Actions authenticating through OIDC to run `plan` on pull requests |
| ALB deletion protection off | On, so the demo is the only exception |

## Module tests

`modules/*/tests/*.tftest.hcl` hold 14 `terraform test` checks, run by `make test-modules` and in CI. They use a mocked
AWS provider, so they create nothing, cost nothing and need no credentials. They pin the properties that matter:
the bastion's `admin_cidr` refuses `0.0.0.0/0` and anything that is not a CIDR, SSH to the web tier is allowed only from
the bastion's security group, the web instances require IMDSv2 and encrypted gp3 disks, HTTP reaches them only from the
load balancer, the health check is the one the recovery numbers below assume, and the NAT gateway and subnet layout
are what the README describes.

To check that they can fail, I broke four of those properties on purpose in a scratch copy (IMDSv2 off, SSH from a CIDR
instead of the bastion group, the `0.0.0.0/0` validation removed, public IPs on launch) and each break turned the
matching test red. **Not covered:** anything about how real AWS behaves. A mock accepts whatever the configuration says,
so these tests catch a configuration someone weakened, not an AWS service that behaves differently. The nine live checks
in `make test` exist for that.

## Layout

```
bootstrap/          S3 bucket for Terraform state (run once, keeps local state)
envs/dev/           the environment: wires the modules together
modules/network/    VPC, subnets, NAT, routes, flow logs
modules/bastion/    hardened SSH entry point
modules/app/        ALB, launch template, Auto Scaling Group, scaling policy
scripts/            verify.sh (11 checks), demo-selfheal.sh, demo-alarm.sh
.github/            CI: fmt, validate, Checkov, tflint
```

## Versions

Terraform 1.15, AWS provider 6.x, Ubuntu 24.04 LTS, Checkov 3.4.

## License

MIT, see [LICENSE](LICENSE).
