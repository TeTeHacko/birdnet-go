#!/usr/bin/env bash
set -euo pipefail

# birdnet-go merge-conflict-resolver: automatically resolve merge conflicts
# when the Gitea auto-sync-upstream workflow fails.
#
# Monitors the auto-sync workflow for failures, uses opencode with tiered
# model escalation (sonnet → opus → human) to resolve merge conflicts,
# runs typecheck + go vet, and pushes the result.
#
# Designed to run periodically (cron or systemd timer).

readonly REPO_DIR="${BIRDNET_RESOLVER_REPO:-$HOME/projects/birdnet-go}"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/birdnet-merge-resolver"
readonly LOCK_FILE="$STATE_DIR/resolver.lock"
readonly LOG_FILE="$STATE_DIR/resolver.log"
readonly MAX_FAILURES=3
readonly GITEA_REPO="tth/birdnet-go"
# Tiered model escalation: fast/cheap first, then powerful for complex conflicts
readonly MODELS=("github-copilot/claude-sonnet-4.6" "github-copilot/claude-opus-4.6")
readonly GITEA_API="${GITEA_URL:-https://git.rfa.cz}/api/v1/repos/$GITEA_REPO"
readonly SMTP_HOST="${RESOLVER_SMTP_HOST:-192.168.33.200}"
readonly SMTP_PORT="${RESOLVER_SMTP_PORT:-10025}"
readonly MAIL_TO="${RESOLVER_MAIL_TO:-tth@rfa.cz}"
readonly MAIL_FROM="${RESOLVER_MAIL_FROM:-birdnet-resolver@rfa.cz}"
# go-tflite (CGO) needs the TensorFlow Lite C headers to compile. The Taskfile
# clones them here; `go vet ./...` fails with "tensorflow/lite/c/c_api.h: No such
# file" without this include path, which previously made try_verify fail for
# EVERY model regardless of whether the AI resolved the conflict correctly.
readonly TF_HEADERS="${BIRDNET_TF_HEADERS:-$HOME/src/tensorflow}"

# Tracks resolved files across the script
RESOLVED_FILES=""
RESOLVED_BY=""
MODEL_ERRORS=""

mkdir -p "$STATE_DIR"

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

notify() {
	local msg="$1"
	if command -v xmpp-notify >/dev/null 2>&1; then
		xmpp-notify "$msg" >/dev/null 2>&1 || true
	fi
	log "NOTIFY: $msg"
}

send_email() {
	local subject="$1"
	local body="$2"
	local msg
	msg="$(printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nContent-Type: text/plain; charset=utf-8\r\nDate: %s\r\n\r\n%s' \
		"$MAIL_FROM" "$MAIL_TO" "$subject" "$(date -R)" "$body")"
	if printf '%s' "$msg" | curl -fsS --url "smtp://$SMTP_HOST:$SMTP_PORT" \
		--mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
		--upload-file - 2>/dev/null; then
		log "EMAIL: sent to $MAIL_TO — $subject"
	else
		log "EMAIL: failed to send to $MAIL_TO (non-fatal)"
	fi
}

cleanup() {
	rm -f "$LOCK_FILE"
}

die() {
	log "FATAL: $*"
	cleanup
	exit 1
}

# --- Locking (PID-based) ---
if [ -f "$LOCK_FILE" ]; then
	lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
	if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
		log "Another resolver is running (PID $lock_pid), exiting"
		exit 0
	fi
	log "Stale lock file found (PID $lock_pid dead), removing"
	rm -f "$LOCK_FILE"
fi
printf '%s\n' "$$" >"$LOCK_FILE"
trap cleanup EXIT

# --- Load Gitea credentials ---
source "$HOME/.config/gitea/credentials"

gitea_get() {
	curl -fsS -H "Authorization: token $GITEA_TOKEN" "$GITEA_API$1"
}

# --- Main resolution logic ---

# Build the resolution prompt for opencode
build_prompt() {
	local conflict_files="$1"
	cat <<-PROMPT
		You are resolving a git merge conflict in the birdnet-go repository (Go + Svelte/TypeScript).

		Our 'main' branch has local customizations on top of upstream tphakala/birdnet-go.
		A merge of upstream/main into our main produced conflicts.

		CONFLICTED FILES:
		$conflict_files

		INSTRUCTIONS:
		1. Read each conflicted file — they contain <<<<<<< / ======= / >>>>>>> markers
		2. Resolve by keeping BOTH upstream changes AND our local customizations:
		   - Upstream typically adds new features, refactors, or fixes bugs
		   - Our local patches add customizations (Czech locale, deployment config, etc.)
		   - When both sides modify the same area: integrate both changes logically
		3. After resolving EACH file: git add <resolved-file>
		4. After ALL files are resolved: git commit --no-edit (merge commit message is pre-set)
		5. Do NOT create new commits beyond the merge commit
		6. If a .go file is conflicted, ensure the result compiles (correct imports, types, etc.)
		7. If a .ts/.svelte file is conflicted, ensure valid TypeScript/Svelte syntax

		CRITICAL: Preserve both sides. Never drop upstream improvements or our customizations.
		If unsure, prefer upstream's version for logic/architecture but keep our additions.
	PROMPT
}

# Try to resolve conflicts with a specific model. Returns 0 on success.
# On failure, resets the repo and returns 1.
try_resolve_with_model() {
	local model="$1"
	local conflict_files="$2"
	local model_short="${model##*/}"

	log "  → Trying $model_short..."

	local prompt
	prompt="$(build_prompt "$conflict_files")"

	if ! opencode run "$prompt" \
		--dir "$REPO_DIR" \
		--model "$model" \
		--dangerously-skip-permissions \
		--title "merge-resolver-$(date +%Y%m%d-%H%M%S)" 2>&1 | tee -a "$LOG_FILE"; then
		MODEL_ERRORS+="  $model_short: opencode exited with error\n"
		log "  ✗ $model_short: opencode run failed"
		return 1
	fi

	# Verify merge completed (no MERGE_HEAD means it was committed)
	if [ -f "$REPO_DIR/.git/MERGE_HEAD" ]; then
		MODEL_ERRORS+="  $model_short: merge incomplete (MERGE_HEAD still present)\n"
		log "  ✗ $model_short: merge still in progress after opencode"
		return 1
	fi

	log "  ✓ $model_short: conflicts resolved, merge committed"
	return 0
}

# Run verification (typecheck + go vet). Returns 0 if all pass.
try_verify() {
	local model_short="$1"

	# Install frontend deps (skip if already installed)
	if [ ! -d "$REPO_DIR/frontend/node_modules" ]; then
		log "  Installing frontend deps..."
		if ! (cd "$REPO_DIR/frontend" && npm ci --no-audit --no-fund) 2>&1 | tail -5; then
			log "  npm ci failed, trying npm install..."
			if ! (cd "$REPO_DIR/frontend" && npm install --no-audit --no-fund) 2>&1 | tail -5; then
				MODEL_ERRORS+="  $model_short: npm install failed\n"
				log "  ✗ $model_short: npm install failed"
				return 1
			fi
		fi
	fi

	log "  Running TypeScript check..."
	if ! (cd "$REPO_DIR/frontend" && npm run typecheck) 2>&1 | tee -a "$LOG_FILE"; then
		MODEL_ERRORS+="  $model_short: typecheck failed\n"
		log "  ✗ $model_short: typecheck failed"
		return 1
	fi

	log "  Running Go vet..."
	# go-tflite requires CGO + the TF Lite C headers; without CGO_CFLAGS the vet
	# step fails on missing tensorflow headers (not a real resolution failure).
	local go_cgo_cflags=""
	if [ -f "$TF_HEADERS/tensorflow/lite/c/c_api.h" ]; then
		go_cgo_cflags="-I$TF_HEADERS"
	else
		log "  ⚠ TF headers not found at $TF_HEADERS — go vet may fail on CGO deps"
	fi
	if ! (cd "$REPO_DIR" && CGO_ENABLED=1 CGO_CFLAGS="$go_cgo_cflags" go vet ./...) 2>&1 | tee -a "$LOG_FILE"; then
		MODEL_ERRORS+="  $model_short: go vet failed\n"
		log "  ✗ $model_short: go vet failed"
		return 1
	fi

	log "  ✓ $model_short: all checks passed"
	return 0
}

resolve_sync() {
	local state_file="$STATE_DIR/last-resolved-run"
	local fail_count_file="$STATE_DIR/consecutive-failures"

	log "=== Checking auto-sync-upstream workflow ==="

	# Find the latest non-cancelled run for main branch
	local run_info
	run_info="$(gitea_get "/actions/runs?limit=10" | jq -r '
    [.workflow_runs // [] | .[] | select(.head_branch == "main")] |
    if length == 0 then "NONE"
    else
      (
        [.[] | select(.conclusion != "cancelled")] |
        if length == 0 then "NONE"
        else
          (.[0] |
            if .status == "completed" and .conclusion == "failure" then
              "\(.id)\t\(.event)"
            elif .status == "completed" and .conclusion == "success" then
              "OK"
            elif .status != "completed" then
              "RUNNING"
            else "NONE"
            end
          )
        end
      )
    end
  ')"

	case "$run_info" in
	NONE)
		log "No runs found, skipping"
		return 0
		;;
	OK)
		log "Latest is success, nothing to do"
		rm -f "$fail_count_file"
		return 0
		;;
	RUNNING)
		log "A run is in progress, skipping"
		return 0
		;;
	esac

	local failed_run_id failed_run_event
	IFS=$'\t' read -r failed_run_id failed_run_event <<<"$run_info"

	# Already resolved this run?
	if [ -f "$state_file" ] && [ "$(<"$state_file")" = "$failed_run_id" ]; then
		log "Run #$failed_run_id already attempted, skipping"
		return 0
	fi

	log "Found failed run #$failed_run_id (event: ${failed_run_event:-unknown})"

	# Check if it's a merge conflict failure (look for "merge" or "conflict" in step output)
	local is_merge_failure
	is_merge_failure="$(gitea_get "/actions/runs/$failed_run_id/jobs" | jq -r '
    [.jobs[].steps[] | select(.name | test("[Mm]erge|[Ss]ync"; "i")) | .conclusion] |
    if any(. == "failure") then "yes"
    else "no"
    end
  ')"

	if [ "$is_merge_failure" = "no" ]; then
		log "Run #$failed_run_id failed but not in merge step — checking all steps..."
		is_merge_failure="$(gitea_get "/actions/runs/$failed_run_id/jobs" | jq -r '
      [.jobs[].steps[] | select(.conclusion == "failure") | .name] |
      if any(test("[Mm]erge|[Aa]ttempt"; "i")) then "yes"
      else "no"
      end
    ')"
		if [ "$is_merge_failure" = "no" ]; then
			log "Run #$failed_run_id: failure is not merge-related, skipping"
			printf '%s\n' "$failed_run_id" >"$state_file"
			return 0
		fi
	fi

	# Check consecutive failure count
	local failures
	failures="$(cat "$fail_count_file" 2>/dev/null || echo 0)"
	if [ "$failures" -ge "$MAX_FAILURES" ]; then
		notify "birdnet-merge-resolver: $MAX_FAILURES consecutive failures, needs manual intervention (run #$failed_run_id)"
		send_email "[birdnet-resolver] ⚠️ Manual intervention needed — run #$failed_run_id" \
			"$MAX_FAILURES consecutive resolution failures. Manual merge required.

Run: #$failed_run_id
Repo: $REPO_DIR"
		return 1
	fi

	log "Merge conflict detected! Attempting resolution (attempt $((failures + 1))/$MAX_FAILURES)..."

	# --- Prepare the repo ---
	if [ ! -d "$REPO_DIR/.git" ]; then
		die "Repo not found at $REPO_DIR"
	fi

	cd "$REPO_DIR"

	# Ensure upstream remote exists
	if ! git remote get-url upstream >/dev/null 2>&1; then
		git remote add upstream https://github.com/tphakala/birdnet-go.git
	fi

	# --- Tiered resolution: try each model in order ---
	RESOLVED_FILES=""
	RESOLVED_BY=""
	MODEL_ERRORS=""
	local resolved=false

	for model in "${MODELS[@]}"; do
		local model_short="${model##*/}"
		log "--- Model tier: $model_short ---"

		# Reset to clean state for this attempt
		git merge --abort 2>/dev/null || true
		git checkout -- . 2>/dev/null || true
		git clean -fd 2>/dev/null || true

		# Fetch latest
		git fetch origin main 2>&1 | tail -3 || die "Failed to fetch origin"
		git fetch upstream main 2>&1 | tail -3 || die "Failed to fetch upstream"

		# Reset to origin/main
		git checkout main 2>/dev/null || git checkout -b main origin/main
		git reset --hard origin/main

		# Attempt merge
		if git merge upstream/main --no-ff --no-edit \
			-m "Merge upstream/main (auto-resolved by $model_short)" 2>&1 | tee -a "$LOG_FILE"; then
			log "Merge succeeded without conflicts — no resolution needed"
			RESOLVED_BY="clean-merge"
			resolved=true
			break
		fi

		# Check for actual conflict markers
		local conflict_files
		conflict_files="$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")"
		if [ -z "$conflict_files" ]; then
			git merge --abort 2>/dev/null || true
			die "Merge failed but no conflict markers found — unknown error"
		fi
		RESOLVED_FILES="$conflict_files"

		log "Conflicts in: $conflict_files"

		# Try resolving with this model
		if ! try_resolve_with_model "$model" "$conflict_files"; then
			git merge --abort 2>/dev/null || true
			continue
		fi

		# Verify the resolution
		if ! try_verify "$model_short"; then
			git reset --hard origin/main
			continue
		fi

		# Success with this model!
		RESOLVED_BY="$model_short"
		resolved=true
		break
	done

	if [ "$resolved" = false ]; then
		# All models failed
		printf '%s\n' "$((failures + 1))" >"$fail_count_file"
		printf '%s\n' "$failed_run_id" >"$state_file"

		local error_summary
		error_summary="$(printf '%b' "$MODEL_ERRORS")"
		notify "birdnet-merge-resolver: all models failed for run #$failed_run_id (attempt $((failures + 1))/$MAX_FAILURES)"
		send_email "[birdnet-resolver] ✗ All models failed — run #$failed_run_id" \
			"All resolution models failed.

Run: #$failed_run_id
Attempt: $((failures + 1))/$MAX_FAILURES
Conflicted files: $RESOLVED_FILES

Model results:
$error_summary
Check logs: $LOG_FILE"
		return 1
	fi

	# --- Push result ---
	log "All checks passed! Pushing to origin/main..."
	if ! git push origin main 2>&1 | tee -a "$LOG_FILE"; then
		die "git push to origin/main failed!"
	fi

	# --- Success ---
	rm -f "$fail_count_file"
	printf '%s\n' "$failed_run_id" >"$state_file"
	local new_head
	new_head="$(git rev-parse --short HEAD)"

	# Build resolution summary
	local detail_msg
	if [ "$RESOLVED_BY" = "clean-merge" ]; then
		detail_msg="birdnet-merge-resolver: ✓ run #$failed_run_id — clean merge, pushed $new_head"
	else
		detail_msg="birdnet-merge-resolver: ✓ run #$failed_run_id resolved by $RESOLVED_BY — $(echo "$RESOLVED_FILES" | tr '\n' ',' | sed 's/,$//'), pushed $new_head"
	fi

	notify "$detail_msg"
	send_email "[birdnet-resolver] ✓ Run #$failed_run_id resolved" \
		"birdnet-merge-resolver completed successfully.

Run: #$failed_run_id
Resolved by: $RESOLVED_BY
New HEAD: $new_head
Resolved files: ${RESOLVED_FILES:-none (clean merge)}

Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"

	log "Done! New HEAD: $new_head (resolved by $RESOLVED_BY)"
	return 0
}

# --- Main ---
log "Checking auto-sync CI for $GITEA_REPO ($(date '+%Y-%m-%d %H:%M:%S'))..."
resolve_sync || true
log "Done."
