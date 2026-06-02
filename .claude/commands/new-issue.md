# new-issue

Create a GitHub issue following CONTRIBUTING.md conventions, then check out a new branch for the work.

## Steps

### 1. Gather Issue Details

Ask the user (or infer from their args) the following. Collect all answers before moving on — you can ask them in one go:

- **Title**: Short, descriptive title for the issue
- **Type**: One of `document`, `feature`, `bugfix`, `refactor`, `chore`, `sandbox`
- **Related Files**: File paths likely to change (or `currently unknown`)
- **Description**: What the issue is (symptoms of a bug, what needs documenting, etc.)
- **Additional Notes**: Suggested approach, quirks, anything else useful (optional — can be left blank)
- **Acceptance Criteria**: Bulleted list of conditions that define "done"

If the user already provided some of this information in their `/new-issue` command args, use it and only ask for what's missing.

### 2. Draft and Preview the Issue

Compose the issue using this exact template from CONTRIBUTING.md:

```
## Related Files:
- `<related files>`

## Description:
<description>

## Additional Notes:
<notes>

## Acceptance Criteria:
- <criterion 1>
- <criterion 2>
```

Show the user:
- **Proposed title**: the issue title they gave
- **Proposed labels**: derive a label from the type using the repo's actual labels:
  - `bugfix` → `bug`
  - `feature` → `feature`
  - `document` → `documentation`
  - `refactor` → `refactor`
  - `sandbox` → `sandbox`
  - `chore` → leave unlabeled unless the user says otherwise
- **Proposed body**: the filled-in template above

Then ask: *"Does this look good, or would you like to change anything?"*

Revise until the user approves. Accept short confirmations like "yes", "looks good", "lgtm", "go ahead".

### 3. Create the GitHub Issue

Once approved, run:

```
gh issue create \
  --title "<title>" \
  --body "<body>" \
  [--label "<label>" if applicable]
```

Capture the issue URL that `gh` prints. Extract the issue number from it (the integer after the last `/`). Show it to the user: *"Issue #NNN created: <url>"*

### 4. Create the Branch

Propose a branch name following the Branch Guide:

```
TYPE/#ISSUE_ID_BRANCH_NAME
```

Where `BRANCH_NAME` is a short snake_case summary of the work (e.g. `fix_cluster_startup`, `add_monitoring_docs`).

Show the proposed branch name and ask the user to confirm or adjust it.

Once confirmed, run:

```
git checkout -b "TYPE/#ISSUE_ID_BRANCH_NAME"
```

Confirm to the user that the branch was created and they are now on it.

## Notes

- Use the `gh` CLI for all GitHub operations — do not open browser URLs.
- The issue number is not known until step 3; do not guess it before then.
- If the user passes args to `/new-issue` (e.g. `/new-issue bugfix: K3s fails to start on arm64`), parse them as pre-filled answers so the conversation starts further along.
- Stay concise: show one clear preview, not multiple draft iterations before asking for feedback.
