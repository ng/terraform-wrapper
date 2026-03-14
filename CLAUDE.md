# terraform-wrapper

Configurable Bash wrapper for Terraform CLI. Single script (`tf`), no dependencies beyond bash/aws-cli/terraform/jq.

## Quick reference

- **Main script**: `tf` (210 lines, bash with `set -euo pipefail`)
- **Config**: `.tf.conf` (INI-like, parsed without eval)
- **Lint**: `shellcheck tf`
- **Test**: `bash tests/tf_test.sh`
- **PR reviews**: Use `/code-review <number>` for adversarial code review

## Key conventions

- All user input is validated before use — no `eval`, no command injection vectors
- `.env` loading only exports `TF_VAR_*` variables matching `^TF_VAR_[A-Za-z_][A-Za-z0-9_]*$`
- Config parser strips quotes, comments, and whitespace safely
- Raw AWS credentials are always unset — SSO profile is the only auth path
- `TF_WORKSPACE` is always unset and managed explicitly by the script
- Pre-apply hooks must be executable files at `tools/tf-pre-apply`

## When editing `tf`

- Maintain `set -euo pipefail` — never remove strict mode
- Quote all variable expansions (no bare `$VAR`, always `"${VAR}"`)
- Keep ShellCheck clean — run `shellcheck tf` before committing
- Test with both `plan` and passthrough modes (e.g. `output`, `state list`)
- Config parsing must handle: inline comments, quoted values, blank lines, missing keys
