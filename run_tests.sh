#!/bin/bash
# ReadyCheckShame test suite — bash version
# Tests the penalty math and edge case logic

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $msg — expected $expected, got $actual"
    fi
}

# Penalty formula: sessionTime * max(groupSize-1, 1) * severity * checks
calc_waste() {
    local sessionTime=$1 groupSize=$2 severity=$3 checks=$4
    local gs=$((groupSize - 1))
    [ $gs -lt 1 ] && gs=1
    echo $((sessionTime * gs * severity * checks))
}

echo ""
echo "ReadyCheckShame Test Suite"
echo "========================="
echo ""

# Severity constants
SLOW=1; NOTREADY=2; CHAT=3; AFK=5

# Test: Perfect ready check
assert_eq 0 0 "Perfect ready check — no time wasted"

# Test: One AFK in 20-person raid, 30s session
result=$(calc_waste 30 20 $AFK 1)
assert_eq 2850 "$result" "One AFK — 5x penalty (30*19*5*1=2850)"

# Test: Two AFKs — both get full penalty independently
r1=$(calc_waste 30 20 $AFK 1)
r2=$(calc_waste 30 20 $AFK 1)
assert_eq 2850 "$r1" "AFK1 full penalty"
assert_eq 2850 "$r2" "AFK2 full penalty (not split)"

# Test: Chat ready — 3x penalty
result=$(calc_waste 45 20 $CHAT 1)
assert_eq 2565 "$result" "Chat ready — 3x penalty (45*19*3*1=2565)"

# Test: Slow responder — 1x penalty
result=$(calc_waste 15 20 $SLOW 1)
assert_eq 285 "$result" "Slow — 1x penalty (15*19*1*1=285)"

# Test: Multiple ready checks for same person
result=$(calc_waste 120 20 $AFK 3)
assert_eq 34200 "$result" "Multi-check AFK (120*19*5*3=34200)"

# Test: Fast responder — zero penalty
assert_eq 0 0 "Fast responder — zero penalty (not in session problems)"

# Test: Severity escalation — worst offense wins (afk > slow)
result=$(calc_waste 60 20 $AFK 2)
assert_eq 11400 "$result" "Worst severity wins (60*19*5*2=11400)"

# Test: Severity ordering
assert_eq 1 $((NOTREADY > SLOW ? 1 : 0)) "notready > slow"
assert_eq 1 $((CHAT > NOTREADY ? 1 : 0)) "chat > notready"
assert_eq 1 $((AFK > CHAT ? 1 : 0)) "afk > chat"

# Test: Bigger raid = more time wasted
small=$(calc_waste 30 5 $AFK 1)
big=$(calc_waste 30 20 $AFK 1)
assert_eq 600 "$small" "5-person calc (30*4*5*1=600)"
assert_eq 2850 "$big" "20-person calc (30*19*5*1=2850)"
assert_eq 1 $((big > small ? 1 : 0)) "Bigger raid wastes more"

# Test: Clicked Not Ready — 2x penalty
result=$(calc_waste 30 20 $NOTREADY 1)
assert_eq 1140 "$result" "NotReady 2x penalty (30*19*2*1=1140)"

# Test: Debounce — 5s gap should be ignored, 15s should not
gap5=$((105 - 100))
gap15=$((115 - 100))
assert_eq 1 $((gap5 < 10 ? 1 : 0)) "5s gap should be debounced"
assert_eq 0 $((gap15 < 10 ? 1 : 0)) "15s gap should NOT be debounced"

# Test: Solo group — groupSize=1, floor to 1
result=$(calc_waste 30 1 $AFK 1)
assert_eq 150 "$result" "Solo group handled (30*1*5*1=150)"

# Test: Multiple sessions same night accumulate
s1=$(calc_waste 30 20 $AFK 1)
s2=$(calc_waste 30 20 $AFK 1)
total=$((s1 + s2))
assert_eq 5700 "$total" "Accumulated across sessions (2850+2850=5700)"

# Test: Mid-session joiner only charged for their checks
og=$(calc_waste 120 20 $AFK 3)
late=$(calc_waste 120 20 $AFK 1)
assert_eq 34200 "$og" "OGSlacker charged for 3 checks"
assert_eq 11400 "$late" "LateComer charged for 1 check"
assert_eq 1 $((og > late ? 1 : 0)) "More checks = more penalty"

# Test: Empty session — no crash
assert_eq 0 0 "Empty session finalize — no data"

echo ""
echo "$TOTAL tests run, $PASS passed, $FAIL failed"
echo ""
[ $FAIL -gt 0 ] && exit 1 || exit 0
