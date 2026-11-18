# Two things the audit suspected, measured

Both come from my own read of the code (`PLAN.md`, step 5.0), neither had a measurement behind it. Predictions are written before the run.

## 1. Does a shorter health check shrink the failed-request window?

The self-healing test (`make demo-selfheal`) kills one of two web instances under steady traffic. The README measured **11 of 210 requests failed (5.2%)**
between +2 s and +22 s, and said the cause is the health check (10 s interval, 2 failures: the load balancer keeps sending traffic to a dead target
until it has failed twice), but that shortening it was **not tested**, so no number was claimed. This tests it: interval **5 s**, timeout **3 s**
(an ALB needs the timeout below the interval), still 2 failures.

**Predictions.**
1. The failed-request window shrinks from about 20 s to **about 10 s**, so failed requests fall from about 5% to **about 2 to 3%**, roughly halved.
2. The time for the group to get back to two healthy instances does **not change meaningfully** (about 100 s), because it is dominated by launching and
   booting a new instance, not by detection.
3. The baseline run (interval 10 s) in this session lands **near the earlier result** (about 5%), so that the comparison is against today's stack and
   not only against a number from days ago. One run each, so expect noise of a few failed requests either way.

## 2. Does `desired_capacity` in the config make Terraform fight the autoscaler?

`modules/app` sets `desired_capacity = var.min_size` next to a target-tracking policy. If the policy scales the group out, the next `terraform plan`
should want to put the capacity back.

**Prediction.** After the capacity is changed by hand to 3 (what the autoscaler would do), `terraform plan` **shows a change** to `desired_capacity`
(3 to 2). With `lifecycle { ignore_changes = [desired_capacity] }` the same plan shows **no changes**.

Not claimed: anything beyond this stack, one session, one run per variant; behaviour under a real scaling event (the capacity is changed with the CLI to
stand in for one).

## Results (2026-11-18, one stack, one run per variant)

| | 10 s interval (baseline) | 5 s interval, 3 s timeout |
|---|---|---|
| Requests that did not get a 200 | **10** of 322 | **10** of 395 |
| Failure window | +2 s to +16 s (502s, then two timeouts) | +2 s to +15 s (502s, then two timeouts) |
| Group back to two healthy instances | 147 s | 181 s |

| Prediction | Verdict |
|---|---|
| 1. A 5 s interval shrinks the failure window from about 20 s to about 10 s and roughly halves the failed requests | **Refuted.** The same 10 failed requests and a 14 s against a 13 s window. The percentages (3.1% against 2.5%) only differ because the test sent more requests while a slower recovery ran, which is why the absolute count is the number to read |
| 2. The recovery time does not change meaningfully | **Inconclusive.** 147 s against 181 s here, and 102 s in the earlier run: the spread between runs is bigger than any effect this change could have |
| 3. The baseline lands near the earlier result | **Yes in absolute terms** (10 failed requests now, 11 before), no in percentage (3.1% now, 5.2% before) for the reason above |
| `desired_capacity`: plan shows a change after a manual scale-out, and no change with `ignore_changes` | **Confirmed both ways.** With the group set to 3 by hand: `~ desired_capacity = 3 -> 2` before the fix, `No changes` after it |

**What this changes.** The README's explanation of the 5.2% was a guess and it was wrong, so it now says so. The failure window ends at about 9 s,
before two 10 s health checks could have failed, which points away from the health check. I did not find what does set it. The most likely
candidate is the delay between terminating an instance and the Auto Scaling group deregistering it from the load balancer, but that is a hypothesis
and nothing here measured it. The health check variables stay (defaults unchanged, 10 s and 5 s) because they cost nothing, but a shorter interval is not
a fix for the failed requests. The `desired_capacity` fix stays: it is a real bug that the plan showed.

Not claimed: the cause of the window, anything about a real scaling event (the capacity was changed with the CLI to stand in for one), or
anything from one run of each.
