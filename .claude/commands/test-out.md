# test-out

Run one or more test scripts from the `testcases/` directory and report results.

## Steps

### 1. Determine Which Tests to Run

The available test scripts are:
- `testcases/test-out_shellscripts.sh` — shellcheck on all `.sh` files
- `testcases/test-out_terraform.sh` — fmt, tflint, checkov, validate (defaults to `tofu`; pass `--use-terraform` to run under Terraform, `--help` for options)
- `testcases/test-out_python.sh` — ruff check + `ruff format --check` on all `*.py`
- `testcases/test-out_simplek3s.sh` — **live** end-to-end health check of an already-deployed cluster (see the special handling in step 3)

Use the args and conversation context to decide which tests to run:

- **No args / no context**: include all *static* test scripts (`shellscripts`, `terraform`, `python`). Do **not** auto-include `test-out_simplek3s.sh` — it is a live-cluster probe with preconditions; only include it when the user explicitly asks or supplies its args.
- **"relevant" or "related" in the prompt**: look back at the conversation to identify which files, tools, or areas were most recently discussed or modified, then select the test scripts most relevant to that work.
- **Explicit additions or removals in the prompt** (e.g. "skip terraform", "only shellcheck", "add X"): apply those adjustments to the list.

Only fall back to running raw commands directly if no test script covers the requested check.

### 2. Propose the Execution Plan

Present the proposed test list to the user as a numbered, ordered list. For example:

```
Here's what I'm planning to run:

1. testcases/test-out_shellscripts.sh
2. testcases/test-out_terraform.sh

Proceed? (yes to run, or tell me what to change)
```

- A yes-type answer ("yes", "go", "lgtm", "looks good", "sure") → proceed to step 3.
- Any other answer (e.g. "remove #2", "why is that included?", "add X first") → open a dialogue, adjust the list, and re-propose before proceeding.

### 3. Execute the Tests

1. Determine and save the log filename of the test.
  - Default: `test-out`, but modify the filename if the user directs you to
  - In the document, we will refer to this as `LOG_FILENAME`

2. Determine and save the timestamp of the test.
  - Run `date +'%Y%m%d-%H%M%S'` as a **separate Bash command** and capture the output as `LOG_TIMESTAMP`.
  - In the document, we will refer to this as `LOG_TIMESTAMP`

3. For each item in the list of tests:
  - `test-out_simplek3s.sh` is a **special case** — it takes `<region> <profile> <nickname>` as required positional args (not the log convention) and uses flags for logging. Execute it like this:
    - `./testcases/test-out_simplek3s.sh <region> <profile> <nickname> --log-name "${LOG_FILENAME}" --log-timestamp "${LOG_TIMESTAMP}"`
    - **Inferring args**: unless the user supplies them explicitly, infer all three by reading `examples/standard_deployment/group_vars/all.yml`:
      - `region` ← `aws_region`
      - `nickname` ← `tfvars.cluster.nickname`
      - `profile` ← `aws_profile`

      Always **show all three inferred values to the user to confirm** before running — they name the cluster the probe will hit, and an operator with more than one deployment needs to see which one was picked.
    - `all.yml` is gitignored (only `all.TEMPLATE.yml` is tracked), so on a fresh clone it will not exist. When it is missing, or a value is absent, or it still holds `__CONFIGURE_THIS__` placeholders, ask the user for the missing args rather than guessing.
    - Its preconditions: a **deployed** cluster + valid AWS creds/profile. If the args can't be resolved, or no cluster is deployed, skip it and note the skip in the report rather than failing the whole run.
  - Otherwise, if its a `test-out_<specifier>.sh` script:
    - Execute it like this: `./testcases/test-out_<specifier>.sh "${LOG_FILENAME}" "${LOG_TIMESTAMP}"`
  - If its a command:
    - Execute it like this: `<command> | tee -a "./testcases/${LOG_FILENAME}-${LOG_TIMESTAMP}.log"`

After all of the tests are done, the log file should be able to be found here:
- `./testcases/${LOG_FILENAME}-${LOG_TIMESTAMP}.log`

Based on the output, report on the results (details below)

### 4. Report Results

After all scripts have run, report a summary using emojis:
- 🟢 passed
- 🟥 failed

Format:

```
Results logged to: `./testcases/${LOG_FILENAME}-${LOG_TIMESTAMP}.log`

🟢 test-out_shellscripts.sh
🟥 test-out_terraform.sh
  - <2-sentence summary of what failed and why>

X/Y tests passed.
```

For failed scripts/commands, include the 2-sentence summary as a nested bullet directly beneath the script line. Keep it to 2 sentences max — focus on what failed and the likely cause, do not reproduce the full log output. Passed scripts have no nested bullet.

Close with: *"Ask me anything about the test run, or I can show you the relevant section of the log."*

## Notes

- Always use scripts from `testcases/` when they exist. Only run raw commands if no script covers the check.
- Never run destructive commands (e.g. `tofu apply`, `tofu destroy`) as part of a testcase.
- Log files accumulate in `testcases/` — do not delete them unless the user asks.
