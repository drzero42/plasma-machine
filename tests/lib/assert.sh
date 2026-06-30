#!/usr/bin/env bash
# Minimal assertion helpers for the CEC offline tests.
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" != "$2" ]; then
        echo "FAIL: ${3:-assert_eq}: expected [$2] got [$1]"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}
assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$1" in
        *"$2"*) ;;
        *) echo "FAIL: ${3:-assert_contains}: [$1] missing [$2]"; TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
    esac
}
assert_not_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$1" in
        *"$2"*) echo "FAIL: ${3:-assert_not_contains}: [$1] should not contain [$2]"; TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
        *) ;;
    esac
}
assert_ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! "$@"; then echo "FAIL: command should succeed: $*"; TESTS_FAILED=$((TESTS_FAILED + 1)); fi
}
assert_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then echo "FAIL: command should fail: $*"; TESTS_FAILED=$((TESTS_FAILED + 1)); fi
}
finish() {
    echo "Ran $TESTS_RUN assertions, $TESTS_FAILED failed"
    [ "$TESTS_FAILED" -eq 0 ]
}
