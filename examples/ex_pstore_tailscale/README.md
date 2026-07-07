# ex_pstore_tailscale — Tailscale OAuth → SSM Parameter Store

This root creates a single **SecureString** SSM parameter holding the Tailscale
Kubernetes Operator's OAuth client, in the JSON shape the cluster expects:

```json
{ "client_id": "...", "client_secret": "..." }
```

The cluster's `tailscale` subsystem reads it via External-Secrets and materializes
the `operator-oauth` Kubernetes secret. Deploy this **before** the cluster whenever
any app uses `exposure = "internal"`.

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

### 3. Use OAuth Keys 

1. Make sure that the right `Client ID` and `Client secret` is inside `terraform.tfvars`
2. Perform a Terraform/Tofu init and apply onto the TF config
3. Copy the `ssm_param_name` output into `subsystems.tailscale.pstore_oauth` in
   `examples/ex_basic/main.tf`

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
