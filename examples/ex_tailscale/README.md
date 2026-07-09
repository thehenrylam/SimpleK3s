# ex_tailscale — Tailscale lifecycle root

This is the **durable** root that owns everything tailnet-related for a SimpleK3s
deployment, kept separate from the cluster (`examples/ex_basic/`) so it survives
cluster teardowns — the same way `examples/ex_idp/` owns the IdP. It manages:

1. The Tailscale Kubernetes Operator's **OAuth client**, as a single
   **SecureString** SSM parameter in the JSON shape the cluster expects:
   ```json
   { "client_id": "...", "client_secret": "..." }
   ```
   The cluster's `tailscale` subsystem reads it via External-Secrets and
   materializes the `operator-oauth` Kubernetes secret.
2. The tailnet **MagicDNS name**, as an SSM parameter consumed by `ex_basic`.
3. A **read-only OAuth client** (separate from the operator one) for the read-only
   Lambdas below — see [Read-only OAuth client](#2b-setup-the-read-only-oauth-client).
4. Three **Lambdas** that manage the tailnet lifecycle around a cluster:
   - `lambda_cleanup.tf` — deletes the cluster's devices on `tofu destroy`
     ([Device cleanup](#device-cleanup-on-cluster-destroy)). Uses the **operator**
     (write) client.
   - `lambda_list.tf` — lists the managed devices (read-only, ad-hoc debugging).
   - `lambda_preflight.tf` — validates the tailnet (tags + MagicDNS) before a
     deploy; `ex_basic` invokes it and **blocks the apply** on a real misconfig.
   The list + preflight Lambdas use the **read-only** client, so their tokens
   cannot mutate anything.

Deploy this **before** the cluster whenever any app uses `exposure = "internal"`.

## ⚠️ Demonstration only — read this first

SimpleK3s deliberately **does not pass credentials through Terraform**. This example
breaks that principle for convenience. The consequences:

- Your secret is written to **`terraform.tfvars`** (plaintext on disk).
- Your secret is written to **Terraform state** (plaintext). State is the real
  exposure: anyone who can read the state file can read the secret, regardless of
  the `sensitive = true` markings (those only hide it from CLI output).

The repo `.gitignore` already excludes `*.tfvars` and `*.tfstate*`, so you won't
*commit* them — but they still exist unencrypted wherever you run this. Treat this
root as a learning aid, not a production secret pipeline.

## How to set up

### 0. Pre-requisites

1. Set up a Tailscale account (https://tailscale.com)
2. Download and set up the Tailscale client (https://tailscale.com/download)

### 1. Setup Tags

__Relevant Docs:__ https://tailscale.com/docs/kubernetes-operator/install-operator

1. Log into tailscale and reach the admin console (https://login.tailscale.com/admin)
2. Go to `Access Controls` > `Tags` (https://login.tailscale.com/admin/acls/visual/tags)
3. Create the `k8s-operator` tag: (Gives us a path into the app and assigns sub-tags to the pods)
   1. Click on `Create tag`
   2. In `Tag Name`, write `k8s-operator`
   3. In `Tag Owner`, write your email (your-username@email.com) to allow yourself access
4. Create the `k8s` tag: (Gives us the tag to have the nodes be assigned to)
   1. Click on `Create tag`
   2. In `Tag Name`, write `k8s`
   3. In `Tag Owner`, write `k8s-operator`
5. You should now have 2 tags: `k8s-operator` and `k8s`. Use `k8s` for SimpleK3s' settings

### 2. Setup OAuth Keys

__Relevant Docs:__ https://tailscale.com/docs/kubernetes-operator/install-operator#configure-tags-and-oauth-credentials

1. Log into tailscale and reach the admin console (https://login.tailscale.com/admin)
2. Go to `Settings` > `Trust credentials` > `+ Credential` (https://login.tailscale.com/admin/settings/trust-credentials)
3. Click on `OAuth`, and click on `Continue`
4. Put in Read + Write for the following scopes: (Leave everything else at NO priviledges)
   1. Genera / Services (tags: `tag:k8s-operator`)
   2. Devices / Core (tags: `tag:k8s-operator`)
   3. Keys / Auth Keys (tags: `tag:k8s-operator`)
5. Click on `Generate credential` 
6. Copy the `Client ID` and `Client secret` into `terraform.tfvars` (a copy from `terraform.TEMPLATE.tfvars`)

### 2b. Setup the read-only OAuth client

The `list` and `preflight` Lambdas use a **separate, read-only** OAuth client so
their tokens can only read — never delete. Create a **second** OAuth credential:

1. Go to `Settings` > `Trust credentials` > `+ Credential` again, choose `OAuth`.
2. Put in **Read** (only) for the following scopes (leave everything else at NO privileges):
   1. Devices / Core — **Read** (for `list` and preflight tag lookup)
   2. Policy File — **Read** (for preflight `tags`: reads the ACL to confirm `tag:k8s` / `tag:k8s-operator` are defined)
   3. DNS — **Read** (for preflight `dns`: reads the MagicDNS preference)
3. Generate, and copy the `Client ID` / `Client secret` into the
   `tailscale_readonly_oauth_client_id` / `..._secret` values in `terraform.tfvars`.

> Without this client the `list`/`preflight` Lambdas can't authenticate; and
> without the Policy File / DNS read scopes the preflight checks will 403.

### 3. Use OAuth Keys 

1. Make sure that the right `Client ID` and `Client secret` is inside `terraform.tfvars`
2. Perform a Terraform/Tofu init and apply onto the TF config
3. Copy the `ssm_param_name` output into `subsystems.tailscale.pstore_oauth` in
   `examples/ex_basic/main.tf`

## Device cleanup on cluster destroy

When a SimpleK3s cluster is destroyed (`tofu destroy` on `examples/ex_basic/`),
the EC2 nodes — and the Kubernetes API with them — are torn down abruptly, so the
Tailscale operator never gets to deregister its devices. The cluster's two tailnet
devices (`<nickname>` proxy + `<nickname>-operator`) are left **offline**, and the
next cluster of the same nickname collides into `<nickname>-1` /
`<nickname>-operator-1` — which breaks the OIDC callbacks pinned to the clean host.

This root ships a Lambda (`lambda_cleanup.tf`, handler `data/cleanup_devices.py`)
that fixes that automatically:

- **Where it lives / how it fires.** The function lives here (durable root) so it
  always exists when invoked. `examples/ex_basic/` holds a small
  `aws_lambda_invocation` (`lifecycle_scope = "CRUD"`) tied to the *cluster's*
  lifecycle. The handler **no-ops on create/update** and only deletes devices on
  the destroy action — so cleanup is **destroy-only**.
- **What it deletes.** Only devices whose short name is `<nickname>` or
  `<nickname>-*` **and** that carry `tag:k8s` / `tag:k8s-operator`. Unrelated
  devices that merely share the name prefix are never touched.
- **How it authenticates.** It reads the same `oauth_config` SSM parameter and
  exchanges it for a Tailscale API token — no new credential, nothing in TF state.
- **Cost vs. observability knobs.** Two optional variables tune logging/tracing
  for **all three** Lambdas: `lambda_log_retention_days` (default `180`;
  CloudWatch-valid values only — 7, 14, …, 180, 365, …) and
  `lambda_enable_xray_tracing` (default `false`). Minimal cost: `7` + `false`.
  Full audit: `365` + `true`.

> **OAuth scope requirement:** deleting devices needs the operator OAuth client to
> have **Devices / Core → Write**. The setup in [step 2](#2-setup-oauth-keys)
> already grants this, so no extra action is needed. If you scoped your client more
> narrowly, add Devices/Core write or the cleanup calls will 403.

## List & preflight Lambdas

Two read-only Lambdas round out the tailnet lifecycle. Both use the
[read-only OAuth client](#2b-setup-the-read-only-oauth-client) — their tokens
literally cannot delete anything.

- **`list` (`lambda_list.tf`)** — lists the devices carrying the managed tags
  (`tag:k8s` / `tag:k8s-operator`), optionally narrowed to a hostname prefix.
  Invoke it ad-hoc for debugging (e.g. when hunting the `-1` collisions):
  ```bash
  aws lambda invoke --function-name tailscale-list-<nickname> \
    --payload '{}' /dev/stdout
  # narrow to one cluster: --payload '{"hostname_prefix":"simplek3s"}'
  ```

- **`preflight` (`lambda_preflight.tf`)** — validates the tailnet before a deploy.
  Dispatches on the `check` field:
  - `{"check":"tags"}` — the ACL defines owners for `tag:k8s` and `tag:k8s-operator`
    (without them the operator can't register).
  - `{"check":"dns"}` — MagicDNS is enabled (required for the tailnet host + HTTPS
    certificates).

  `examples/ex_basic/` invokes it at plan time (`data.aws_lambda_invocation`) and a
  `precondition` **blocks the apply** if a check returns `ok=false` — turning the
  tag-setup and MagicDNS gotchas into a fast, clear error instead of a failed
  ~20-minute cluster build. The Lambda **fails open** on Tailscale API errors
  (returns `ok=true`), so a transient API hiccup can't wedge an otherwise-fine apply.

**Limitation (destroy-only):** cleanup runs only on a *clean* `tofu destroy`. If a
teardown is skipped, fails midway, or the stack is deleted out-of-band (e.g. via
the AWS console), the stale devices still linger and you'll need to remove them
manually in the admin console.

## Doing this more securely (production)

The goal is to keep the secret out of Terraform state and off developer laptops.
In rough order of impact:

1. **Don't use Terraform for the secret at all.** Create the SecureString
   out-of-band from a hardened, access-controlled host:
   ```bash
   aws ssm put-parameter \
     --name "/tailscale-standalone/<nickname>/oauth_config" \
     --type SecureString --key-id <your-cmk> \
     --value '{"client_id":"...","client_secret":"..."}'
   ```
   The cluster reads it identically; no secret ever enters TF state.
2. **Centralize secret creation on an admin-only server / CI runner.** Run the
   `put-parameter` step (or this root, if you must) only from a controlled,
   audited environment — a bastion or a CI pipeline whose IAM role is the *only*
   principal allowed to write under `/tailscale-standalone/*`. Admins request
   changes through that pipeline rather than holding the credentials locally.
   Pair it with CloudTrail data events on Parameter Store/KMS for an audit trail.
3. **Use a customer-managed KMS key** with a tight key policy instead of the
   default `aws/ssm` key, so decrypt is scoped to the cluster role and the
   creation pipeline only.
4. **If you keep Terraform, use an encrypted remote backend** (S3 + SSE-KMS +
   DynamoDB lock) with restricted read access — never local state for secrets.
5. **Rotate and scope minimally.** Give the OAuth client only the tags/scopes it
   needs, and rotate it on a schedule; tagged operator devices don't expire, so
   rotation is about credential hygiene, not uptime.
6. **Consider eliminating the long-lived secret** by minting the OAuth client via
   the Tailscale API inside the controlled job, so the credential is generated and
   consumed in one place rather than copy-pasted.
