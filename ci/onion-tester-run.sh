#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Run /usr/share/sdwdate/onion-tester with a bounded, targeted retry. The probe
## exits non-zero if even one of ~59 URLs is OFFLINE - a stricter check than
## production sdwdate (which samples 3 random URLs per pool and tolerates some
## misses). Without retry, a single transient Tor circuit timeout fails CI on an
## otherwise-healthy URL set.
##
## Design (why this shape):
##   * Attempt 1 probes the FULL conf. Each later attempt re-probes ONLY the URLs
##     that failed the previous one (the probe prints a 'FAILED_URL <url>' marker
##     per failure, and accepts a URL subset as arguments). A transient per-onion
##     flake thus costs a few-URL re-probe, not a full ~59-URL sweep -- far cheaper,
##     and it converges instead of re-rolling the whole set each time.
##   * A retry is only worth anything if it is an INDEPENDENT trial. Tor keeps
##     per-onion client-side failure state (hidden-service descriptor cache, dead
##     intro points), so re-probing through the same client reproduces the previous
##     verdict for reasons that have nothing to do with the service being up. Each
##     retry is therefore preceded by NEWNYM, which purges that state and forces
##     fresh circuits.
##   * A global WALL-CLOCK DEADLINE bounds the whole loop, and each attempt runs
##     under `timeout` with the remaining budget, so the wrapper always exits
##     cleanly (and records 'attempts') rather than being SIGKILL'd mid-probe by the
##     workflow step timeout (which loses the outputs). deadline < step cap.
##   * An attempt is never STARTED with less budget than one probe cycle needs
##     (a single URL costs up to the probe's 120s primary timeout plus the
##     diagnostic curl HEAD). Launching one anyway just converts "we ran out of
##     wall clock" into rc=124, which reads as a probe verdict but is not one.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

if [ "${CI:-}" != "true" ] && [ "${ALLOW_LOCAL:-}" != "true" ]; then
   printf '%s\n' \
      "${BASH_SOURCE[0]}: refusing to run outside CI. Set ALLOW_LOCAL=true to override." >&2
   exit 1
fi

## CI-tuned probe knobs (the probe keeps its production defaults 3 / 60 for direct
## end-user runs; here we parallelize harder and shorten the diagnostic HEAD so a
## FULL sweep is ~5 min instead of ~13 -- which is what leaves budget for the
## targeted retries below). '[ -v ] ||' respects an explicit override, incl. empty.
[ -v ONION_TESTER_CHUNK ] || ONION_TESTER_CHUNK=20
[ -v ONION_TESTER_HEAD_MAXTIME ] || ONION_TESTER_HEAD_MAXTIME=15
export ONION_TESTER_CHUNK ONION_TESTER_HEAD_MAXTIME

script_dir="$(dirname -- "${BASH_SOURCE[0]}")"

## Overridable so the suite runs from a checkout / against a mock in tests; defaults
## to the installed probe.
onion_tester="${ONION_TESTER_BIN:-/usr/share/sdwdate/onion-tester}"
newnym="${ONION_TESTER_NEWNYM_BIN:-${script_dir}/onion-tester-newnym}"
attempts="${ONION_TESTER_ATTEMPTS:-3}"
## Long enough for Tor's NEWNYM rate limit to clear and for the purged
## descriptor/intro-point state to be re-fetched from a different HSDir set.
inter_attempt_sleep="${ONION_TESTER_RETRY_SLEEP:-60}"
## Wall-clock cap for the whole retry loop. MUST stay below the workflow step's
## timeout-minutes so we self-terminate and still emit outputs. Sized off measured
## CI runs: a full sweep has taken 300-800s, each targeted retry ~150s, plus the
## inter-attempt sleeps (step cap is 24 min; 1200s here leaves margin).
deadline_seconds="${ONION_TESTER_DEADLINE:-1200}"
## Smallest budget an attempt can be launched with and still reach a verdict:
## the probe's per-URL primary timeout is 120s, plus the diagnostic curl HEAD and
## interpreter startup. Below this, `timeout` would reap the probe before it could
## answer, so starting the attempt only manufactures an rc=124.
min_attempt_seconds="${ONION_TESTER_MIN_ATTEMPT:-180}"

main() {
   local start now elapsed remaining attempt rc final_attempt=0 tmp
   local -a probe_args=()

   start="$(date +%s)"
   tmp="$(mktemp)"
   rc=0

   for ((attempt = 1; attempt <= attempts; attempt++)); do
      now="$(date +%s)"
      elapsed=$((now - start))
      remaining=$((deadline_seconds - elapsed))
      if [ "${remaining}" -lt "${min_attempt_seconds}" ]; then
         if [ "${final_attempt}" -eq 0 ]; then
            printf '%s\n' "onion-tester: ${remaining}s left of the ${deadline_seconds}s budget, below the ${min_attempt_seconds}s an attempt needs; no attempt ran, so there is no probe verdict" >&2
            rc=124
         else
            printf '%s\n' "onion-tester: ${remaining}s left of the ${deadline_seconds}s budget, below the ${min_attempt_seconds}s an attempt needs; stopping after attempt ${final_attempt} and reporting ITS verdict (rc=${rc})" >&2
         fi
         break
      fi

      if [ "${#probe_args[@]}" -eq 0 ]; then
         printf '%s\n' "=== onion-tester attempt ${attempt}/${attempts} (full conf; ${remaining}s of budget left) ==="
      else
         printf '%s\n' "=== onion-tester attempt ${attempt}/${attempts} (retry ${#probe_args[@]} failed URL(s); ${remaining}s left) ==="
      fi

      ## Bound the single attempt by the remaining budget; --kill-after reaps curl
      ## stragglers. Capture to ${tmp} to parse FAILED_URL markers, and cat it so the
      ## CI log still shows the full probe output.
      rc=0
      timeout --kill-after=10s "${remaining}s" "${onion_tester}" "${probe_args[@]}" > "${tmp}" 2>&1 || rc=$?
      cat -- "${tmp}"
      final_attempt="${attempt}"

      if [ "${rc}" -eq 0 ]; then
         printf '%s\n' "onion-tester passed on attempt ${attempt}"
         break
      fi
      if [ "${rc}" -eq 124 ]; then
         printf '%s\n' "onion-tester attempt ${attempt} hit the time budget (rc=124); failing fast" >&2
         break
      fi

      ## Narrow the next attempt to just the URLs that failed this one.
      mapfile -t probe_args < <(sed -n 's/^FAILED_URL //p' -- "${tmp}" | sort --unique)
      printf '%s\n' "onion-tester attempt ${attempt} failed (rc=${rc}); ${#probe_args[@]} URL(s) to retry" >&2
      if [ "${#probe_args[@]}" -eq 0 ]; then
         ## Non-zero but no parseable markers (e.g. the probe died before printing):
         ## keep the full set for the next attempt rather than silently narrowing to
         ## nothing (an empty arg list would re-probe the full conf anyway).
         printf '%s\n' "no FAILED_URL markers parsed; next attempt re-probes the full conf" >&2
      fi
      if [ "${attempt}" -lt "${attempts}" ]; then
         ## Stop rather than retry on stale circuits: the control port is set up by
         ## our own onion-tester-configure-tor.sh, so an unreachable one is an
         ## infrastructure bug, and a retry without NEWNYM cannot tell a dead onion
         ## from a cached client-side failure. rc=3 marks a harness failure so it is
         ## not read as a probe verdict.
         if ! "${newnym}"; then
            printf '%s\n' "onion-tester: NEWNYM failed before attempt $((attempt + 1)); a retry on the same circuits would replay Tor's cached per-onion failure state instead of re-testing the service" >&2
            rc=3
            break
         fi
         printf '%s\n' "retrying in ${inter_attempt_sleep}s..." >&2
         sleep "${inter_attempt_sleep}"
      fi
   done

   safe-rm --force -- "${tmp}"

   if [ -n "${GITHUB_OUTPUT:-}" ]; then
      {
         printf 'attempts=%s\n' "${final_attempt}"
         printf 'final_rc=%s\n' "${rc}"
      } >> "${GITHUB_OUTPUT}"
   fi

   exit "${rc}"
}

main "${@}"
