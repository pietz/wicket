#!/bin/zsh
# Definition of done: build with warnings as errors, run the tests, lint formatting.
#   Scripts/check.sh
# Fix formatting with: swift format format --in-place --recursive Sources Tests Package.swift
set -uo pipefail
cd "${0:A:h}/.."

failed=()
step() {  # $1 label, rest: command
  local label=$1; shift
  echo "== $label"
  "$@" || failed+=("$label")
}

step build swift build --build-tests -Xswiftc -warnings-as-errors
step test swift test --skip-build
step format swift format lint --strict --recursive Sources Tests Package.swift

if (( ${#failed} )); then
  echo "check: FAILED (${(j:, :)failed})"
  exit 1
fi
echo "check: OK (build, test, format)"
