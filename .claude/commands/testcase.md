# testcase

Run one or more testcase scripts from the `testcases/` directory and report results.

## Steps

### 1. Determine Which Tests to Run

The available testcase scripts are:
- `testcases/test_check_all_shellscripts.sh` — shellcheck on all `.sh` files
- `testcases/test_check_all_terraform.sh` — tofu fmt, tflint, checkov, tofu validate

Use the args and conversation context to decide which tests to run:

- **No args / no context**: include all testcase scripts.
- **"relevant" or "related" in the prompt**: look back at the conversation to identify which files, tools, or areas were most recently discussed or modified, then select the testcase scripts most relevant to that work.
- **Explicit additions or removals in the prompt** (e.g. "skip terraform", "only shellcheck", "add X"): apply those adjustments to the list.

Only fall back to running raw commands directly if no testcase script covers the requested check.

### 2. Propose the Execution Plan

Present the proposed test list to the user as a numbered, ordered list. For example:

```
Here's what I'm planning to run:

1. testcases/test_check_all_shellscripts.sh
2. testcases/test_check_all_terraform.sh

Proceed? (yes to run, or tell me what to change)
```

- A yes-type answer ("yes", "go", "lgtm", "looks good", "sure") → proceed to step 3.
- Any other answer (e.g. "remove #2", "why is that included?", "add X first") → open a dialogue, adjust the list, and re-propose before proceeding.

### 3. Execute the Tests

Generate a log filename using the current timestamp:

```
testcases/testcase_YYYYMMDD-HHMMSS_NNN.log
```

Where `NNN` is milliseconds (use `date +%Y%m%d-%H%M%S_%3N` to generate).

Run each script in the agreed order, redirecting both stdout and stderr to the log file:

```bash
bash <script> >> <logfile> 2>&1
```

Capture the exit code of each script individually to determine pass/fail. Do not stop on first failure — run all scripts and collect all results.

### 4. Report Results

After all scripts have run, report a summary using emojis:
- 🟢 passed
- 🟥 failed

Format:

```
Results logged to: testcases/testcase_YYYYMMDD-HHMMSS_NNN.log

🟢 test_check_all_shellscripts.sh
🟥 test_check_all_terraform.sh
  - <2-sentence summary of what failed and why>

X/Y tests passed.
```

For failed scripts/commands, include the 2-sentence summary as a nested bullet directly beneath the script line. Keep it to 2 sentences max — focus on what failed and the likely cause, do not reproduce the full log output. Passed scripts have no nested bullet.

Close with: *"Ask me anything about the test run, or I can show you the relevant section of the log."*

## Notes

- Always use scripts from `testcases/` when they exist. Only run raw commands if no script covers the check.
- Never run destructive commands (e.g. `tofu apply`, `tofu destroy`) as part of a testcase.
- Log files accumulate in `testcases/` — do not delete them unless the user asks.
