#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Offline regression suite for ci/onion-tester-run.sh. Drives the retry wrapper
## against a mock probe and a mock NEWNYM helper, so the retry POLICY is tested
## without Tor, without network, in seconds.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runner="${test_dir}/onion-tester-run.sh"
work_dir=""
passed=0
failed=0

# shellcheck disable=SC2317  ## reached via the EXIT trap in main()
onion_tester_test_cleanup() {
   if [ -n "${work_dir}" ]; then
      safe-rm --recursive --force -- "${work_dir}"
   fi
}

write_mocks() {
   cat > "${work_dir}/mock-probe" <<'MOCK_PROBE_EOF'
#!/bin/bash

set -o nounset

count=0
if [ -f "${MOCK_STATE}/count" ]; then
   count="$(cat -- "${MOCK_STATE}/count")"
fi
count=$((count + 1))
printf '%s\n' "${count}" > "${MOCK_STATE}/count"
printf '%s\n' "${*}" >> "${MOCK_STATE}/argv.log"

sleep "${MOCK_SLEEP:-0}"

read -r -a mock_results <<< "${MOCK_RESULTS}"
rc="${mock_results[$((count - 1))]:-0}"
if [ "${rc}" -ne 0 ]; then
   printf '%s\n' "FAILED_URL http://mock1example2onion3address4here5padding6to7fiftysix.onion"
fi
exit "${rc}"
MOCK_PROBE_EOF

   cat > "${work_dir}/mock-newnym" <<'MOCK_NEWNYM_EOF'
#!/bin/bash

set -o nounset

printf '%s\n' "newnym" >> "${MOCK_STATE}/newnym.log"
exit "${MOCK_NEWNYM_RC:-0}"
MOCK_NEWNYM_EOF

   chmod +x -- "${work_dir}/mock-probe" "${work_dir}/mock-newnym"
}

reset_state() {
   safe-rm --recursive --force -- "${work_dir}/state"
   mkdir --parents -- "${work_dir}/state"
   touch -- "${work_dir}/state/argv.log" "${work_dir}/state/newnym.log"
}

check() {
   local label expected actual

   label="$1"
   expected="$2"
   actual="$3"

   if [ "${expected}" = "${actual}" ]; then
      passed=$((passed + 1))
      printf '%s\n' "PASS: ${label}"
      return 0
   fi
   failed=$((failed + 1))
   printf '%s\n' "FAIL: ${label}: expected '${expected}', got '${actual}'" >&2
   return 0
}

check_contains() {
   local label needle file

   label="$1"
   needle="$2"
   file="$3"

   if grep --quiet --fixed-strings -- "${needle}" "${file}"; then
      passed=$((passed + 1))
      printf '%s\n' "PASS: ${label}"
      return 0
   fi
   failed=$((failed + 1))
   printf '%s\n' "FAIL: ${label}: '${needle}' not found in output" >&2
   return 0
}

newnym_calls() {
   local count

   count="$(wc --lines < "${work_dir}/state/newnym.log")"
   printf '%s\n' "${count}"
}

## An attempt that cannot possibly finish within the leftover budget must NOT be
## started: `timeout` would reap it and the wrapper would report rc=124, which
## reads as "the probe judged the conf bad" but is only "we ran out of wall
## clock". The last COMPLETED attempt's verdict is the honest answer.
case_budget_floor_not_started() {
   local rc=0

   reset_state
   MOCK_STATE="${work_dir}/state" \
   MOCK_RESULTS="1 1 1" \
   MOCK_SLEEP=6 \
   MOCK_NEWNYM_RC=0 \
   ALLOW_LOCAL=true \
   ONION_TESTER_BIN="${work_dir}/mock-probe" \
   ONION_TESTER_NEWNYM_BIN="${work_dir}/mock-newnym" \
   ONION_TESTER_ATTEMPTS=3 \
   ONION_TESTER_RETRY_SLEEP=0 \
   ONION_TESTER_DEADLINE=8 \
   ONION_TESTER_MIN_ATTEMPT=5 \
   ONION_TESTER_WARMUP_MAX=0 \
      "${runner}" > "${work_dir}/out.log" 2>&1 || rc=$?

   check "budget floor: reports the last completed attempt's verdict, not rc=124" \
      "1" "${rc}"
   check_contains "budget floor: says which attempt the verdict came from" \
      "reporting ITS verdict" "${work_dir}/out.log"
   check "budget floor: the unfundable attempt never ran" \
      "1" "$(cat -- "${work_dir}/state/count")"
}

## A retry through the same Tor client replays that client's cached per-onion
## failure state, so every retry must be preceded by NEWNYM to be an independent
## trial.
case_newnym_between_attempts() {
   local rc=0

   reset_state
   MOCK_STATE="${work_dir}/state" \
   MOCK_RESULTS="1 1 0" \
   MOCK_SLEEP=0 \
   MOCK_NEWNYM_RC=0 \
   ALLOW_LOCAL=true \
   ONION_TESTER_BIN="${work_dir}/mock-probe" \
   ONION_TESTER_NEWNYM_BIN="${work_dir}/mock-newnym" \
   ONION_TESTER_ATTEMPTS=3 \
   ONION_TESTER_RETRY_SLEEP=0 \
   ONION_TESTER_DEADLINE=600 \
   ONION_TESTER_MIN_ATTEMPT=5 \
   ONION_TESTER_WARMUP_MAX=0 \
      "${runner}" > "${work_dir}/out.log" 2>&1 || rc=$?

   check "newnym: converging run exits 0" "0" "${rc}"
   check "newnym: signalled once before every retry" "2" "$(newnym_calls)"
}

## NEWNYM is not optional decoration: without it the following attempt is a
## replay, so its verdict is untrustworthy. A failing control port is an
## infrastructure bug and must surface as one, with its own exit code.
case_newnym_failure_is_fatal() {
   local rc=0

   reset_state
   MOCK_STATE="${work_dir}/state" \
   MOCK_RESULTS="1 0 0" \
   MOCK_SLEEP=0 \
   MOCK_NEWNYM_RC=1 \
   ALLOW_LOCAL=true \
   ONION_TESTER_BIN="${work_dir}/mock-probe" \
   ONION_TESTER_NEWNYM_BIN="${work_dir}/mock-newnym" \
   ONION_TESTER_ATTEMPTS=3 \
   ONION_TESTER_RETRY_SLEEP=0 \
   ONION_TESTER_DEADLINE=600 \
   ONION_TESTER_MIN_ATTEMPT=5 \
   ONION_TESTER_WARMUP_MAX=0 \
      "${runner}" > "${work_dir}/out.log" 2>&1 || rc=$?

   check "newnym failure: distinct harness exit code" "3" "${rc}"
   check "newnym failure: no further attempt ran" \
      "1" "$(cat -- "${work_dir}/state/count")"
}

## Guards the pre-existing behaviour the retry design rests on.
case_first_attempt_pass() {
   local rc=0

   reset_state
   MOCK_STATE="${work_dir}/state" \
   MOCK_RESULTS="0" \
   MOCK_SLEEP=0 \
   MOCK_NEWNYM_RC=0 \
   ALLOW_LOCAL=true \
   ONION_TESTER_BIN="${work_dir}/mock-probe" \
   ONION_TESTER_NEWNYM_BIN="${work_dir}/mock-newnym" \
   ONION_TESTER_ATTEMPTS=3 \
   ONION_TESTER_RETRY_SLEEP=0 \
   ONION_TESTER_DEADLINE=600 \
   ONION_TESTER_MIN_ATTEMPT=5 \
   ONION_TESTER_WARMUP_MAX=0 \
      "${runner}" > "${work_dir}/out.log" 2>&1 || rc=$?

   check "first-attempt pass: exits 0" "0" "${rc}"
   check "first-attempt pass: no NEWNYM burned" "0" "$(newnym_calls)"
}

case_retry_is_targeted() {
   local rc=0 second_argv

   reset_state
   MOCK_STATE="${work_dir}/state" \
   MOCK_RESULTS="1 0" \
   MOCK_SLEEP=0 \
   MOCK_NEWNYM_RC=0 \
   ALLOW_LOCAL=true \
   ONION_TESTER_BIN="${work_dir}/mock-probe" \
   ONION_TESTER_NEWNYM_BIN="${work_dir}/mock-newnym" \
   ONION_TESTER_ATTEMPTS=3 \
   ONION_TESTER_RETRY_SLEEP=0 \
   ONION_TESTER_DEADLINE=600 \
   ONION_TESTER_MIN_ATTEMPT=5 \
   ONION_TESTER_WARMUP_MAX=0 \
      "${runner}" > "${work_dir}/out.log" 2>&1 || rc=$?

   second_argv="$(sed -n '2p' -- "${work_dir}/state/argv.log")"
   check "targeted retry: run converges to 0" "0" "${rc}"
   check "targeted retry: attempt 2 re-probes only the failed URL" \
      "http://mock1example2onion3address4here5padding6to7fiftysix.onion" \
      "${second_argv}"
}

## The warm-up exists because Tor is restarted immediately before the probe runs,
## and "Bootstrapped 100%" does not mean the hidden-service descriptor cache is
## populated. Its verdict must be DISCARDED: a cold first sweep measures descriptor
## fetching, not the conf. Measured with chunk held constant: 178s / 1 OFFLINE cold
## vs 14s / 0 OFFLINE warm.
case_warmup_verdict_discarded() {
   local rc=0 probe_calls

   reset_state
   MOCK_STATE="${work_dir}/state" \
   MOCK_RESULTS="1 0" \
   MOCK_SLEEP=0 \
   MOCK_NEWNYM_RC=0 \
   ALLOW_LOCAL=true \
   ONION_TESTER_BIN="${work_dir}/mock-probe" \
   ONION_TESTER_NEWNYM_BIN="${work_dir}/mock-newnym" \
   ONION_TESTER_ATTEMPTS=1 \
   ONION_TESTER_RETRY_SLEEP=0 \
   ONION_TESTER_DEADLINE=600 \
   ONION_TESTER_MIN_ATTEMPT=5 \
   ONION_TESTER_WARMUP_MAX=60 \
      "${runner}" > "${work_dir}/out.log" 2>&1 || rc=$?

   probe_calls="$(cat -- "${work_dir}/state/count")"
   ## ATTEMPTS=1 on purpose: with retries available the loop would converge to 0
   ## anyway and the assertion would pass with or without a warm-up. With one
   ## measured attempt, exit 0 is only possible if the warm-up absorbed the
   ## failing sweep.
   check "warm-up: failing warm-up does not fail the run" "0" "${rc}"
   check "warm-up: ran before the first measured attempt" "2" "${probe_calls}"
   check "warm-up: no NEWNYM burned on a first-attempt pass" "0" "$(newnym_calls)"
   check_contains "warm-up: labelled as discarded in the log" \
      "verdict DISCARDED" "${work_dir}/out.log"
}

## A warm-up is not a measurement, so it must never consume the budget a measured
## attempt needs. With a budget barely above the floor it is clamped, and an
## attempt still runs and still produces the verdict.
case_warmup_never_starves_attempts() {
   local rc=0 probe_calls

   reset_state
   MOCK_STATE="${work_dir}/state" \
   MOCK_RESULTS="0" \
   MOCK_SLEEP=0 \
   MOCK_NEWNYM_RC=0 \
   ALLOW_LOCAL=true \
   ONION_TESTER_BIN="${work_dir}/mock-probe" \
   ONION_TESTER_NEWNYM_BIN="${work_dir}/mock-newnym" \
   ONION_TESTER_ATTEMPTS=3 \
   ONION_TESTER_RETRY_SLEEP=0 \
   ONION_TESTER_DEADLINE=8 \
   ONION_TESTER_MIN_ATTEMPT=5 \
   ONION_TESTER_WARMUP_MAX=600 \
      "${runner}" > "${work_dir}/out.log" 2>&1 || rc=$?

   probe_calls="$(cat -- "${work_dir}/state/count")"
   check "warm-up clamp: a measured attempt still ran" "0" "${rc}"
   check "warm-up clamp: warm-up did not consume the attempt budget" "2" "${probe_calls}"
}

## Disabling it must actually disable it -- otherwise the retry accounting in every
## other case is silently measuring one extra sweep.
case_warmup_disabled() {
   local rc=0 probe_calls

   reset_state
   MOCK_STATE="${work_dir}/state" \
   MOCK_RESULTS="0" \
   MOCK_SLEEP=0 \
   MOCK_NEWNYM_RC=0 \
   ALLOW_LOCAL=true \
   ONION_TESTER_BIN="${work_dir}/mock-probe" \
   ONION_TESTER_NEWNYM_BIN="${work_dir}/mock-newnym" \
   ONION_TESTER_ATTEMPTS=3 \
   ONION_TESTER_RETRY_SLEEP=0 \
   ONION_TESTER_DEADLINE=600 \
   ONION_TESTER_MIN_ATTEMPT=5 \
   ONION_TESTER_WARMUP_MAX=0 \
      "${runner}" > "${work_dir}/out.log" 2>&1 || rc=$?

   probe_calls="$(cat -- "${work_dir}/state/count")"
   check "warm-up disabled: exits 0" "0" "${rc}"
   check "warm-up disabled: probe called exactly once" "1" "${probe_calls}"
}

main() {
   local total

   work_dir="$(mktemp --directory)"
   trap onion_tester_test_cleanup EXIT
   write_mocks

   case_budget_floor_not_started
   case_newnym_between_attempts
   case_newnym_failure_is_fatal
   case_first_attempt_pass
   case_retry_is_targeted
   case_warmup_verdict_discarded
   case_warmup_never_starves_attempts
   case_warmup_disabled

   total=$((passed + failed))
   printf '%s\n' "onion-tester-run-test: ${total} checks, ${passed} pass, ${failed} fail, 0 skip"
   if [ "${failed}" -ne 0 ]; then
      exit 1
   fi
   exit 0
}

main "${@}"
