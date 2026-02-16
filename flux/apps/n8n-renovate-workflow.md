# Renovate PR Auto-Merge — n8n Workflow Guide

## Workflow Overview

```
Cron (every 30 min)
  │
  ▼
[1] List PRs ──── STATUS: NONE ──► Stop
  │
  STATUS: FOUND
  │
  ▼
[2] Review PR ─── IMPACT: HIGH ──► [1] List PRs (next PR)
  │
  IMPACT: LOW or MEDIUM
  │
  ▼
[3] Merge PR ─── ACTION: FAILED ──► Stop
  │
  ACTION: MERGED
  │
  ▼
  Wait 60s
  │
  ▼
[4] Flux Health ─── STATUS: HEALTHY ──► [5] K8s Health
  │                                        │
  │                                        ├── HEALTHY ──► [1] List PRs (next PR)
  │                                        │
  │                                        └── UNHEALTHY ──► [6] Revert
  │
  STATUS: UNHEALTHY
  │
  ▼
[6] Revert PR ──► Wait 60s ──► [4] Flux Health ──► Stop
```

## Base URL

```
http://192.168.1.202:8080/api/a2a/kagent
```

## Node Configuration

### Node 1 — Cron Trigger

- **Type:** Schedule Trigger
- **Interval:** Every 30 minutes

---

### Node 2 — List Renovate PRs

**HTTP Request:**
```
POST http://192.168.1.202:8080/api/a2a/kagent/renovate-list-agent/
Content-Type: application/json
```

**Body:**
```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [
        {
          "kind": "text",
          "text": "List open Renovate PRs"
        }
      ]
    }
  }
}
```

**Response parsing (Function node after HTTP):**
```javascript
const response = $input.first().json;
const artifact = response.result.artifacts[0].parts[0].text;
const lines = artifact.split('\n');

const output = {};
for (const line of lines) {
  const match = line.match(/^(\w+):\s*(.+)$/);
  if (match) {
    output[match[1]] = match[2].trim();
  }
}

return [{ json: output }];
```

**Output example:**
```json
{ "STATUS": "FOUND", "PR": "49", "TITLE": "fix(helm): update chart tempo...", "BRANCH": "renovate/tempo-1.x", "LABELS": "renovate/helm,type/patch" }
```

**Route (IF node):**
- `STATUS` equals `FOUND` → Node 3
- `STATUS` equals `NONE` → Stop (No Operation node)

---

### Node 3 — Review PR (review only, no merge)

**HTTP Request:**
```
POST http://192.168.1.202:8080/api/a2a/kagent/renovate-review-agent/
Content-Type: application/json
```

**Body (use expression for PR number):**
```json
{
  "jsonrpc": "2.0",
  "id": "2",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [
        {
          "kind": "text",
          "text": "Review and assess PR {{ $json.PR }}"
        }
      ]
    }
  }
}
```

**Response parsing:**
```javascript
const response = $input.first().json;
const artifact = response.result.artifacts[0].parts[0].text;
const lines = artifact.split('\n');

const output = {};
for (const line of lines) {
  const match = line.match(/^(\w+):\s*(.+)$/);
  if (match) {
    output[match[1]] = match[2].trim();
  }
}

return [{ json: output }];
```

**Output example:**
```json
{ "PR": "49", "IMPACT": "LOW", "REASON": "type/patch label, tempo 1.24.1 to 1.24.4" }
```

**Route (IF node):**
- `IMPACT` equals `LOW` or `MEDIUM` → Node 3b (Merge)
- `IMPACT` equals `HIGH` → Loop back to Node 2 (list next PR)

---

### Node 3b — Merge PR (separate agent, merge only)

**HTTP Request:**
```
POST http://192.168.1.202:8080/api/a2a/kagent/renovate-merge-agent/
Content-Type: application/json
```

**Body (use expression for PR number):**
```json
{
  "jsonrpc": "2.0",
  "id": "2b",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [
        {
          "kind": "text",
          "text": "Merge PR {{ $json.PR }}"
        }
      ]
    }
  }
}
```

**Response parsing:**
```javascript
const response = $input.first().json;
const artifact = response.result.artifacts[0].parts[0].text;
const lines = artifact.split('\n');

const output = {};
for (const line of lines) {
  const match = line.match(/^(\w+):\s*(.+)$/);
  if (match) {
    output[match[1]] = match[2].trim();
  }
}

return [{ json: output }];
```

**Output example:**
```json
{ "PR": "49", "ACTION": "MERGED" }
```

**Route (IF node):**
- `ACTION` equals `MERGED` → Wait 60s → Node 4
- `ACTION` equals `FAILED` → Stop

---

### Node 4 — Wait for Reconciliation

**Type:** Wait
**Duration:** 60 seconds

---

### Node 5 — Flux Health Check

**HTTP Request:**
```
POST http://192.168.1.202:8080/api/a2a/kagent/flux-health-agent/
Content-Type: application/json
```

**Body:**
```json
{
  "jsonrpc": "2.0",
  "id": "3",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [
        {
          "kind": "text",
          "text": "Check Flux reconciliation status"
        }
      ]
    }
  }
}
```

**Response parsing:**
```javascript
const response = $input.first().json;
const artifact = response.result.artifacts[0].parts[0].text;
const lines = artifact.split('\n');

const output = {};
for (const line of lines) {
  const match = line.match(/^(\w+):\s*(.+)$/);
  if (match) {
    output[match[1]] = match[2].trim();
  }
}

// Carry forward the PR number from upstream
output.PR = $('Review PR').first().json.PR;

return [{ json: output }];
```

**Output example:**
```json
{ "STATUS": "HEALTHY", "FLUX_READY": "true", "DETAILS": "113/113 Kustomizations ready, 17/17 HelmReleases ready", "PR": "49" }
```

**Route (IF node):**
- `STATUS` equals `HEALTHY` → Node 6
- `STATUS` equals `UNHEALTHY` → Node 7

---

### Node 6 — K8s Pod Health Check

**HTTP Request:**
```
POST http://192.168.1.202:8080/api/a2a/kagent/k8s-health-agent/
Content-Type: application/json
```

**Body:**
```json
{
  "jsonrpc": "2.0",
  "id": "4",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [
        {
          "kind": "text",
          "text": "Check pod health"
        }
      ]
    }
  }
}
```

**Response parsing:**
```javascript
const response = $input.first().json;
const artifact = response.result.artifacts[0].parts[0].text;
const lines = artifact.split('\n');

const output = {};
for (const line of lines) {
  const match = line.match(/^(\w+):\s*(.+)$/);
  if (match) {
    output[match[1]] = match[2].trim();
  }
}

output.PR = $('Review PR').first().json.PR;

return [{ json: output }];
```

**Route (IF node):**
- `STATUS` equals `HEALTHY` → Loop back to Node 2 (process next PR)
- `STATUS` equals `UNHEALTHY` → Node 7

---

### Node 7 — Revert PR

**HTTP Request:**
```
POST http://192.168.1.202:8080/api/a2a/kagent/renovate-revert-agent/
Content-Type: application/json
```

**Body (use expression for PR number):**
```json
{
  "jsonrpc": "2.0",
  "id": "5",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [
        {
          "kind": "text",
          "text": "Revert PR {{ $json.PR }}"
        }
      ]
    }
  }
}
```

**Response parsing:**
```javascript
const response = $input.first().json;
const artifact = response.result.artifacts[0].parts[0].text;
const lines = artifact.split('\n');

const output = {};
for (const line of lines) {
  const match = line.match(/^(\w+):\s*(.+)$/);
  if (match) {
    output[match[1]] = match[2].trim();
  }
}

return [{ json: output }];
```

**Output example:**
```json
{ "STATUS": "REVERTED", "ORIGINAL_PR": "49", "REVERT_PR": "60", "REASON": "Reverted due to cluster health failure" }
```

**After revert:** Wait 60s → Run Flux Health Check (Node 5) again → Stop

---

## Shared Response Parser

All agents return the same `KEY: value` format. Use this reusable Function node pattern:

```javascript
const response = $input.first().json;
const artifact = response.result.artifacts[0].parts[0].text;
const lines = artifact.split('\n');

const output = {};
for (const line of lines) {
  const match = line.match(/^([\w_]+):\s*(.+)$/);
  if (match) {
    output[match[1]] = match[2].trim();
  }
}

return [{ json: output }];
```

## HTTP Request Settings

Apply to all HTTP Request nodes:

| Setting | Value |
|---------|-------|
| Method | POST |
| URL | `http://192.168.1.202:8080/api/a2a/kagent/{agent-name}/` |
| Content-Type | `application/json` |
| Timeout | `300000` (5 min — agents make LLM + API calls) |
| Retry on Fail | Yes, 1 retry |

## Loop Protection

Add a **Set node** at the start to track iterations:

```javascript
const iteration = ($('Set Counter').first()?.json?.iteration || 0) + 1;

if (iteration > 10) {
  return [{ json: { STATUS: "STOPPED", REASON: "Max 10 PRs per run" } }];
}

return [{ json: { iteration } }];
```

This prevents infinite loops if there are many open PRs.

## Pre-existing Issues

These Kustomizations are currently not Ready and will cause the flux-health-agent to report UNHEALTHY regardless of PR merges:

- `kube-ops/cert-manager-selfsigned` (Unknown)
- `kube-ops/cert-manager-letsencrypt` (False — depends on selfsigned)
- `kube-ops/cert-manager-certificates` (Unknown — depends on letsencrypt)
- `kgateway-system/kgateway-certificate` (False — depends on cert-manager)

**Fix these first** or update the flux-health-agent to exclude known-failing resources, otherwise every merge will trigger a revert.
