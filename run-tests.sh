#!/bin/bash
# GitStat test runner wrapper for Kira
# Runs Zig unit tests and writes results to .test-results.json

RESULTS_FILE=".test-results.json"

# Run tests with summary to get counts
echo "Running Zig unit tests..."
OUTPUT=$(zig build test --summary all 2>&1)
TEST_EXIT_CODE=$?

# Default values
PASSED=0
FAILED=0

# Parse the summary line: "X/Y tests passed" or "X passed, Y failed"
# Zig 0.15 with --summary all outputs: "192/192 tests passed"
if echo "$OUTPUT" | grep -qE '[0-9]+/[0-9]+ tests passed'; then
    # Extract "X/Y tests passed" format
    COUNTS=$(echo "$OUTPUT" | grep -oE '[0-9]+/[0-9]+ tests passed' | head -1)
    PASSED=$(echo "$COUNTS" | grep -oE '^[0-9]+')
    TOTAL=$(echo "$COUNTS" | grep -oE '/[0-9]+' | tr -d '/')
    FAILED=$((TOTAL - PASSED))
elif echo "$OUTPUT" | grep -qE '[0-9]+ passed'; then
    # Alternative format: "X passed"
    PASSED=$(echo "$OUTPUT" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
    PASSED=${PASSED:-0}
    if echo "$OUTPUT" | grep -qE '[0-9]+ failed'; then
        FAILED=$(echo "$OUTPUT" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | head -1)
    fi
    FAILED=${FAILED:-0}
else
    # Fallback based on exit code
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        PASSED=1
        FAILED=0
    else
        PASSED=0
        FAILED=1
    fi
fi

# Ensure we have numbers
PASSED=${PASSED:-0}
FAILED=${FAILED:-0}
TOTAL=$((PASSED + FAILED))

# Write results
cat > "$RESULTS_FILE" << EOF
{
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL
}
EOF

echo ""
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "All $PASSED tests passed!"
else
    echo "$PASSED passed, $FAILED failed"
    echo "$OUTPUT"
fi

echo ""
echo "Test results written to $RESULTS_FILE"
cat "$RESULTS_FILE"

exit $TEST_EXIT_CODE
