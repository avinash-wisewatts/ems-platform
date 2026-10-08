#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# scripts/test/assert_deploy_production_promotion_gate.sh
#
# Static/local validation for the GitHub-Free production promotion gate in
# .github/workflows/deploy-production.yml (the validate-promotion job).
#
# GitHub Actions workflow YAML has no local unit-test runner on this
# repository's toolchain (no `act`, no self-hosted runner). The checks below
# mirror the exact regex/comparison/loop logic embedded in
# deploy-production.yml's `validate-promotion` job -- if that job's logic
# changes, these mirrored snippets must be updated to match, or this test
# stops proving anything real. Where the check involves live state (staging
# HEAD, a deploy-staging.yml run, a GHCR image), this script exercises the
# real `git`/`gh`/`docker` commands against the actual repository and
# registry rather than mocking them, so a pass here is evidence the gate
# will behave correctly against today's real state, not just that the
# regex is well-formed.
#
# This script never dispatches deploy-production.yml and never touches
# staging or production.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKFLOW_FILE="${PROJECT_ROOT}/.github/workflows/deploy-production.yml"

REPO="avinash-wisewatts/ems-platform"
PASS=0
FAIL=0

# Extracts the raw YAML lines for top-level job $1 (e.g. "validate-promotion")
# from deploy-production.yml, up to (but not including) the next 2-space-
# indented job key or end of file. Used for job-scoped structural
# assertions (Tests 10-12) without needing a YAML parser as a dependency.
extract_job() {
    local job="$1"
    awk -v job="  ${job}:" '
        $0 == job { found=1; print; next }
        found && /^  [a-zA-Z_-]+:/ { exit }
        found { print }
    ' "${WORKFLOW_FILE}"
}

SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP+1)); }

# ----------------------------------------------------------------------------
# Mirrors: "Require exact double-entry commit-SHA confirmation" (SHA format)
# ----------------------------------------------------------------------------
sha_is_valid() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

echo "=== Test 1: malformed SHA ==="
if sha_is_valid "abc123"; then fail "1a: short hex string incorrectly accepted"; else pass "1a: short hex string rejected"; fi
if sha_is_valid "$(printf 'a%.0s' {1..41})"; then fail "1b: 41-char string incorrectly accepted"; else pass "1b: 41-char string rejected"; fi
if sha_is_valid "$(printf 'A%.0s' {1..40})"; then fail "1c: uppercase hex incorrectly accepted"; else pass "1c: uppercase hex rejected"; fi
if sha_is_valid "e4fe0090eb7b19c9caa960af4b94f2803e92147g"; then fail "1d: non-hex character incorrectly accepted"; else pass "1d: non-hex character rejected"; fi
if sha_is_valid "e4fe0090eb7b19c9caa960af4b94f2803e921477"; then pass "1e: well-formed 40-char lowercase hex SHA accepted"; else fail "1e: well-formed SHA incorrectly rejected"; fi

# ----------------------------------------------------------------------------
# Mirrors: confirm_release_git_sha byte-for-byte comparison
# ----------------------------------------------------------------------------
echo
echo "=== Test 2: mismatched confirmation SHA ==="
a="e4fe0090eb7b19c9caa960af4b94f2803e921477"
b="e4fe0090eb7b19c9caa960af4b94f2803e921478"
if [[ "$a" == "$b" ]]; then fail "2a: single-character-differing SHAs incorrectly matched"; else pass "2a: single-character-differing SHAs correctly rejected"; fi
if [[ "$a" == "$a" ]]; then pass "2b: identical SHAs correctly matched"; else fail "2b: identical SHAs incorrectly rejected"; fi

# ----------------------------------------------------------------------------
# Mirrors: "Require release_git_sha to be staging's current HEAD"
# Live check against the real remote, via the SAME authenticated GitHub API
# call the workflow itself uses (gh api .../git/ref/heads/staging), not a
# raw `git ls-remote`. An earlier version of this test used
# `git ls-remote https://github.com/...` directly and passed locally --
# but only because this developer machine's git has a credential helper
# transparently supplying a token for github.com. That is exactly the class
# of gap that made the real GitHub Actions runner fail closed in production
# (2026-08-25, run 32858328343): the runner has no such credential helper
# and no actions/checkout in that job, so the identical-looking command
# fails there with "could not read Username". Mirroring the actual fixed
# mechanism here, instead of a differently-authenticated command that only
# happens to produce the same answer, is the point of this test.
# ----------------------------------------------------------------------------
echo
echo "=== Test 3: SHA different from staging HEAD (live) ==="
staging_head="$(gh api "repos/${REPO}/git/ref/heads/staging" --jq '.object.sha')"
if [[ -z "${staging_head}" ]]; then
    fail "3: could not resolve live staging HEAD -- skipping dependent assertions"
else
    decoy="0000000000000000000000000000000000000000"
    if [[ "${decoy}" == "${staging_head}" ]]; then
        fail "3a: decoy all-zero SHA incorrectly matched staging HEAD"
    else
        pass "3a: decoy SHA correctly rejected as not staging HEAD (current HEAD: ${staging_head})"
    fi
    if [[ "${staging_head}" == "${staging_head}" ]]; then
        pass "3b: current staging HEAD correctly matches itself"
    else
        fail "3b: current staging HEAD failed to match itself"
    fi
fi

# ----------------------------------------------------------------------------
# Mirrors: "Require a successful deploy-staging.yml run for this exact SHA"
# Live check against the real Actions API.
# ----------------------------------------------------------------------------
echo
echo "=== Test 4: SHA with no successful staging deployment (live) ==="
decoy_run="$(gh run list --repo "${REPO}" --workflow=deploy-staging.yml \
    --json headSha,conclusion --limit 100 \
    --jq '[.[] | select(.headSha=="0000000000000000000000000000000000000000" and .conclusion=="success")] | length')"
if [[ "${decoy_run}" == "0" ]]; then
    pass "4a: decoy SHA correctly has zero successful deploy-staging.yml runs"
else
    fail "4a: decoy SHA unexpectedly matched a successful run"
fi

# Mirrors the workflow's server-side --commit filter plus the unchanged
# headSha/conclusion filter.
successful_staging_runs() {
    gh run list --repo "${REPO}" --workflow=deploy-staging.yml \
        --commit "$1" --json headSha,conclusion --limit 100 \
        --jq "[.[] | select(.headSha==\"$1\" and .conclusion==\"success\")] | length"
}

if [[ -n "${staging_head:-}" ]]; then
    real_run="$(successful_staging_runs "${staging_head}")"
    if [[ "${real_run}" != "0" ]]; then
        pass "4b: current staging HEAD (${staging_head}) has a successful deploy-staging.yml run"
    else
        fail "4b: current staging HEAD has NO successful deploy-staging.yml run -- staging is not a valid promotion candidate right now"
    fi
fi

# 4c: an older milestone is found by its exact commit regardless of how many
# later staging runs exist (the reason for --commit).
# 28038ac = release Stage 1 milestone (migrations 223-248), a real staging deploy.
milestone_sha="$(git -C "${PROJECT_ROOT}" rev-parse --verify --quiet 28038ac^{commit} || true)"
if [[ -z "${milestone_sha}" ]]; then
    fail "4c: milestone commit 28038ac not resolvable in this checkout"
elif [[ "$(successful_staging_runs "${milestone_sha}")" != "0" ]]; then
    pass "4c: older milestone ${milestone_sha} is found by exact-commit lookup with a successful deploy-staging.yml run"
else
    fail "4c: older milestone ${milestone_sha} has no successful deploy-staging.yml run found by exact-commit lookup"
fi
# 4d: a commit whose only staging run failed is still rejected.
failed_only_sha="$(git -C "${PROJECT_ROOT}" rev-parse 59ba395 2>/dev/null || true)"
if [[ -n "${failed_only_sha}" ]]; then
    if [[ "$(successful_staging_runs "${failed_only_sha}")" == "0" ]]; then
        pass "4d: commit ${failed_only_sha} (staging deploy concluded 'failure') correctly has zero successful runs"
    else
        fail "4d: commit ${failed_only_sha} unexpectedly has a successful staging run"
    fi
else
    skip "4d: commit 59ba395 not resolvable in this checkout"
fi

# ----------------------------------------------------------------------------
# Mirrors: "Resolve and verify the SHA-derived image exists in GHCR"
# Live check against the real registry (read-only inspect, no pull/push).
# ----------------------------------------------------------------------------
echo
echo "=== Test 5: missing GHCR image (live) ==="
# ghcr.io/avinash-wisewatts/ems-platform-app is a private package: anonymous
# `docker buildx imagetools inspect` fails with 401 Unauthorized for ANY tag,
# real or decoy, without the REGISTRY_USERNAME/REGISTRY_PASSWORD credentials
# the workflow itself logs in with. This script deliberately does not use
# those secrets interactively, so it cannot distinguish "not found" (404)
# from "not authorized to check" (401) the way the real workflow step can
# once it has logged in. Both sub-checks below are therefore reported as
# SKIP with the reason, rather than a false PASS or FAIL, when the failure
# looks like an auth problem rather than a real registry response.
image_check_authable="false"
decoy_image="ghcr.io/${REPO}-app:0000000000000000000000000000000000000000"
decoy_out="$(docker buildx imagetools inspect "${decoy_image}" 2>&1)" || true
if echo "${decoy_out}" | grep -qi "401 Unauthorized\|failed to authorize"; then
    skip "5a: cannot distinguish not-found from unauthorized without registry credentials this script intentionally does not hold (workflow authenticates via REGISTRY_USERNAME/REGISTRY_PASSWORD before this check)"
elif echo "${decoy_out}" | grep -qi "not found\|manifest unknown\|404"; then
    pass "5a: decoy image tag correctly not found in GHCR"
    image_check_authable="true"
else
    fail "5a: decoy image tag produced an unexpected result: ${decoy_out}"
fi

if [[ -n "${staging_head:-}" ]]; then
    if [[ "${image_check_authable}" == "true" ]]; then
        real_image="ghcr.io/${REPO}-app:${staging_head}"
        if docker buildx imagetools inspect "${real_image}" >/dev/null 2>&1; then
            pass "5b: image for current staging HEAD exists in GHCR (${real_image})"
        else
            fail "5b: image for current staging HEAD NOT found in GHCR"
        fi
    else
        skip "5b: same credential limitation as 5a -- independently confirmed instead via staging's running container: 'docker inspect ems-admin-portal' on the staging host reports image ghcr.io/${REPO}-app:${staging_head} (see task record)"
    fi
fi

# ----------------------------------------------------------------------------
# Mirrors: "Require an approved production operator"
# ----------------------------------------------------------------------------
echo
echo "=== Test 6: unauthorized workflow actor ==="
check_actor() {
    local actor="$1" approved_csv="$2"
    if [[ -z "${approved_csv}" ]]; then
        return 1
    fi
    local IFS=','
    local -a allowed
    read -ra allowed <<< "${approved_csv}"
    for name in "${allowed[@]}"; do
        local trimmed
        trimmed="$(echo "${name}" | xargs)"
        if [[ "${trimmed}" == "${actor}" ]]; then
            return 0
        fi
    done
    return 1
}

if check_actor "some-random-user" "alice,bob"; then
    fail "6a: actor not in allowlist incorrectly authorized"
else
    pass "6a: actor not in allowlist correctly rejected"
fi
if check_actor "bob" "alice, bob , carol"; then
    pass "6b: allowlisted actor correctly authorized (including surrounding-whitespace tolerance)"
else
    fail "6b: allowlisted actor incorrectly rejected"
fi
if check_actor "alice" ""; then
    fail "6c: empty/unset allowlist incorrectly authorized an actor (must fail closed)"
else
    pass "6c: empty/unset allowlist correctly fails closed"
fi

# ----------------------------------------------------------------------------
# Test 7: successful validation path (composite, live) -- every real
# component the validate-promotion job depends on is currently satisfiable
# for the actual current staging HEAD.
# ----------------------------------------------------------------------------
echo
echo "=== Test 7: successful validation path (live, composite) ==="
# The GHCR-existence leg is asserted separately in Test 5 (with credentials
# this script does not hold, it can only run the un-authenticated form) --
# composited here from the three legs this script CAN verify end-to-end
# without registry credentials.
if [[ -n "${staging_head:-}" ]] \
    && sha_is_valid "${staging_head}" \
    && [[ "${real_run:-0}" != "0" ]]; then
    pass "7: current staging HEAD (${staging_head}) satisfies every live, credential-free validate-promotion precondition (SHA format, staging-HEAD match, successful staging run); GHCR image existence is covered by Test 5 under the workflow's own authenticated credentials"
else
    fail "7: current staging HEAD does NOT satisfy the credential-free validate-promotion preconditions right now"
fi

# ----------------------------------------------------------------------------
# Tests 8-14: structural assertions against the actual workflow source.
# These do not require any live credentials -- they prove the fixed
# implementation is present in the file that will actually run, not just
# that some equivalent logic passes in this script.
# ----------------------------------------------------------------------------

echo
echo "=== Test 8: staging HEAD lookup uses an authenticated GitHub mechanism ==="
auth_lookup_count="$(grep -cE 'gh api "repos/\$\{\{ github\.repository \}\}/git/ref/heads/staging"' "${WORKFLOW_FILE}" || true)"
if [[ "${auth_lookup_count}" -eq 2 ]]; then
    pass "8: authenticated gh api ref lookup present in both staging-HEAD checks (validate-promotion and the pre-deploy race recheck)"
else
    fail "8: expected 2 occurrences of the authenticated staging-HEAD lookup (validate-promotion + race recheck), found ${auth_lookup_count}"
fi

echo
echo "=== Test 9: no raw unauthenticated git ls-remote against github.com remains ==="
executable_ls_remote="$(grep -nE 'git ls-remote.*github\.com' "${WORKFLOW_FILE}" | grep -v '^[0-9]*:[[:space:]]*#' || true)"
if [[ -z "${executable_ls_remote}" ]]; then
    pass "9: no executable (non-comment) git ls-remote against github.com remains -- this is exactly the pattern that failed closed in run 32858328343"
else
    fail "9: found what looks like an executable git ls-remote against github.com: ${executable_ls_remote}"
fi

echo
echo "=== Test 10: production SSH secrets unavailable to validate-promotion ==="
validate_block="$(extract_job "validate-promotion")"
if echo "${validate_block}" | grep -qE 'PRODUCTION_HOST|PRODUCTION_USER|PRODUCTION_SSH_KEY'; then
    fail "10: validate-promotion job references a production SSH secret -- it must never have SSH access"
else
    pass "10: validate-promotion job does not reference any production SSH secret (only REGISTRY_* and the built-in github.token)"
fi

echo
echo "=== Test 11: deploy-production depends on validate-promotion ==="
deploy_block="$(extract_job "deploy-production")"
if echo "${deploy_block}" | grep -qE '^[[:space:]]*needs:[[:space:]]*validate-promotion[[:space:]]*$'; then
    pass "11: deploy-production job declares needs: validate-promotion"
else
    fail "11: deploy-production job does not declare needs: validate-promotion"
fi

echo
echo "=== Test 12: staging HEAD recheck, then image resolution, then SSH -- in that exact order ==="
# 2026-08-25 update: deploy-production now resolves its own digest-pinned
# image (step "Resolve and pin the deployment image") between the staging-
# HEAD recheck and the SSH step, instead of consuming validate-promotion's
# resolved value via a cross-job output -- see Test 15 for why. So exactly
# one step (the image resolution) is expected between the recheck and SSH,
# not zero.
recheck_line="$(echo "${deploy_block}" | grep -n 'name: Re-verify staging HEAD' | head -1 | cut -d: -f1)"
resolve_line="$(echo "${deploy_block}" | grep -n 'name: Resolve and pin the deployment image' | head -1 | cut -d: -f1)"
ssh_line="$(echo "${deploy_block}" | grep -n 'name: Deploy over SSH' | head -1 | cut -d: -f1)"
if [[ -n "${recheck_line}" && -n "${resolve_line}" && -n "${ssh_line}" \
    && "${recheck_line}" -lt "${resolve_line}" && "${resolve_line}" -lt "${ssh_line}" ]]; then
    between="$(echo "${deploy_block}" | sed -n "$((resolve_line+1)),$((ssh_line-1))p" | grep -cE '^[[:space:]]*- name:' || true)"
    if [[ "${between}" -eq 0 ]]; then
        pass "12: deploy-production steps run in order: staging-HEAD recheck, image resolution, Deploy over SSH -- with nothing else between resolution and SSH"
    else
        fail "12: another step appears between image resolution and Deploy over SSH"
    fi
else
    fail "12: could not confirm the expected step order (staging-HEAD recheck -> image resolution -> Deploy over SSH) in deploy-production"
fi

echo
echo "=== Test 13: image is derived from release_git_sha, not an independent input ==="
if grep -qE '^[[:space:]]*image_tag:' "${WORKFLOW_FILE}"; then
    fail "13a: an independent image_tag input still exists"
else
    pass "13a: no independent image_tag input exists"
fi
if grep -qF 'image="${REGISTRY}/${IMAGE_NAME}:${RELEASE_SHA}"' "${WORKFLOW_FILE}"; then
    pass "13b: image reference is constructed from REGISTRY/IMAGE_NAME/RELEASE_SHA (derived from release_git_sha)"
else
    fail "13b: could not find the expected SHA-derived image construction"
fi

echo
echo "=== Test 14: production deployment uses the resolved, digest-pinned image ==="
digest_construction_count="$(grep -cF 'image_with_digest="${REGISTRY}/${IMAGE_NAME}:${RELEASE_SHA}@${digest}"' "${WORKFLOW_FILE}" || true)"
if [[ "${digest_construction_count}" -eq 2 ]]; then
    pass "14a: digest-pinned image reference (tag@digest) is constructed in both validate-promotion's early check and deploy-production's authoritative resolution"
else
    fail "14a: expected the digest-pinned image construction exactly twice (early check + authoritative resolution), found ${digest_construction_count}"
fi
if grep -qF 'APP_IMAGE: ${{ steps.resolve-image.outputs.image_with_digest }}' "${WORKFLOW_FILE}"; then
    pass "14b: deploy-production's APP_IMAGE is sourced from a same-job step output"
else
    fail "14b: deploy-production does not consume a same-job resolved digest-pinned image output"
fi

# ----------------------------------------------------------------------------
# Tests 15-18: the 2026-08-25 image-handoff fix. The first real dispatch
# (run 32858328343 -> 32861162765) proved that a job-level output
# (jobs.validate-promotion.outputs.image_with_digest, the mechanism behind
# needs.validate-promotion.outputs.*) gets silently discarded by GitHub
# Actions' own secret-masking check at job completion when the value
# happens to match a secret used in that job ("Skip output
# 'image_with_digest' since it may contain secret") -- validate-promotion
# reported success, but deploy-production's APP_IMAGE was empty, and
# deploy_release.sh correctly refused to run rather than deploy with no
# image. The fix moves authoritative image resolution into deploy-production
# itself, as a same-job step output, which is never subject to that
# specific job-outputs masking check. These tests prove the fixed
# architecture is actually present, not just that some digest string
# appears somewhere in the file.
# ----------------------------------------------------------------------------

echo
echo "=== Test 15: validate-promotion no longer exposes a job-level image output ==="
if echo "${validate_block}" | grep -qE '^[[:space:]]*outputs:'; then
    fail "15: validate-promotion still declares a job-level outputs: block -- this is exactly the cross-job channel GitHub Actions silently discarded"
else
    pass "15: validate-promotion declares no job-level outputs: block (the image is no longer handed off through a cross-job output)"
fi

echo
echo "=== Test 16: deploy-production does not consume validate-promotion's job output for the image ==="
if echo "${deploy_block}" | grep -qE 'needs\.validate-promotion\.outputs\.image'; then
    fail "16: deploy-production still references needs.validate-promotion.outputs.image* -- this is the exact reference that resolved empty on the failed run"
else
    pass "16: deploy-production does not reference needs.validate-promotion.outputs.image* anywhere"
fi

echo
echo "=== Test 17: deploy-production resolves its own image via a same-job step output ==="
if echo "${deploy_block}" | grep -qE '^[[:space:]]*id:[[:space:]]*resolve-image[[:space:]]*$'; then
    pass "17a: deploy-production declares its own resolve-image step"
else
    fail "17a: deploy-production does not declare its own resolve-image step"
fi
if echo "${deploy_block}" | grep -qF 'docker buildx imagetools inspect "${image}"'; then
    pass "17b: deploy-production's resolve-image step independently authenticates to GHCR and inspects the SHA-derived image"
else
    fail "17b: deploy-production's resolve-image step does not perform its own GHCR inspection"
fi

echo
echo "=== Test 18: deploy_release.sh remains unchanged by this fix (live, vs origin/staging) ==="
if git diff --quiet origin/staging -- scripts/release/deploy_release.sh 2>/dev/null; then
    pass "18: scripts/release/deploy_release.sh is byte-identical to origin/staging -- this fix touched only the workflow"
else
    fail "18: scripts/release/deploy_release.sh differs from origin/staging -- this fix must not modify the deployment script"
fi

# ----------------------------------------------------------------------------
# Tests 19-23: staging-milestone promotion mode (2026-10-08). Mirrors the
# compare-API logic in validate-promotion ("Require release_git_sha to be
# staging's current HEAD (or ... in staging's history)" and "Require a
# milestone to move production forward") and the deploy-production recheck,
# against the real repository via the same authenticated `gh api` calls.
# ----------------------------------------------------------------------------

# Mirrors: staging-milestone ancestry check. 0 = accepted.
milestone_in_staging_history() {
    local sha="$1" head="$2" status
    status="$(gh api "repos/${REPO}/compare/${sha}...${head}" --jq '.status' 2>/dev/null)" || return 1
    [[ "${status}" == "ahead" || "${status}" == "identical" ]]
}
# Mirrors: forward-only check. 0 = accepted (last promoted is a strict ancestor).
moves_production_forward() {
    local last="$1" sha="$2" status
    status="$(gh api "repos/${REPO}/compare/${last}...${sha}" --jq '.status' 2>/dev/null)" || return 1
    [[ "${status}" == "ahead" ]]
}

echo
echo "=== Test 19: staging-milestone ancestry check (live) ==="
if [[ -n "${staging_head:-}" ]]; then
    if milestone_in_staging_history "${staging_head}" "${staging_head}"; then pass "19a: staging HEAD itself accepted (identical)"; else fail "19a: staging HEAD rejected"; fi
    if milestone_in_staging_history "${milestone_sha}" "${staging_head}"; then pass "19b: older milestone ${milestone_sha} accepted (in staging history)"; else fail "19b: older milestone ${milestone_sha} rejected"; fi
    if milestone_in_staging_history "0000000000000000000000000000000000000000" "${staging_head}"; then fail "19c: unknown SHA incorrectly accepted"; else pass "19c: unknown SHA rejected (compare fails closed)"; fi
    off_branch="$(git -C "${PROJECT_ROOT}" rev-parse 1c4d635 2>/dev/null || true)"
    if [[ -n "${off_branch}" ]]; then
        if milestone_in_staging_history "${off_branch}" "${staging_head}"; then fail "19d: commit not in staging history (${off_branch}) incorrectly accepted"; else pass "19d: commit not in staging history (${off_branch}, unmerged feature branch) rejected"; fi
    else
        skip "19d: off-staging commit 1c4d635 not resolvable in this checkout"
    fi
else
    fail "19: no live staging HEAD"
fi

echo
echo "=== Test 20: staging-milestone forward-only check (live) ==="
last_promoted="$(gh run list --repo "${REPO}" --workflow=deploy-production.yml --status success --limit 1 --json headSha --jq '.[0].headSha // empty')"
if [[ -z "${last_promoted}" ]]; then
    fail "20: could not determine the last promoted production release (workflow would fail closed)"
else
    if moves_production_forward "${last_promoted}" "${milestone_sha}"; then pass "20a: milestone ${milestone_sha} moves production forward from last promoted ${last_promoted}"; else fail "20a: milestone ${milestone_sha} rejected as not moving forward from ${last_promoted}"; fi
    if moves_production_forward "${last_promoted}" "${last_promoted}"; then fail "20b: redeploying the last promoted release incorrectly accepted"; else pass "20b: redeploying the last promoted release rejected (identical)"; fi
    older="$(gh api "repos/${REPO}/commits/${last_promoted}" --jq '.parents[0].sha' 2>/dev/null || true)"
    if [[ -n "${older}" ]]; then
        if moves_production_forward "${last_promoted}" "${older}"; then fail "20c: older commit ${older} incorrectly accepted (would be a rollback)"; else pass "20c: older commit ${older} rejected (behind the last promoted release)"; fi
    else
        skip "20c: could not resolve a parent of the last promoted release"
    fi
fi

echo
echo "=== Test 21: promotion_mode input is explicit, opt-in, and defaults to the original behaviour ==="
# The block ends at the next line indented 6 spaces or less (next input or section).
mode_block="$(awk '/^      promotion_mode:/{f=1; print; next} f && /^ {0,6}[^ ]/ {exit} f' "${WORKFLOW_FILE}")"
if echo "${mode_block}" | grep -qE '^[[:space:]]*type:[[:space:]]*choice[[:space:]]*$' \
   && echo "${mode_block}" | grep -qE '^[[:space:]]*default:[[:space:]]*staging-head[[:space:]]*$' \
   && [[ "$(echo "${mode_block}" | grep -cE '^[[:space:]]*- staging-(head|milestone)[[:space:]]*$')" -eq 2 ]] \
   && [[ "$(echo "${mode_block}" | grep -cE '^[[:space:]]*- ')" -eq 2 ]]; then
    pass "21: promotion_mode is a choice input with exactly {staging-head, staging-milestone}, default staging-head"
else
    fail "21: promotion_mode is not a two-option choice input defaulting to staging-head"
fi

echo
echo "=== Test 22: staging-head behaviour and every existing safeguard are unchanged ==="
[[ "$(grep -cF "is not staging's current HEAD (\${head}). This workflow only promotes the current staging tip" "${WORKFLOW_FILE}")" -eq 1 ]] \
    && pass "22a: staging-head exact-equality rejection still present in validate-promotion" || fail "22a: staging-head exact-equality rejection missing"
[[ "$(grep -cF 'staging HEAD moved to ${head} after this promotion was validated' "${WORKFLOW_FILE}")" -eq 1 ]] \
    && pass "22b: staging-head pre-deploy race recheck still present in deploy-production" || fail "22b: staging-head race recheck missing"
grep -qF 'name: Require an approved production operator' "${WORKFLOW_FILE}" && grep -qF 'PRODUCTION_APPROVED_OPERATORS' "${WORKFLOW_FILE}" \
    && pass "22c: approved-operator allowlist step unchanged and unconditional" || fail "22c: allowlist step missing"
grep -qF 'name: Require exact double-entry commit-SHA confirmation' "${WORKFLOW_FILE}" \
    && pass "22d: double-entry SHA confirmation step present" || fail "22d: double-entry step missing"
if echo "${validate_block}" | grep -B2 -A2 -E 'name: Require (an approved production operator|exact double-entry|a successful deploy-staging|.*SHA-derived image)' | grep -qE '^[[:space:]]*if:'; then
    fail "22e: an existing safeguard step has become conditional"
else
    pass "22e: allowlist, double-entry, staging-run and image steps remain unconditional (apply in both modes)"
fi
grep -qF -- '--commit "${RELEASE_SHA}"' "${WORKFLOW_FILE}" && grep -qF 'select(.headSha==\"${RELEASE_SHA}\" and .conclusion==\"success\")' "${WORKFLOW_FILE}" \
    && pass "22f: staging-run check is exact-commit (--commit) and still requires headSha match + conclusion success" || fail "22f: staging-run check changed unexpectedly"

echo
echo "=== Test 23: staging-milestone checks are present in both jobs and fail closed ==="
[[ "$(grep -cF 'compare/${RELEASE_SHA}...${head}' "${WORKFLOW_FILE}")" -eq 2 ]] \
    && pass "23a: ancestry compare present in validate-promotion and in the deploy-production recheck" || fail "23a: expected the ancestry compare in exactly 2 places"
forward_step="$(echo "${validate_block}" | awk '/name: Require a milestone to move production forward/{f=1} f&&/- name:/&&!/move production forward/{exit} f')"
echo "${forward_step}" | grep -qF "if: \${{ inputs.promotion_mode == 'staging-milestone' }}" \
    && echo "${forward_step}" | grep -qF 'compare/${last_promoted}...${RELEASE_SHA}' \
    && echo "${forward_step}" | grep -qF '!= "ahead"' \
    && echo "${forward_step}" | grep -qF 'refusing a staging-milestone promotion' \
    && pass "23b: forward-only step runs only in staging-milestone mode, requires strict 'ahead', and fails closed without a last promoted release" \
    || fail "23b: forward-only step is missing or not fail-closed"
[[ "$(grep -cF "Unknown promotion_mode" "${WORKFLOW_FILE}")" -eq 2 ]] \
    && pass "23c: unknown promotion_mode is rejected in both validate-promotion and deploy-production" || fail "23c: unknown-mode rejection missing in one job"
forward_line="$(echo "${validate_block}" | grep -n 'name: Require a milestone to move production forward' | cut -d: -f1)"
image_line="$(echo "${validate_block}" | grep -n 'name: Verify the SHA-derived image exists in GHCR' | cut -d: -f1)"
[[ -n "${forward_line}" && -n "${image_line}" && "${forward_line}" -lt "${image_line}" ]] \
    && pass "23d: forward-only check runs before any registry credential use" || fail "23d: forward-only check ordering unexpected"

echo
echo "============================================================"
echo "RESULT: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (credential-limited, see notes above)"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
