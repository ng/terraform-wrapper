# PR Review — Adversarial Review & Fix Workflow

Review and fix PR $ARGUMENTS (number or URL). If no argument given, review the current branch's open PR.

## Phase 1: Gather Context

1. **Fetch PR context** using `gh`:
   - Get the PR diff: `gh pr diff $PR`
   - Get PR details: `gh pr view $PR`
   - Check CI status: `gh pr checks $PR`

2. **Pull all existing review feedback**:
   - Get review comments: `gh api repos/{owner}/{repo}/pulls/{number}/comments`
   - Get PR review summaries: `gh api repos/{owner}/{repo}/pulls/{number}/reviews`
   - Get conversation threads: `gh pr view $PR --comments`
   - Identify unresolved vs resolved comments

3. **Read all changed files** in full to understand the current state.

## Phase 2: Address GitHub Feedback

4. **Categorize GitHub feedback** into:
   - Actionable fixes (bugs, style, logic issues)
   - Questions needing response
   - Already addressed / outdated comments

5. **Apply fixes** for all actionable GitHub feedback. For each fix:
   - Reference the original comment
   - Explain what was changed and why

6. **Present a summary** of what was addressed and what was skipped (with reasoning).

## Phase 3: Adversarial Agent Review

**Important**: Neither agent auto-fixes code. Both produce reports only. The main context synthesizes and applies fixes after both agents complete.

Store the current branch name in `[branch]` for use in temp file paths.

### Pass 1 — The Optimizer (findings report)

Runs first in a worktree. Reviews code and writes a structured findings report — does NOT modify any source files.

```
Agent({
  subagent_type: "general-purpose",
  isolation: "worktree",
  mode: "bypassPermissions",
  run_in_background: true,
  prompt: `You are "The Optimizer" — the first pass in an adversarial code review of branch [branch] (PR #[number]).

  YOUR ROLE: Find every issue worth fixing. Be thorough and constructive.
  CONSTRAINT: Do NOT modify any source files. Write your findings to a report file only.

  1. Read ALL changed files: git diff origin/main...HEAD
  2. Read CLAUDE.md for project conventions
  3. Review against these lenses:
     - Shell scripting safety: quoting, word splitting, glob expansion, uninitialized variables
     - Security: command injection vectors, eval usage, credential handling, input validation
     - Error handling: set -euo pipefail compliance, proper exit codes, error messages
     - Portability: bash-specific features flagged, macOS vs Linux differences (sed, readlink, etc.)
     - Config/secret parsing: edge cases in .tf.conf and .env parsing (special chars, empty values, malformed lines)
     - Terraform integration: workspace handling, init flags, backend config, var-file ordering
     - UX: help text, error messages, output clarity

  4. Run shellcheck on any modified .sh or bash scripts and include findings.

  5. Write your findings to /tmp/code-review-optimizer-[branch].md in this exact format:

     # Optimizer Findings — [branch]

     ## Summary
     Brief description of what this branch does and overall code quality assessment.

     ## Findings

     ### Finding 1: [title]
     - **File**: [path]:[line number]
     - **Severity**: 🔴 Critical | 🟡 Major | 🟢 Minor | ⚪ Nit
     - **Category**: [Security | Shell Safety | Error Handling | Portability | Config Parsing | Terraform | UX]
     - **Problem**: [what is wrong]
     - **Suggested fix**: [concrete code change or approach]
     - **Rationale**: [why this matters]

     ### Finding 2: [title]
     ...

     ## Statistics
     - Total findings: [count]
     - 🔴 Critical: [count]
     - 🟡 Major: [count]
     - 🟢 Minor: [count]
     - ⚪ Nit: [count]

  6. Do NOT commit, push, or modify source files. Report only.`
})
```

Wait for The Optimizer to complete before launching The Skeptic.

### Pass 2 — The Skeptic (challenge report)

Runs second in a worktree. Reads The Optimizer's findings AND the code. Challenges suggestions and catches missed issues.

```
Agent({
  subagent_type: "general-purpose",
  isolation: "worktree",
  mode: "bypassPermissions",
  run_in_background: true,
  prompt: `You are "The Skeptic" — the second pass in an adversarial code review of branch [branch] (PR #[number]).

  YOUR ROLE: Challenge The Optimizer's findings. Find flaws in their suggestions. Catch what they missed.
  CONSTRAINT: Do NOT modify any source files. Write your challenge report only.

  1. Read The Optimizer's findings: /tmp/code-review-optimizer-[branch].md
  2. Read ALL changed files: git diff origin/main...HEAD
  3. Read CLAUDE.md for project conventions

  For EACH of The Optimizer's findings, evaluate:
  - Is the issue real or a false positive?
  - Would the suggested fix introduce new problems (break portability, change behavior, etc.)?
  - Is the fix over-engineered for the actual risk?
  - Does the severity rating match the actual impact?
  - Is there a simpler or safer alternative?

  REQUIREMENT: You MUST challenge at least 2 of The Optimizer's findings with substantive objections (not just "I agree"). Push back where the suggestion is risky, wrong, premature, or over-engineered.

  Then, independently review the code for issues The Optimizer missed, especially:
  - Edge cases in config parsing (empty values, special characters, multi-line, no trailing newline)
  - Race conditions or TOCTOU issues in file checks
  - Bash version compatibility (macOS ships bash 3.2, many features require 4+)
  - Missing error paths (what if terraform init fails partway, what if workspace create and select both fail)
  - Argument handling edge cases (env names with spaces or special chars, empty MODE)

  4. Write your challenge report to /tmp/code-review-skeptic-[branch].md in this exact format:

     # Skeptic Challenge Report — [branch]

     ## Challenges to Optimizer Findings

     ### RE: Finding [N] — [Optimizer's title]
     - **Verdict**: ✅ Agree | ⚠️ Disagree | 🔄 Agree with modifications
     - **Challenge**: [why the suggestion is wrong, risky, or over-engineered — be specific]
     - **Alternative**: [better approach, if applicable]
     - **Risk if applied as-is**: [what could break]

     (Repeat for each Optimizer finding)

     ## Missed Issues

     ### Missed Issue 1: [title]
     - **File**: [path]:[line number]
     - **Severity**: 🔴 Critical | 🟡 Major | 🟢 Minor | ⚪ Nit
     - **Category**: [Edge Case | Portability | Error Path | Argument Handling | Other]
     - **Problem**: [what is wrong]
     - **Suggested fix**: [concrete code change or approach]

     ## Statistics
     - Optimizer findings challenged: [count]
     - Findings agreed with: [count]
     - Findings agreed with modifications: [count]
     - New issues found: [count]

  5. Do NOT commit, push, or modify source files. Report only.`
})
```

Wait for The Skeptic to complete.

## Phase 4: Synthesize and Apply

Read both reports:
1. `/tmp/code-review-optimizer-[branch].md`
2. `/tmp/code-review-skeptic-[branch].md`

### Resolve each finding

For each Optimizer finding, cross-reference The Skeptic's verdict:

| Skeptic Verdict | Action |
|-----------------|--------|
| ✅ Agree | Apply the fix (Critical/Major) or note it (Minor/Nit) |
| ⚠️ Disagree | Present the dispute to the user — do NOT auto-fix |
| 🔄 Agree with modifications | Apply the modified version (Critical/Major) or note it (Minor/Nit) |

For Skeptic's missed issues: treat as new findings and apply Critical/Major fixes.

### Apply agreed fixes

1. Fix all undisputed 🔴 Critical and 🟡 Major issues
2. Run validation: `shellcheck tf`
3. If fixes were applied, commit: `fix: address code review findings`
4. Do NOT push yet — present the report first

## Phase 5: Summary

**Output findings table**:

| Source | Severity | File | Finding | Skeptic Verdict | Status |
|--------|----------|------|---------|-----------------|--------|
| GitHub | ...      | ...  | ...     | —               | Fixed / Skipped / Needs discussion |
| Optimizer | ...   | ...  | ...     | Agree / Disagree / Modified | Fixed / Disputed / Deferred |
| Skeptic (missed) | ... | ... | ...  | —               | Fixed / Deferred |

Report sections:
- **Summary**: What was added/modified/removed
- **GitHub Feedback**: Items addressed vs skipped
- **Consensus Fixes Applied**: Issues both agents agreed on that were auto-fixed
- **Disputed Items** (requires author decision): Issues where The Skeptic disagreed — present both sides with a recommendation
- **Remaining Items**: Minor and Nit issues not auto-fixed (for author to decide)
- **Recommendation**: Approve, Request Changes, or Comment

After the user reviews disputed items and remaining items:
1. Apply any additional fixes the user approves
2. Re-run validation: `shellcheck tf`
3. Commit and push: `git push`
