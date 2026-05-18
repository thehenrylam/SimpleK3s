# Pricing

This document provides estimated monthly costs for running SimpleK3s across common deployment profiles, along with a comparison against equivalent EKS setups.

> **Disclaimer:** All prices are estimates based on AWS `us-east-1` on-demand rates as of May 2026.<br/>
> Actual costs will vary by region, traffic, and spot market conditions. Always verify current rates at the [AWS Pricing Calculator](https://calculator.aws/pricing/2/home).<br/>
> AWS Cognito (IdP), SSM Parameter Store, and S3 (bootstrap bucket) are either free tier or negligible in cost and are excluded from these estimates.

---

## Reference Rates (us-east-1)

| Resource       | Rate (Hourly)   | Rate (Monthly)                 | 
| -------------: | :-------------- | :----------------------------- |
| t4g.small      |  $0.0168/hr     | ~$12/mo                        |
| t4g.medium     |  $0.0336/hr     | ~$25/mo                        |
| t4g.large      |  $0.0672/hr     | ~$49/mo                        |
| t4g.xlarge     |  $0.1344/hr     | ~$98/mo                        |
| m6g.medium     |  $0.039/hr      | ~$28/mo                        |
| m6g.large      |  $0.077/hr      | ~$55/mo                        |
| m6g.xlarge     |  $0.154/hr      | ~$111/mo                       |
| c6g.medium     |  $0.034/hr      | ~$24/mo                        |
| c6g.large      |  $0.068/hr      | ~$49/mo                        |
| c6g.xlarge     |  $0.136/hr      | ~$98/mo                        |
| db.r6g.2xlarge |  $0.899/hr      | ~$647/mo                       |
| db.r6g.4xlarge |  $1.798/hr      | ~$1295/mo                      |
| EBS gp3        | ~$0.00001/GB/hr | $0.08/GB/mo                    |
| ELB (Network)  | --N/A--         | ~$16/mo (low traffic baseline) |
| Public IPv4    |  $0.005/hr      | ~$3.65/mo per address          |

*NOTE: Spot instances (for the t4g family) can provide up to ~60-70% savings compared to on-demand instances.
- The discount rates are completely dependent on the current market demand for instances
- Spot instances are NOT recommended to be used on control plane nodes.
    - Spot instances add a lot of risk of stability on the Kubernetes cluster
    - Having a 1xt4g.large (non-spot) control plane is better than 3xt4g.medium (spot) control plane 

---

## Scenarios

These are the scenarios to help provide a clear picture of how much SimpleK3s would cost, so developers can properly estimate and budget these kinds of Kubernetes setups.

**Assumptions for all Scenarios:**
- This setup is used 24/7 (typical uptime of a SaaS service)
- Only control plane costs are calculated (unless otherwise specified under **Additional Assumptions**)
- AWS Cognito used as IdP and is free via the free-tier condition (under 50K MAU)

### Scenario 0 — Control Group (EKS with Feature Parity to SimpleK3s)

A cost baseline of an EKS setup with the same platform capabilities that SimpleK3s provides by default: 
- GitOps deployment (ArgoCD)
- Monitoring (Prometheus + Grafana)
- Autoscaling (Karpenter)
- Ingress (Traefik)
- Policy enforcement (Kyverno)
- Secrets management (External Secrets)

**Additional Assumptions:**
- 2 × t4g.large worker nodes to host all system pods with adequate headroom (Represented as `Workers (System)`)
- All tools (e.g. ArgoCD) are self-installed via Helm (no AWS managed add-ons) - ***same as SimpleK3s***
- Single NLB for ingress (via Traefik) - ***same as SimpleK3s***
- `Est. Monthly Cost` equals to 30 days of full 24/7 usage 

| Line Item              | Est. Monthly Cost | Detail                    | 
| :--------------------- | :---------------- | :------------------------ | 
| EKS Control Plane      | $73.00            | AWS managed, flat fee     |
| EC2 — Workers (System) | $98.11            | 2 × t4g.large (on-demand) |
| EBS — Workers (System) | $3.20             | 2 × 20 GB gp3             |
| Network Load Balancer  | $16.43            | 1 NLB (low traffic)       |
| Public IPv4 (System)   | $7.30             | 2 address(es) × $3.65/mo  |
| **Total**              | **$198.04**       |                           |

> ***Reminder***: Although EKS helps simplify the creation of a Kubernetes cluster, installation and configuration of each tool like ArgoCD is still needs to be done by the developer. Not to mention the requirement to stay on the AWS's EKS upgrade cycle.

### Scenario 1 — Baseline (Default Settings)

The out-of-the-box configuration: 3 control-plane nodes running K3s, all system pods (ArgoCD, Grafana, Prometheus, Traefik, etc.) scheduled onto the control plane. No persistent agent nodes — Karpenter is idle until workloads demand scale-out.

| Line Item                   | Est. Monthly Cost | Detail                        |
| --------------------------: | :---------------- | :---------------------------- |
| EC2 — Control Plane         | $73.58            | 3 × t4g.medium (on-demand)    |
| EBS — Control Plane         | $1.60             | 1 × 20 GB gp3                 |
| Public IPv4 - Control Plane | $10.95            | 3 address(es) × $3.65/mo      |
| Network Load Balancer       | $16.43            | 1 NLB (low traffic)           |
| **Total**                   | **$102.56**       |                               |

> SimpleK3s costs ***47%*** of a comparable EKS setup without changing anything

---

### Scenario 2 — Cost Optimized

Minimizes spend while keeping the full platform (ArgoCD, Grafana, monitoring) operational.
Optimization Philosophy: Change the default settings while not compromising on deployment and observability (which would immediately cost the startup in terms of lost productivity and potential downtime)

| Line Item             | Est. Monthly Cost | Detail                      |
| --------------------: | :---------------- | :-------------------------- |
| EC2 — Control Plane   | $49.00            | 1 × t4g.large (on-demand)   |
| EBS — Control Plane   | $2.88             | 1 × 12 GB gp3               |
| Network Load Balancer | $16.43            | 1 NLB (low traffic)         |
| Public IPv4           | $3.65             | 1 address(es) × $3.65/mo    |
| **Total**             | **$71.96**        |                             |

> SimpleK3s costs ***63%*** of a comparable EKS setup (without HA)<br/>
> SimpleK3s costs ***30%*** of a SimpleK3s default setup

**Additional Notes:**
- Savings can extend even further if spot workers are enabled:
    - Set `capacity_type = "spot"` in `subsystems.karpenter` to enable spot workers
    - Tune `consolidate_after` (default `5m`) to aggressively reclaim idle nodes
    - Worker costs stay near $0 during off-hours when Karpenter consolidates

---

### Scenario 3 — SimpleK3s Deployment with minimal Workload (0 - 1K users)

Scenario that illustrates a standard deployment of a startup that is between month 0-12 of its life.
- The startup should either be getting Product Market Fit or attracting more users
- $100/mo burn rate on infra isn't bad at all for a startup

**Additional Assumptions:**
- Cost optimized SimpleK3s settings are used (Scenario 2)
- Assumed tech stack:
    - Frontend: ReactJS 
    - Backend: ExpressJS and NodeJS
    - Database: Supabase (Popular, well-known, and widely-used among startups)
- The startup / project is using 1.5 x t4g.small (2vCPU/2GB) with 24GB gp3 EBS
    - 0.5 x t4g.small is reserved for the dev team to experiment with new features or used as part of a blue/green deployment
        - "0.5" simply means that we expect it to be up ~50% of the time in a single month
    - 1.0 x t4g.small is to serve the customers
- Each concurrent user will on average, make 1 RPS (request per second)
- The MERN app can handle ~1K RPS (**Conservative estimate assuming SimpleK3s overhead (requires ~1GB)**)

| Line Item                  | Est. Monthly Cost | Detail                             |
| -------------------------: | :---------------- | :--------------------------------- |
| SimpleK3s Control Plane    | $71.96            | Pricing metrics of Scenario 2      |
| EC2 — Workers (On-Demand)  | $18.36            | 1.5 × t4g.small (1.5 x $0.017/hr)  |
| EBS — Workers              | $2.88             | 1.5 × 24 GB gp3                    |
| Public IPv4 - Workers      | $5.48             | 1.5 × address(es)                  |
| Database (Supabase Free)   | $0.00             | 500MB disk, 5 GB egress, 50K MAU   |
| **Total**                  | **$98.68**        |                                    |

> With the following assumptions, this can comfortably handle ~1000 users without breaking a sweat.<br/>
> In addition, this setup is protected from traffic spikes due to Karpenter's dynamic provisioning.

> **Caution**: Please be careful, although we have sources stating that t2.micros can handle 2000 RPS, `t*` type instances are primarily use burst credits to drive their performance, if the workload is consistently elevated, it will deplete its burst credits and throttle hard. Please be prepared to use `t4g.medium` instances, or `m*` type instances the moment slow response times are detected.

> ***Reminder***: This minimal setup is cheaper than a SimpleK3s default setup! (**$98.68/mo** vs **$102.56/mo**)

---

### Scenario 4 — SimpleK3s Deployment with standard Workload (~2.5K users)

Scenario that illustrates a standard deployment of a startup that is between month 12-24 of its life.
- The startup should start to get some traction
- Revenue should be enough to cover infra expenses (2.5K users at 1% conversion w/ $10/mo for each paying user ~= $250/mo)
- With the current concurrent user count, the startup should be in the position to get pre-seed or seed funding

**Additional Assumptions:**
- Default SimpleK3s settings are used (Scenario 1)
- Assumed tech stack:
    - Frontend: ReactJS 
    - Backend: ExpressJS and NodeJS
    - Database: Supabase (Popular, well-known, and widely-used among startups)
- The startup / project is using 1.5 x m6g.medium (1vCPU/4GB) with 24GB gp3 EBS
    - 0.5 x m6g.medium is reserved for the dev team to experiment with new features or used as part of a blue/green deployment
        - "0.5" simply means that we expect it to be up ~50% of the time in a single month
    - 1.0 x m6g.medium is to serve the customers
- Each concurrent user will on average, make 1 RPS (request per second)
- The MERN app can handle ~25K RPS (**Extrapolating figures from the sources below**)

| Line Item                  | Est. Monthly Cost | Detail                             |
| -------------------------: | :---------------- | :--------------------------------- |
| SimpleK3s Control Plane    | $102.56           | Pricing metrics of Scenario 1      |
| EC2 — Workers (On-Demand)  | $42.12            | 1.5 × m6g.medium (1.5 x $0.039/hr) |
| EBS — Workers              | $2.88             | 1.5 × 24 GB gp3                    |
| Public IPv4 - Workers      | $5.48             | 1.5 × address(es)                  |
| Database (Supabase PRO)    | $25.00            | 8GB disk, 250 GB egress, 100K MAU  |
| **Total**                  | **$178.04**       |                                    |

> With the following assumptions, this can comfortably handle ~2500 users without breaking a sweat.<br/>
> In addition, this setup is protected from traffic spikes due to Karpenter's dynamic provisioning.

> ***Reminder***: This complete setup is STILL cheaper than an EKS baseline setup! (**$178.04/mo** vs **$198.04/mo**)

---

### Scenario 5 — SimpleK3s Deployment with full Workload (Achieved Traction, +1M users)

Scenario that illustrates a standard deployment of a startup that is >2 years of its life.
- The startup should have funding secured via VC (seed funding)
- The startup isn't looking for cost efficiency anymore (growth at all costs mentality)

**Additional Assumptions:**
- Custom SimpleK3s settings are used (geared towards high performance)
- Assumed tech stack:
    - Frontend: ReactJS 
    - Backend: ExpressJS and NodeJS
    - Database: AWS RDS Aurora PostgreSQL (migrated from Supabase — at this scale, self-managed RDS is significantly cheaper and a dedicated platform team makes it operationally viable)
- Each concurrent user will on average, make 1 RPS (request per second)
- 1 × c6g.xlarge can handle 10K RPS (if t6g.medium w/ 1vCPU can handle 2.5K RPS, then c6g.xlarge w/ 4vCPU could handle 4x2.5K RPS)
    - From the assumptions we would need 100 × c6g.xlarge to accomodate 1M users
        - (1 c6g / 10K RPS) * (1 RPS / 1 user) * (1,000K users) = 100 c6g.xlarge
- A CDN is set up using **Cloudflare Enterprise** (unmetered bandwidth, flat monthly fee — does not charge per GB)
    - Assumed ~95% cache hit rate (Cloudflare serves cached responses directly; EC2 only handles cache misses)
    - Cloudflare and AWS have a **Bandwidth Alliance** agreement — EC2 → Cloudflare egress fees may be fully waived; this significantly impacts the data transfer line item (see table notes)
- Each user causes ~0.000025GB (25KB) of data to be transferred per request — typical for a JSON API response (images/media assumed to be served via CDN, not EC2)
    - That means each user incurs ~64.8GB/mo of raw egress (1 RPS × 0.000025GB × 2,592,000 sec/mo)
    - Total raw egress for 1M users: ~64,800,000,000GB/mo (~64.8PB/mo)
    - With 95% CDN cache hit rate, only 5% reaches EC2: ~3,240,000,000GB/mo (~3.24PB/mo) of EC2 egress

> At this scale, data transfer costs (egress: ~$0.09/GB for the first 10 TB/mo) can become a significant line item depending on your application's traffic patterns — factor this in separately.

| Line Item                       | Est. Monthly Cost | Detail                                                 |
| ------------------------------: | :---------------- | :----------------------------------------------------- |
| EC2 — Control Plane             | $294.34           | 3 × t4g.xlarge (high workload for ArgoCD + monitoring) |
| EBS — Control Plane             | $2.88             | 3 × 12 GB gp3                                          |
| Public IPv4 - Control Plane     | $10.95            | 3 × IPv4 for Control Plane                             |
| Network Load Balancer           | $33.00            | 1–2 NLBs                                               |
| EC2 — Workers (On-Demand)       | $9792.00          | 100 × c6g.xlarge (4vCPU/8GB) ($97.92/mo)               |
| EBS — Workers                   | $256.00           | 100 × 32 GB gp3                                        |
| Public IPv4  - Workers          | $365.00           | 100 × Workers                                          |
| CDN — Cloudflare Enterprise     | $10,000.00        | Flat fee, unmetered bandwidth, ~95% cache hit rate     |
| Database (RDS Aurora)           | $2,400.00         | 1 × db.r6g.4xlarge writer + 3 × db.r6g.2xlarge readers + 2TB I/O Optimized storage |
| EC2 Data Transfer (5% miss)     | $162,003,791.00   | 3.24 PB EC2 egress @ AWS tiers; **~$0 if AWS Bandwidth Alliance applies** |
| **Compute + CDN + DB Subtotal** | **$23,154.17** | Excludes EC2 data transfer (see note below)            |

> **Data Transfer Note:** The EC2 egress line (~$162M/mo) represents the worst-case cost if AWS Bandwidth Alliance does **not** apply. If Cloudflare's Bandwidth Alliance agreement with AWS waives EC2 → Cloudflare egress (which it commonly does), the effective data transfer cost drops to **~$0**, making the total **~$23,154/mo**. At this scale, confirming Bandwidth Alliance eligibility with both AWS and Cloudflare is essential before budgeting.

> 1M users w/ 1% conversion rate where each paying customer pays $10/mo, it will generate $100K/mo of revenue (covers infra cost)<br/>
> At this point, you wouldn't be worried much about burn rate, if you are for some reason, then you should have a dedicated FinOps team to optimize the cost for you.

---

## How Does This Compare to EKS?

**Scenario 0** establishes the control group: an EKS cluster with the same platform capabilities (ArgoCD, Grafana, Prometheus, Karpenter, Traefik, Kyverno, External Secrets) self-installed via Helm, running on 2 × t4g.large worker nodes — the minimum to host all system pods comfortably. That comes to **$198.04/mo** before a single workload pod is deployed.

EKS charges a flat **$73/mo** for the managed control plane regardless of cluster size. Everything else — workers, storage, networking, and all the tooling — is on you. SimpleK3s bundles all of that tooling and automates the bootstrap, so the comparison below reflects the true cost of achieving feature parity, not just raw infrastructure.

### Cost Comparison

| Scenario                            | SimpleK3s   | EKS Equivalent | Difference             |
| :---------------------------------- | :---------- | :------------- | :--------------------- |
| 0 — Control Group                   | N/A         | $198.04/mo     | N/A                    |
| 1 — Baseline                        | $102.56/mo  | $198.04/mo     | SimpleK3s ~48% cheaper |
| 2 — Cost Optimized                  | $71.96/mo   | $198.04/mo     | SimpleK3s ~64% cheaper |
| 3 — Minimal Workload (~1K users)    | $98.68/mo   | ~$225/mo       | SimpleK3s ~56% cheaper |
| 4 — Standard Workload (~2.5K users) | $178.04/mo  | ~$274/mo       | SimpleK3s ~35% cheaper |
| 5 — Full Traction (~1M users)       | ~$23,154/mo | ~$22,933/mo    | Roughly equivalent     |

> EKS equivalents assume the same worker and storage configuration as the corresponding SimpleK3s scenario, replacing the SimpleK3s control-plane EC2 costs with the $73/mo EKS flat fee. Managed add-on costs (CloudWatch Container Insights, managed Karpenter, etc.) are excluded from EKS estimates — including them would widen the gap further in SimpleK3s's favour at lower scenarios.

### When SimpleK3s Wins

- **Scenarios 1–4 (early-to-mid stage startups)** — SimpleK3s runs 35–64% cheaper than an equivalent EKS setup. The savings come primarily from avoiding the $73/mo control plane flat fee and from having all tooling pre-bundled rather than self-installed on top of EKS.
- **Speed to production** — ArgoCD, Grafana, Prometheus, Kyverno, and External Secrets are configured and wired together automatically during cluster bootstrap. On EKS, each requires a separate Helm install, RBAC configuration, and IdP integration.
- **Learning and transition path** — SimpleK3s runs standard Kubernetes, so apps built here migrate to EKS without changes. It is a natural starting point before committing to the operational overhead and cost of a fully managed service.

### When EKS Wins

- **Scenario 5 and beyond** — At 1M+ concurrent users, the $73/mo EKS control plane fee is negligible relative to total infrastructure cost. EKS and SimpleK3s reach cost parity at this scale, and EKS's operational advantages become the deciding factor.
- **Managed upgrades** — EKS handles control-plane version upgrades. SimpleK3s requires manual K3s version management, which becomes increasingly expensive in engineering time as the team and cluster grow.
- **SLA and support** — EKS carries AWS SLA commitments and integrates with AWS Support. SimpleK3s offers zero reliability guarantee (see README Disclaimer).
- **Mission-critical workloads** — If downtime has a direct revenue or legal impact, the operational safety net of a managed service justifies the premium. SimpleK3s is not the right tool for that environment.

---

## Cost Reduction Tips

- **Use spot workers:** Set `capacity_type = "spot"` in `subsystems.karpenter`. Spot instances on the t4g and m6g families typically run 60–70% cheaper than on-demand. Keep control-plane nodes on-demand — a spot interruption on the control plane causes cluster-wide instability.
- **Tune Karpenter consolidation:** A tighter `consolidate_after` (e.g., `"2m"`) reclaims idle nodes faster, reducing wasted spend between workload bursts. The default `"5m"` is conservative — adjust it based on how quickly your workloads ramp up.
- **Right-size the control plane:** `t4g.medium` is the recommended minimum when running system pods. Only upgrade to `t4g.large` or `t4g.xlarge` when you observe consistent CPU or memory pressure — don't over-provision speculatively.
- **Use the Supabase free tier for as long as possible:** At Scenarios 3 and below, the free tier (500 MB, 5 GB egress, 50K MAU) is sufficient. Upgrading to Pro ($25/mo) is only warranted once you approach those limits.
- **Set up CDN before you need it:** Cloudflare's free and Pro tiers handle meaningful traffic with zero bandwidth fees. Getting CDN in place early (Scenarios 3–4) avoids an expensive emergency migration when traffic spikes in Scenario 5.
- **Verify Bandwidth Alliance eligibility early:** At Scenario 5 scale, whether EC2 → Cloudflare egress is waived under the AWS Bandwidth Alliance is worth confirming with both AWS and Cloudflare — the difference is potentially tens of millions of dollars per month.
- **Turn dev/staging clusters off overnight:** For non-production environments with predictable off-hours, `tofu destroy` and `tofu apply` on a schedule eliminates the control plane cost entirely during downtime — Karpenter alone won't help if the control plane stays running.

# Sources:
  - https://dev.to/ocodista/under-pressure-benchmarking-nodejs-on-a-single-core-ec2-5ghe
    - NodeJS achieved 2000 RPS with a 100% success rate with a t2.micro (1vCPU/1GB) with little to no overhead
  - https://pixel506.com/insights/how-much-traffic-can-nodejs-handle
    - ExpressJS can handle ~15K RPS and the basic HTTP module can handle 70K RPS (via a benchmark made by Fastify)
  - https://medium.com/@louisbertson/benchmarking-node-js-frameworks-choose-your-framework-for-2025-4a2fa089dcf3
    - ExpressJS can handle ~3482 RPS
  - https://supabase.com/pricing
    - Pricing model of supabase
  - https://sparecores.com/servers?vendor=aws&columns=75744272&benchmark=eyJpZCI6InN0cmVzc19uZzpiZXN0biIsImNvbmZpZyI6Int9In0=&limit=250&order_by=selected_benchmark_score&order_dir=asc 
    - t2.micro (Benchmark Score: 157 multi core / 157 single core) (burst - micro burst budget)
    - t4g.small (Benchmark Score: 3011 multi core / 1519 single core) (burst - small burst budget)
    - t4g.medium (Benchmark Score: 2867 multi core / 1513 single core) (burst - medium burst budget)
    - t4g.large (Benchmark Score: 3012 multi core / 15017 single core) (burst - large burst budget)
    - m6g.medium (Benchmark Score: 1500 multi core / 1500 single core) (non-burst - consistent performance)
    - c6g.xlarge (Benchmark Score: 6054 multi core / 1520 single core) (non-burst - consistent performance)
