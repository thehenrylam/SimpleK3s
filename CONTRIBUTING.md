# Contributing to SimpleK3s 
Contributions to SimpleK3s are greatly welcomed and we want to set everyone up for success to allow for them
This document will outline all the relevant info for beginners to join in and work on it

## Most common types of changes
These are the most common changes that we want to focus on for now (No set priority)
- Bug fixes
- Reliability and robustness
- Ease of use
- Enterprise features
- Cost optimization
- Documentation

## Questions?
Its recommended for everyone to try to read the *.md files on the repo first and foremost (**and comments within the files if applicable**).
But if it isn't clear enough, please open an Issue with the [help wanted](https://github.com/thehenrylam/SimpleK3s/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22help%20wanted%22) tag 

## Code of Conduct
1. Set everyone up for success 
    - Contributors: Make it easier for the people around you to work with your code +6 months after you made it
    - Maintainers: The easier you make it for us to merge (good info, clean code, good docs), the easier we can put your change onto the repo
2. No spamming (PRs, commits, issues, etc)
    - Don't spam GitHub's functions on this repo, we'll try to work with you in good faith and kindly ask you to slow down
    - We'll have no choice to turn you away if our warnings are ignored
3. Read documentation to improve it
    - Not only is reading documentation important to save yourself time and headache, it also helps make documentation better!
        - The more you read, the more likely you'll spot confusing documentation, which you can raise a GitHub issue to fix it!
        - **Remember, improving documentation and making sure that it stays up-to-date is just as important as a feature/bugfix! (because end-users will likely read it as well!)**
4. Sloppy work is frowned upon
    - Make sure that documentation is well written and properly describes the behavior
    - Bad formatting, disorganized modules, exceedingly inelegant solutions is something we do not want, as its will create more work for contributors and maintainers
    - Do your best to keep commits as clean as possible 
        - We completely understand the 'please work' commits taken at 3am, and we greatly appreciate that you try squashing your commits together to help commits cleaner
5. Remember the goal
    - Make it as "plug n' play" as possible (Less required config == better)
    - Keep it organized and elegant (Approachability to tinker as a beginner is good)
    - Cost conscious (Avoid managed services like EKS, as its unsustainable to run without having dedicated cashflow)

## Requirements
Check the [Requirements](https://github.com/thehenrylam/SimpleK3s?tab=readme-ov-file#requirements) section of the README.md
Tip:
- You can copy the `.git/` hooks to help make sure your commits are of the right format by executing `./.git-custom/apply.sh` 
    - You can check inside the `.git-custom/` to make sure you understand what its doing with your `.git/` folder before you apply the customizations

## Example: How to make a change (step-by-step guide)
ASSUMPTION: You want to fix a bug that causes a failure on cluster startup

1. Go to the [Issues](https://github.com/thehenrylam/SimpleK3s/issues) section
    - Try to adjust the labels setting to filter out labels you don't need and only the labels that help describe the bug
2. Attempt to determine the `Issue Ticket` that you'll be working on  
    - If there is a pre-existing issue ticket...
        - It is actively being worked on, ask the contributor if they need any help on it. Otherwise, its recommended to try working on something else
        - It is not actively being worked on (+14 days inactivity), you can try to assign yourself to that ticket to work on it.
    - If there is not a pre-existing issue ticket, create it!
        - Use this [TEMPLATE](https://github.com/thehenrylam/SimpleK3s?tab=contributing-ov-file#template-for-issues) for your tickets
3. Once the `Issue Ticket` has been determined, get its `Issue Id`, which will be used later (Can be found next to the `#` character)
    - For this example, let's assume that `Issue Id` == `#4092`
4. Go to the terminal and open a branch ([Branch Guide](https://github.com/thehenrylam/SimpleK3s?tab=contributing-ov-file#branch-guide))
    - `git checkout -b "bugfix/#4092_fix_cluster_startup"`
5. Make commits for the fix ([Commit Guide](https://github.com/thehenrylam/SimpleK3s?tab=contributing-ov-file#commit-guide))
    - `git -m "bug#4092 - Modify bootstrap script to wait for a service to start before the changes are made"`
    - Good to know: `git commit --amend` to modify your last commit message
6. Test to see if the changes are valid
    - Follow the README.md for the recommended commands, but you should at least try to do a `tofu plan` (or Terraform equivalent)
    - Make sure that you statisfy the `Acceptance Criteria` when you are checking (found within the `Issue Ticket`)
    - Its good to document what you are doing and issues you're facing for others to learn and can help you out easier
6. Push the commits for the fix 
    - `git push --set-upstream origin bugfix/#4092_fix_cluster_startup`
7. Issue a PR ([PR Guide](https://github.com/thehenrylam/SimpleK3s?tab=contributing-ov-file#pr-guide))
    - At the top of the GitHub banner, click on `Pull Requests`
    - Click on the `compare` dropdown, and select the branch you're working on
    - Click on `Create pull request`
    - It will be merged so long as the code resolves the issue, and guidelines within the [PR Guide](https://github.com/thehenrylam/SimpleK3s?tab=contributing-ov-file#pr-guide) are met

**Don't know what issue to open or take, but still want to make changes?**
- Try opening a GitHub issue with the `sandbox` label (Use `sandbox` for both branch and commit)
- This allows anybody to freely experiment whatever you'd like (make commits, pull changes, etc) without fear of messing something up
- Pro Tips:
    1. You can use `sandbox` to try out a task first before commiting to a real ticket (e.g. `refactor`, `document`, `feature`)
    2. If you can help pitch an idea that would cause massive changes to the repo by using `sandbox` to showcase it for contributors and maintainers to see
    3. PRs with `sandbox` in the branch/commit will be rejected (**because its sole purpose is to test, nothing more**) 

## PR Guide
This is meant to be a series of guidelines to help get your PR merged.
The rules are kept short and easy to follow, failure to follow will likely lead to the PR being rejected

```
Breakdown: (Title)
    BRANCH_TYPE#ISSUE_ID PR_TITLE

Example: (Assume 'bugfix' type and issue id is '#12345')
    bugfix#12345 Fix a bug

See the BRANCH_TYPE via the Branch Guide
```

**Keep your PRs:**
1. Explainable: 
    - You must explain what you did with your code using your own words (No AI)
    - Its so to make sure that you can show that you understand the underlying behavior
2. Focused:
    - Do your best to keep requested changes focused (Small change + few file changes)
    - Of course there are exceptions (like refactoring), but you'll need to be able to explain why
3. Tested:
    - Be sure to test before you issue out the PR
    - Include the testcase to reproduce the issue on the `main` branch and before/after images of the change
    - We will be sure to test before we merge to perform due diligence
        - If we don't get the same result as the change, we will do our best to work with you to try what may be the difference between our tests

## Branch Guide
```
Breakdown:
    BRANCH_TYPE#ISSUE_ID_BRANCH_NAME

Example: (Assume 'bugfix' type and issue id is '#12345')
    bugfix#12345_fix_a_bug

Command:
    git checkout -b "bugfix#12345_fix_a_bug"
```

**Branch Types**
- `document`    : Documentation
- `feature`     : Feature
- `bugfix`      : Bug Fix
- `refactor`    : Refactorization
- `chore`       : Misc (Dependency updates, etc)
- `sandbox`     : Test branch to freely experiment (Not allowed for PRs)

## Commit Guide
```
Breakdown:
    COMMIT_TYPE#ISSUE_ID - COMMIT_MESSAGE

Example: (Assume 'bug' type and issue id is '#12345')
    bug#12345 - This is a commit to resolve a bug

Command:
    git commit -m "bug#12345 - This is a commit to resolve a bug"
```

**Commit Types:**
- `document`    : Documentation
- `feature`     : Feature
- `bugfix`      : Bug Fix
- `refactor`    : Refactorization
- `chore`       : Misc (Dependency updates, etc)
- `sandbox`     : Test commits for `sandbox` branch types (Not allowed for other branches)

## Template for Issues
```
## Related Files:
- `file/paths/that/you/will/likely/change.txt` 
👆 You can put down 'currently unknown` (you can go back later to change it)
    This is just to signal the expected scope of changes
    Very useful for contributors to understand what it would change to resolve the issue 
        - Great way to get up-to-speed when revisiting the issue
        - Newcomers can better make connections between a feature to a set of folders/files
        - Fantastic material to set others up for success when assigning it to others

## Description:
Description of the issue (need to document xyz, description of the bug's symptoms, etc)

## Additional Notes:
Notes to help yourself and others (A suggested approach to fix, quirks that needs to be kept in mind, etc)

## Acceptance Criteria:
- Conditions to meet to be considered done
- Try to include instructions/commands to make it easier to reproduce and check among contributors
    - Describe the OKAY / FAILURE result
- For non-technical such as refactoring/documentation, describe what needs to be done and added
👆 For changes that fixes/changes functionality, its recommended to take a before/after screenshot to confirm that it looks OK
```
