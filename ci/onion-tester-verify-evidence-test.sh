#!/bin/bash

## Copyright (C) 2026 - 2026 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## AI-Assisted

## Offline regression test for onion-tester-verify-evidence.sh's temp-file
## handling. Extracts the real fetch_and_grep_hash function and runs it against a
## stubbed curl, so there is no network, no wayback, no Tor and no root.
##
## What it pins:
##   * the scratch file is NOT a predictable path derived from the hash. The old
##     "/tmp/wb-${hash}.html" was computed entirely from conf content, so any other
##     user on the host could pre-create or symlink it before the fetch.
##   * the scratch file is REMOVED on both outcomes. The old early `return 0`
##     leaked one file per verified hash.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

passed=0
failed=0
work_dir=''

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subject="${VERIFY_EVIDENCE_BIN:-${script_dir}/onion-tester-verify-evidence.sh}"

## Invoked indirectly, via the EXIT trap in main().
# shellcheck disable=SC2317
cleanup() {
   [ -z "${work_dir}" ] || safe-rm --recursive --force -- "${work_dir}"
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

## Run the REAL function with a stub curl on PATH. `found` decides whether the
## stub writes a body containing the hash, i.e. the success or the failure path.
run_fetch() {
   local found="$1" hash="$2" tmpdir="$3" rc=0

   cat > "${tmpdir}/curl" <<STUB_EOF
#!/bin/bash
set -o nounset
out=''
prev=''
for arg in "\${@}"; do
   if [ "\${prev}" = '--output' ]; then
      out="\${arg}"
   fi
   prev="\${arg}"
done
printf '%s\n' "\${out}" >> "${tmpdir}/outputs.log"
if [ "${found}" = 'true' ]; then
   printf 'snapshot body containing ${hash} here\n' > "\${out}"
else
   printf 'unrelated calendar html\n' > "\${out}"
fi
exit 0
STUB_EOF
   chmod +x -- "${tmpdir}/curl"

   PATH="${tmpdir}:${PATH}" bash -c '
      set -o errexit
      set -o nounset
      set -o pipefail
      retry_attempts=1
      inter_attempt_sleep=0
      curl_max_time=5
      user_agent=test
      '"$(sed -n '/^fetch_and_grep_hash()/,/^}/p' -- "${subject}")"'
      fetch_and_grep_hash "$1" "$2"
   ' _ "${hash}" 'https://web.archive.org/web/2026/https://example.com/' \
      || rc=$?
   printf '%s\n' "${rc}"
}

## The scratch path the stub was told to write. If it is derivable from the hash,
## it is predictable.
scratch_path() {
   tail -n 1 -- "$1/outputs.log"
}

case_scratch_path_not_predictable() {
   local hash='abcdef0123456789' tmpdir path rc

   tmpdir="${work_dir}/predictable"
   mkdir --parents -- "${tmpdir}"
   rc="$(run_fetch true "${hash}" "${tmpdir}")"
   path="$(scratch_path "${tmpdir}")"

   check "verified hash returns success" "0" "${rc}"
   ## A path containing the hash is derived from conf content, so it is
   ## predictable to anyone who can read the conf and pre-creatable by any other
   ## user on the host. This subsumes checking for one specific literal path.
   case "${path}" in
      *"${hash}"*)
         failed=$((failed + 1))
         printf '%s\n' "FAIL: scratch path still embeds the hash: '${path}'" >&2
         ;;
      *)
         passed=$((passed + 1))
         printf '%s\n' "PASS: scratch path does not embed the hash"
         ;;
   esac
}

case_scratch_removed_on_success() {
   local hash='fedcba9876543210' tmpdir path rc

   tmpdir="${work_dir}/success"
   mkdir --parents -- "${tmpdir}"
   rc="$(run_fetch true "${hash}" "${tmpdir}")"
   path="$(scratch_path "${tmpdir}")"

   check "success path returns 0" "0" "${rc}"
   if [ -e "${path}" ]; then
      failed=$((failed + 1))
      printf '%s\n' "FAIL: scratch file leaked on the success path: '${path}'" >&2
   else
      passed=$((passed + 1))
      printf '%s\n' "PASS: scratch file removed on the success path"
   fi
}

case_scratch_removed_on_failure() {
   local hash='0011223344556677' tmpdir path rc

   tmpdir="${work_dir}/failure"
   mkdir --parents -- "${tmpdir}"
   rc="$(run_fetch false "${hash}" "${tmpdir}")"
   path="$(scratch_path "${tmpdir}")"

   check "unverified hash returns non-zero" "1" "${rc}"
   if [ -e "${path}" ]; then
      failed=$((failed + 1))
      printf '%s\n' "FAIL: scratch file leaked on the failure path: '${path}'" >&2
   else
      passed=$((passed + 1))
      printf '%s\n' "PASS: scratch file removed on the failure path"
   fi
}

main() {
   local total

   if [ ! -f "${subject}" ]; then
      printf '%s\n' "SKIP: ${subject} not found; set VERIFY_EVIDENCE_BIN" >&2
      exit 77
   fi

   work_dir="$(mktemp --directory)"
   trap cleanup EXIT

   case_scratch_path_not_predictable
   case_scratch_removed_on_success
   case_scratch_removed_on_failure

   total=$((passed + failed))
   printf '%s\n' "onion-tester-verify-evidence-test: ${total} checks, ${passed} pass, ${failed} fail, 0 skip"
   if [ "${failed}" -ne 0 ]; then
      exit 1
   fi
   exit 0
}

main "${@}"
