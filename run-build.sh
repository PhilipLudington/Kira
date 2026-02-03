#!/bin/bash
# AirTower build wrapper for Kira
# Runs Zig build and writes results to .build-results.json

RESULTS_FILE=".build-results.json"

# Run build and capture output
echo "Building Kira..."
OUTPUT=$(zig build 2>&1)
BUILD_EXIT_CODE=$?

# Count errors and warnings from output
ERRORS=0
WARNINGS=0

if [ $BUILD_EXIT_CODE -ne 0 ]; then
    # Count error lines
    ERRORS=$(echo "$OUTPUT" | grep -c "error:" 2>/dev/null || true)
    if [ -z "$ERRORS" ] || [ "$ERRORS" = "0" ]; then
        ERRORS=1  # At least one error if build failed
    fi
fi

# Count warnings (suppress grep exit code)
WARNINGS=$(echo "$OUTPUT" | grep -c "warning:" 2>/dev/null || true)
if [ -z "$WARNINGS" ]; then
    WARNINGS=0
fi

# Determine success
if [ $BUILD_EXIT_CODE -eq 0 ]; then
    SUCCESS="true"
else
    SUCCESS="false"
fi

# Write results
cat > "$RESULTS_FILE" << EOF
{
  "success": $SUCCESS,
  "errors": $ERRORS,
  "warnings": $WARNINGS
}
EOF

echo ""
if [ $BUILD_EXIT_CODE -eq 0 ]; then
    echo "Build successful!"
else
    echo "Build failed with $ERRORS error(s)"
    echo "$OUTPUT"
fi

echo ""
echo "Build results written to $RESULTS_FILE"
cat "$RESULTS_FILE"

exit $BUILD_EXIT_CODE
