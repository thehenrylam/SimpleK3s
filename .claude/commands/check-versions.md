# check-versions

Scan the repository for all software version references, then compare against the Pinned Versions table in `CLAUDE.md` and report on status.

## Steps

### 1. Extract the CLAUDE.md Pinned Versions table

Read `CLAUDE.md` and parse the Pinned Versions table. For each row, record:
- **Dependency name** (e.g. `K3s`, `SSM Agent`, `tflint`)
- **Expected version** (e.g. `v1.35.1+k3s1`, `3.3.4515.0`)
- **Defined In** file(s)

This is the baseline. Everything found in the scan will be checked against it.

### 2. Scan the codebase for version references

Search the following locations and patterns. For each finding record the dependency name, version string (or "unpinned"), and file + line number.

**Terraform variable defaults** (`k3s_cluster/variables.tf`):
- Lines matching `default = "..."` near version-related variable names

**Subsystem/app default_settings** (`k3s_cluster/cluster_app/*/main.tf`):
- `version = "..."` inside `default_settings` blocks
- `ssm_agent_version = "..."` inside `default_settings` blocks

**Toolchain version variables** (`toolchain/tc_testing_macos_install.sh`, `toolchain/tc_testing_macos_check.sh`, `toolchain/tc_testing_macos_uninstall.sh`):
- Lines matching `*_VERSION="..."` variable assignments at the top of the file

**CI workflow** (`.github/workflows/static-analysis.yml`):
- Lines under `env:` matching `*_VERSION: "..."`
- `tflint_version:` action input
- `tofu_version:` action input
- `python-version:` action input
- `pip install ...` or `apt-get install ...` without a version pin (flag as unpinned)

**Cloud-init template** (`k3s_cluster/cloudinit.sh.tftpl`):
- Any `curl` or install commands using `latest` in a URL (flag as unpinned)

**Bootstrap and other shell scripts** (`k3s_cluster/cluster_app/bootstrap/*.sh`, `toolchain/*.sh`):
- Any `curl`/`wget`/`apt-get install`/`brew install` commands referencing `latest` or with no version (flag as unpinned)

### 3. Classify each finding

For every version found in the scan, assign one of these statuses:

| Status | Meaning |
|---|---|
| ✅ Pinned & tracked | Version is pinned in code AND matches the CLAUDE.md table |
| ⚠️ Drifted | Version is pinned in code BUT differs from the CLAUDE.md table |
| 🔵 Pinned, untracked | Version is pinned in code but NOT present in the CLAUDE.md table |
| 🔴 Unpinned | Version reference is floating (`latest`, `*`, no version specified) |

Also check the inverse: flag any dependency listed in the CLAUDE.md table whose version cannot be found anywhere in the codebase scan (it may have been removed or the file moved).

### 4. Report results

Output the report in this format:

```
## Version Check Report

### ✅ Pinned & Tracked
| Dependency | Version | File |
|---|---|---|
| ...        | ...     | ...  |

### ⚠️ Drifted (code ≠ CLAUDE.md)
| Dependency | Code Version | CLAUDE.md Version | File |
|---|---|---|---|
| ...        | ...          | ...               | ...  |

### 🔵 Pinned but Untracked (not in CLAUDE.md)
| Dependency | Version | File |
|---|---|---|
| ...        | ...     | ...  |

### 🔴 Unpinned (floating references)
| Dependency | File | Line |
|---|---|---|
| ...        | ...  | ...  |

### ❓ In CLAUDE.md but not found in codebase
| Dependency | Expected Version | Expected File |
|---|---|---|
| ...        | ...              | ...           |
```

Omit any section that has no rows.

Close with a one-sentence summary: total findings by status (e.g. "8 pinned & tracked, 0 drifted, 1 untracked, 2 unpinned.") and a recommendation if any action is needed.

## Notes

- Do not modify any files. This command is read-only — it reports, it does not fix.
- The CLAUDE.md Pinned Versions table is the source of truth for what *should* be tracked. Anything in the codebase not in that table is untracked, not necessarily wrong.
- Terraform provider `version` constraints using `~>` or `>=` are range constraints by design — do not flag these as unpinned.
- Helm chart YAML template files that use `${version}` template variables are not unpinned — their value comes from the Terraform `default_settings`. Do not flag these.
- The Debian AMI name pattern (`debian-13-arm64-*`) is intentionally dynamic — do not flag it.
- When a dependency appears in multiple files (e.g. `ssm_agent_version` in both `variables.tf` and `karpenter/main.tf`), check that all occurrences agree. If they differ, flag the discrepancy under ⚠️ Drifted.
