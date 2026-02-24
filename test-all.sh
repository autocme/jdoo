#!/bin/bash
# =============================================================================
# jdoo - Automated Test Suite
# =============================================================================
# Usage: chmod +x test-all.sh && ./test-all.sh
# =============================================================================

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

# Load .env if exists
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

PROJECT="${COMPOSE_PROJECT_NAME:-jdoo}"
ODOO_VER="${ODOO_VERSION:-19.0}"
CONTAINER_APP="${PROJECT}-app"
CONTAINER_DB="${PROJECT}-db"

# Helpers
header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================${NC}"
}

test_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
}

test_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
}

test_start() {
    echo -e "  ${YELLOW}[TEST]${NC} $1"
}

# =============================================================================
# Test 1: Container Status
# =============================================================================
header "Test 1: Container Status"

test_start "Checking if ${CONTAINER_APP} is running..."
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_APP}$"; then
    test_pass "${CONTAINER_APP} is running"
else
    test_fail "${CONTAINER_APP} is NOT running"
fi

test_start "Checking if ${CONTAINER_DB} is running..."
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_DB}$"; then
    test_pass "${CONTAINER_DB} is running"
else
    test_fail "${CONTAINER_DB} is NOT running"
fi

# =============================================================================
# Test 2: Odoo Version Detection
# =============================================================================
header "Test 2: Odoo Version"

test_start "Checking Odoo version matches ${ODOO_VER}..."
DETECTED_VER=$(docker exec "${CONTAINER_APP}" printenv ODOO_VERSION 2>/dev/null || echo "")
if [ "$DETECTED_VER" = "$ODOO_VER" ]; then
    test_pass "Odoo version: ${DETECTED_VER}"
else
    test_fail "Expected ${ODOO_VER}, got: ${DETECTED_VER}"
fi

test_start "Checking Python version..."
PY_VER=$(docker exec "${CONTAINER_APP}" python --version 2>&1 || echo "")
if [ -n "$PY_VER" ]; then
    test_pass "Python: ${PY_VER}"
else
    test_fail "Could not detect Python version"
fi

# =============================================================================
# Test 3: Entrypoint Logs
# =============================================================================
header "Test 3: Entrypoint Initialization"

test_start "Checking entrypoint logs..."
LOGS=$(docker logs "${CONTAINER_APP}" 2>&1 | head -50)

if echo "$LOGS" | grep -q "jdoo"; then
    test_pass "jdoo entrypoint executed"
else
    test_fail "jdoo entrypoint NOT found in logs"
fi

if echo "$LOGS" | grep -q "Configuration file generated successfully"; then
    test_pass "Configuration generated"
else
    test_fail "Configuration generation not detected"
fi

if echo "$LOGS" | grep -q "User permissions configured"; then
    test_pass "User permissions configured"
else
    test_fail "User permissions not configured"
fi

# =============================================================================
# Test 4: Configuration File
# =============================================================================
header "Test 4: Configuration"

test_start "Checking erp.conf exists..."
if docker exec "${CONTAINER_APP}" test -f /etc/odoo/erp.conf; then
    test_pass "erp.conf exists"
else
    test_fail "erp.conf NOT found"
fi

test_start "Checking addons_path in config..."
ADDONS_PATH=$(docker exec "${CONTAINER_APP}" grep "addons_path" /etc/odoo/erp.conf 2>/dev/null || echo "")
if [ -n "$ADDONS_PATH" ]; then
    test_pass "addons_path configured: ${ADDONS_PATH}"
else
    test_fail "addons_path NOT configured"
fi

# Odoo 17+ should use gevent_port, not longpolling_port
MAJOR=$(echo "${ODOO_VER}" | cut -d. -f1)
if [ "$MAJOR" -ge 17 ]; then
    test_start "Checking gevent_port mapping (Odoo ${ODOO_VER})..."
    if docker exec "${CONTAINER_APP}" grep -q "gevent_port" /etc/odoo/erp.conf 2>/dev/null; then
        test_pass "longpolling_port correctly mapped to gevent_port"
    else
        test_fail "gevent_port mapping not found"
    fi
fi

# =============================================================================
# Test 5: Database Connection
# =============================================================================
header "Test 5: Database Connection"

test_start "Checking PostgreSQL connectivity..."
if docker exec "${CONTAINER_DB}" pg_isready -U "${POSTGRES_USER:-odoo}" -d postgres &>/dev/null; then
    test_pass "PostgreSQL is accepting connections"
else
    test_fail "PostgreSQL is NOT accepting connections"
fi

PG_VER=$(docker exec "${CONTAINER_DB}" postgres --version 2>/dev/null | head -1 || echo "")
test_start "PostgreSQL version..."
if [ -n "$PG_VER" ]; then
    test_pass "${PG_VER}"
else
    test_fail "Could not detect PostgreSQL version"
fi

# =============================================================================
# Test 6: Healthcheck
# =============================================================================
header "Test 6: Healthcheck"

test_start "Checking container health status..."
HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_APP}" 2>/dev/null || echo "unknown")
if [ "$HEALTH" = "healthy" ]; then
    test_pass "Container is healthy"
elif [ "$HEALTH" = "starting" ]; then
    test_pass "Container is starting (healthcheck in progress)"
else
    test_fail "Container health: ${HEALTH}"
fi

test_start "Testing HTTP endpoint..."
HTTP_CODE=$(docker exec "${CONTAINER_APP}" curl -s -o /dev/null -w '%{http_code}' http://localhost:8069/web/login 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "303" ]; then
    test_pass "HTTP endpoint responding (${HTTP_CODE})"
else
    test_fail "HTTP endpoint returned: ${HTTP_CODE}"
fi

# =============================================================================
# Test 7: File Permissions
# =============================================================================
header "Test 7: File Permissions"

test_start "Checking odoo user UID/GID..."
CONTAINER_UID=$(docker exec "${CONTAINER_APP}" id -u odoo 2>/dev/null || echo "")
CONTAINER_GID=$(docker exec "${CONTAINER_APP}" id -g odoo 2>/dev/null || echo "")
EXPECTED_UID="${PUID:-1000}"
EXPECTED_GID="${PGID:-1000}"

if [ "$CONTAINER_UID" = "$EXPECTED_UID" ]; then
    test_pass "UID matches: ${CONTAINER_UID}"
else
    test_fail "UID expected ${EXPECTED_UID}, got ${CONTAINER_UID}"
fi

if [ "$CONTAINER_GID" = "$EXPECTED_GID" ]; then
    test_pass "GID matches: ${CONTAINER_GID}"
else
    test_fail "GID expected ${EXPECTED_GID}, got ${CONTAINER_GID}"
fi

test_start "Checking data directory ownership..."
OWNER=$(docker exec "${CONTAINER_APP}" stat -c '%U:%G' /var/lib/odoo 2>/dev/null || echo "")
if [ "$OWNER" = "odoo:odoo" ]; then
    test_pass "Data directory owned by odoo:odoo"
else
    test_fail "Data directory owned by: ${OWNER}"
fi

# =============================================================================
# Test 8: Volumes
# =============================================================================
header "Test 8: Docker Volumes"

test_start "Checking db-data volume..."
if docker volume ls --format '{{.Name}}' | grep -q "${PROJECT}.*db-data"; then
    test_pass "Database volume exists"
else
    test_fail "Database volume NOT found"
fi

test_start "Checking odoo-data volume..."
if docker volume ls --format '{{.Name}}' | grep -q "${PROJECT}.*odoo-data"; then
    test_pass "Odoo data volume exists"
else
    test_fail "Odoo data volume NOT found"
fi

# =============================================================================
# Test 9: Extra Addons Directory
# =============================================================================
header "Test 9: Extra Addons"

test_start "Checking extra-addons mount..."
if docker exec "${CONTAINER_APP}" test -d /mnt/extra-addons; then
    test_pass "Extra addons directory mounted"
else
    test_fail "Extra addons directory NOT mounted"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
header "Test Summary"
TOTAL=$((PASSED + FAILED))
echo -e "  Odoo Version: ${ODOO_VER}"
echo -e "  Total:  ${TOTAL}"
echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
echo -e "  ${RED}Failed: ${FAILED}${NC}"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "  ${RED}Some tests failed.${NC}"
    exit 1
fi
