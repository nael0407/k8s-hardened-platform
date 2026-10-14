#!/usr/bin/env bash
# ==============================================================================
# Master Automated Verification Suite
# Project: Hardened Kubernetes Platform with eBPF Runtime Security & GitOps
# Author: Natanael
# ==============================================================================

set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k3s-lab.yaml}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

report_pass() {
    local test_name="$1"
    local detail="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo -e "  [${GREEN}✔ PASS${NC}] ${BOLD}${test_name}${NC}"
    echo -e "         ${CYAN}Evidence:${NC} ${detail}"
}

report_fail() {
    local test_name="$1"
    local detail="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  [${RED}✘ FAIL${NC}] ${BOLD}${test_name}${NC}"
    echo -e "         ${YELLOW}Reason:${NC} ${detail}"
}

echo -e "\n${BOLD}${BLUE}====================================================================${NC}"
echo -e "${BOLD}${BLUE}  K8S HARDENED PLATFORM - AUTOMATED END-TO-END SECURITY AUDIT       ${NC}"
echo -e "${BOLD}${BLUE}====================================================================${NC}\n"

echo -e "${YELLOW}Phase A: Network Security (Cilium eBPF Zero-Trust)${NC}"

# Test 1: Frontend to Backend (Allowed)
FRONTEND_STATUS=$(kubectl -n secure-demo exec frontend -- curl -s -o /dev/null -w "%{http_code}" -m 3 http://backend-svc 2>/dev/null || echo "failed")
if [ "$FRONTEND_STATUS" == "200" ]; then
    report_pass "Zero-Trust: Frontend Legitimate Ingress" "HTTP 200 OK from backend-svc"
else
    report_fail "Zero-Trust: Frontend Legitimate Ingress" "Expected HTTP 200, got: $FRONTEND_STATUS"
fi

# Test 2: Attacker to Backend (Dropped)
ATTACKER_DROP=$(kubectl -n secure-demo exec attacker -- curl -s -o /dev/null -m 3 http://backend-svc 2>&1 || true)
if [[ "$ATTACKER_DROP" == *"exit code 28"* ]] || [[ "$ATTACKER_DROP" == *"timed out"* ]] || [[ "$ATTACKER_DROP" == *"Connection timed out"* ]]; then
    report_pass "Zero-Trust: Attacker Lateral Movement Blocked" "eBPF Packet Dropped (curl exit code 28 timeout)"
else
    report_fail "Zero-Trust: Attacker Lateral Movement Blocked" "Attacker traffic was not dropped!"
fi

echo -e "\n${YELLOW}Phase B: Supply Chain Security & Admission Control (Kyverno + Cosign)${NC}"

# Test 3: Privileged Container Denial
PRIV_OUTPUT=$(kubectl apply -f attack-tests/kyverno/01-privileged-pod.yaml 2>&1 || true)
if [[ "$PRIV_OUTPUT" == *"denied the request"* ]] && [[ "$PRIV_OUTPUT" == *"disallow-privileged-containers"* ]]; then
    report_pass "Admission Control: Privileged Pod Denial" "Blocked by Kyverno (disallow-privileged-containers)"
else
    report_fail "Admission Control: Privileged Pod Denial" "Privileged pod was not rejected!"
fi

# Test 4: HostPID Sharing Denial
HOSTPID_OUTPUT=$(kubectl apply -f attack-tests/kyverno/03-hostpid-pod.yaml 2>&1 || true)
if [[ "$HOSTPID_OUTPUT" == *"denied the request"* ]] && [[ "$HOSTPID_OUTPUT" == *"disallow-host-namespaces"* ]]; then
    report_pass "Admission Control: HostPID Namespace Denial" "Blocked by Kyverno (disallow-host-namespaces)"
else
    report_fail "Admission Control: HostPID Namespace Denial" "HostPID pod was not rejected!"
fi

# Test 5: Unsigned Image Rejection
UNSIGNED_OUTPUT=$(kubectl apply -f attack-tests/kyverno/04-unsigned-image-pod.yaml 2>&1 || true)
if [[ "$UNSIGNED_OUTPUT" == *"denied the request"* ]] && [[ "$UNSIGNED_OUTPUT" == *"no signatures found"* ]]; then
    report_pass "Supply Chain: Unsigned Image Admission Rejection" "Blocked by Cosign policy (no signatures found)"
else
    report_fail "Supply Chain: Unsigned Image Admission Rejection" "Unsigned image was not rejected!"
fi

echo -e "\n${YELLOW}Phase C: In-Kernel Runtime Threat Enforcement (Tetragon eBPF)${NC}"

# Test 6: In-Kernel SIGKILL on Token Theft
TOKEN_OUTPUT=$(kubectl -n secure-demo exec attacker -- cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>&1 || true)
if [[ "$TOKEN_OUTPUT" == *"exit code 137"* ]]; then
    report_pass "Runtime Enforcement: ServiceAccount Token Harvesting" "Killed in-kernel by Tetragon SIGKILL (Exit Code 137)"
else
    report_fail "Runtime Enforcement: ServiceAccount Token Harvesting" "Expected exit code 137, got: $TOKEN_OUTPUT"
fi

# Test 7: In-Kernel SIGKILL on Shell Execution
SHELL_OUTPUT=$(kubectl -n secure-demo exec attacker -- /bin/sh -c "echo breached" 2>&1 || true)
if [[ "$SHELL_OUTPUT" == *"exit code 137"* ]]; then
    report_pass "Runtime Enforcement: Unauthorized Interactive Shell Execution" "Killed in-kernel by Tetragon SIGKILL (Exit Code 137)"
else
    report_fail "Runtime Enforcement: Unauthorized Interactive Shell Execution" "Expected exit code 137, got: $SHELL_OUTPUT"
fi

# Test 8: Benign Process Allowed (No False Positives)
WHOAMI_OUTPUT=$(kubectl -n secure-demo exec attacker -- whoami 2>&1 || true)
if [ "$WHOAMI_OUTPUT" == "curl_user" ]; then
    report_pass "Runtime Accuracy: Benign Application Execution" "whoami successfully returned 'curl_user' (Exit Code 0)"
else
    report_fail "Runtime Accuracy: Benign Application Execution" "Benign execution failed: $WHOAMI_OUTPUT"
fi

echo -e "\n${YELLOW}Phase D: GitOps Engine State (Argo CD)${NC}"

# Test 9: Argo CD Application Status
CILIUM_HEALTH=$(kubectl -n argocd get app cilium -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
KYVERNO_HEALTH=$(kubectl -n argocd get app kyverno -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
TETRAGON_HEALTH=$(kubectl -n argocd get app tetragon -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

if [ "$CILIUM_HEALTH" == "Healthy" ] && [ "$KYVERNO_HEALTH" == "Healthy" ] && [ "$TETRAGON_HEALTH" == "Healthy" ]; then
    report_pass "GitOps: Platform Applications Health" "Cilium ($CILIUM_HEALTH), Kyverno ($KYVERNO_HEALTH), Tetragon ($TETRAGON_HEALTH)"
else
    report_fail "GitOps: Platform Applications Health" "Cilium ($CILIUM_HEALTH), Kyverno ($KYVERNO_HEALTH), Tetragon ($TETRAGON_HEALTH)"
fi

echo -e "\n${BOLD}${BLUE}====================================================================${NC}"
echo -e "${BOLD}  AUDIT SUMMARY: ${PASSED_TESTS}/${TOTAL_TESTS} CHECKS PASSED${NC}"
if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "  STATUS: ${GREEN}${BOLD}ALL DEFENSE LAYERS FUNCTIONING PERFECTLY!${NC}"
else
    echo -e "  STATUS: ${RED}${BOLD}$FAILED_TESTS CHECKS FAILED!${NC}"
fi
echo -e "${BOLD}${BLUE}====================================================================${NC}\n"
