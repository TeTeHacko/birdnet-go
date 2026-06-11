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
# Captures just the latest verification (typecheck + go vet) output so a failed
# verify can be fed back to the model for repair, instead of being discarded.
readonly VERIFY_LOG="$STATE_DIR/verify-output.txt"
readonly MAX_FAILURES=3
# How many times to feed verification errors back to the model to repair a
# merge that resolved textually but doesn't compile/typecheck. Auto-merged
# (non-conflict) files broken by upstream API changes only surface here.
readonly MAX_REPAIRS=2
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
# Mirrors the failing check's output into VERIFY_LOG so build_repair_prompt can
# hand the exact errors back to the model.
try_verify() {
	local model_short="$1"

	: >"$VERIFY_LOG"

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
	if ! (cd "$REPO_DIR/frontend" && npm run typecheck) 2>&1 | tee -a "$LOG_FILE" "$VERIFY_LOG"; then
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
	if ! (cd "$REPO_DIR" && CGO_ENABLED=1 CGO_CFLAGS="$go_cgo_cflags" go vet ./...) 2>&1 | tee -a "$LOG_FILE" "$VERIFY_LOG"; then
		MODEL_ERRORS+="  $model_short: go vet failed\n"
		log "  ✗ $model_short: go vet failed"
		return 1
	fi

	log "  ✓ $model_short: all checks passed"
	return 0
}

# Build a repair prompt from the captured verification output. Used when the
# merge resolved textually but typecheck/go vet fails — typically because an
# upstream API change met our local code in an AUTO-MERGED (non-conflict) file,
# which git merges cleanly but breaks compilation. The model never saw those
# files in the original conflict set, so we point it straight at the errors.
build_repair_prompt() {
	local errors
	errors="$(tail -n 150 "$VERIFY_LOG" 2>/dev/null || echo "(no captured output)")"
	cat <<-PROMPT
		The merge conflicts were resolved and committed, but verification
		(TypeScript typecheck and/or 'go vet ./...') is now FAILING.

		CRITICAL: these failures are usually in files that were NOT part of the
		original conflict set. When upstream changes a function signature, a
		struct field's type, or an interface method, and our local code or tests
		still use the old form, git auto-merges both sides cleanly but the result
		does not compile. Fix ALL reported errors wherever they live — do not
		limit yourself to files that had conflict markers.

		VERIFICATION OUTPUT (the errors you must fix):
		$errors

		INSTRUCTIONS:
		1. Read every error above and open each file it references.
		2. Fix each one. Common causes: changed function/method signatures (e.g.
		   a new variadic or parameter), a struct field that became an
		   atomic.Pointer now accessed via .Load(), duplicate imports introduced
		   by the merge, or removed/renamed symbols.
		3. Find how other, already-correct call sites use the new API and mirror
		   that convention exactly.
		4. git add every fixed file. Do NOT create a new commit and do NOT amend
		   — leave the fixes staged; the harness folds them into the merge commit.
		5. Do not revert the conflict resolution; only fix the build/typecheck.
	PROMPT
}

# Verify the committed merge and, on failure, feed the errors back to the model
# to repair, up to MAX_REPAIRS times. Returns 0 once verification passes, 1 if
# it still fails after exhausting repair attempts.
verify_with_repair() {
	local model="$1"
	local model_short="${model##*/}"
	local attempt=0

	while true; do
		if try_verify "$model_short"; then
			return 0
		fi

		if [ "$attempt" -ge "$MAX_REPAIRS" ]; then
			MODEL_ERRORS+="  $model_short: verification still failing after $MAX_REPAIRS repair attempt(s)\n"
			log "  ✗ $model_short: still failing after $MAX_REPAIRS repair attempt(s)"
			return 1
		fi

		attempt=$((attempt + 1))
		log "  ⟳ $model_short: verification failed — repair attempt $attempt/$MAX_REPAIRS"

		local repair_prompt
		repair_prompt="$(build_repair_prompt)"
		if ! opencode run "$repair_prompt" \
			--dir "$REPO_DIR" \
			--model "$model" \
			--dangerously-skip-permissions \
			--title "merge-repair-$(date +%Y%m%d-%H%M%S)" 2>&1 | tee -a "$LOG_FILE"; then
			log "  ✗ $model_short: repair run failed to execute"
			return 1
		fi

		# Fold the model's repair edits into the merge commit. The repair prompt
		# asks it to leave changes staged/unstaged but not commit; amend keeps a
		# single merge commit so the downstream fast-forward push still works.
		if [ -n "$(cd "$REPO_DIR" && git status --porcelain)" ]; then
			log "  folding repair changes into merge commit..."
			(cd "$REPO_DIR" && git add -A && git commit --amend --no-edit) >/dev/null 2>&1 || true
		fi
	done
}

resolve_sync() {
	local state_file="$STATE_DIR/last-resolved-run"
	local fail_count_file="$STATE_DIR/consecutive-failures"
	# Sentinel: set once the manual-intervention email has been sent so we stop
	# re-emailing on every subsequent failed auto-sync run. Cleared whenever the
	# failure streak resets (clean upstream sync or a successful resolution).
	local notified_file="$STATE_DIR/manual-intervention-notified"

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
		rm -f "$fail_count_file" "$notified_file"
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
		# Give up after MAX_FAILURES attempts and notify exactly once. The
		# auto-sync workflow keeps producing new failed runs every 15 min, so
		# without this sentinel we'd re-email on each one (spam). Stay quiet
		# until the streak resets (OK branch or a successful resolution).
		if [ -f "$notified_file" ]; then
			log "Already gave up after $MAX_FAILURES failures and notified — staying quiet (manual merge still required)"
			return 0
		fi
		notify "birdnet-merge-resolver: $MAX_FAILURES consecutive failures, needs manual intervention (run #$failed_run_id)"
		send_email "[birdnet-resolver] ⚠️ Manual intervention needed — run #$failed_run_id" \
			"$MAX_FAILURES consecutive resolution failures. Manual merge required.

Run: #$failed_run_id
Repo: $REPO_DIR

No further automatic attempts or emails will be sent until the next clean
upstream sync or a successful resolution resets the failure counter."
		touch "$notified_file"
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
		# gitea/main is the authoritative deploy line: the gitea Actions
		# auto-sync advances gitea on clean syncs, so github (origin) can lag
		# behind it. We MUST base on gitea/main; otherwise a merge built on the
		# stale github base cannot fast-forward onto gitea and the push fails.
		git fetch gitea main 2>&1 | tail -3 || die "Failed to fetch gitea"
		git fetch origin main 2>&1 | tail -3 || die "Failed to fetch origin"
		git fetch upstream main 2>&1 | tail -3 || die "Failed to fetch upstream"

		# Reset to gitea/main (deploy line)
		git checkout main 2>/dev/null || git checkout -b main gitea/main
		git reset --hard gitea/main

		# Attempt merge
		if git merge upstream/main --no-ff --no-edit \
			-m "Merge upstream/main (auto-resolved by $model_short)" 2>&1 | tee -a "$LOG_FILE"; then
			# A conflict-free merge can still break the build: upstream API
			# changes meeting our local code in auto-merged files compile-fail
			# even with zero conflict markers. So verify (and repair) it too.
			log "Merge succeeded without conflicts — verifying build..."
			if ! verify_with_repair "$model"; then
				git reset --hard gitea/main
				continue
			fi
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

		# Verify the resolution, repairing build/typecheck breakage (including
		# in auto-merged files outside the conflict set) before giving up.
		if ! verify_with_repair "$model"; then
			git reset --hard gitea/main
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
	# Push the deploy line (gitea) first — this is what triggers build/deploy
	# and MUST succeed. Then mirror to github (origin) best-effort: github is
	# always an ancestor of gitea here, so it fast-forwards; a github failure
	# must not block the deploy, so it is non-fatal.
	log "All checks passed! Pushing to gitea/main (deploy line)..."
	if ! git push gitea main 2>&1 | tee -a "$LOG_FILE"; then
		die "git push to gitea/main failed!"
	fi
	log "Mirroring to github (origin/main)..."
	if ! git push origin main 2>&1 | tee -a "$LOG_FILE"; then
		log "WARNING: mirror push to github failed (non-fatal); github will catch up next run"
	fi

	# --- Success ---
	rm -f "$fail_count_file" "$notified_file"
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
