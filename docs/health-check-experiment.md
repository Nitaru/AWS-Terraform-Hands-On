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
