# Hybrid MCP + Blockchain Oracle Roadmap

This document captures the phased plan for building a decentralized inflation oracle that powers the Inflation Market protocol. The approach blends an MPC-backed off-chain aggregation layer with on-chain consensus and governance.

---

## Vision & Goals

- Deliver tamper-resistant CPI / real-yield data for multiple regions.
- Provide transparency and auditability for every data point shown to users.
- Start lean (manual multi-sig) and scale into a fully decentralized oracle network.
- Keep costs low while still offering Chainlink-level trust guarantees over time.

---

## System Overview

```
Official CPI / Treasury APIs ─┐
Market Instruments (swaps)   ├─> Regional Data Pipelines ─┐
Vendor Feeds (Bloomberg)     ┘                           │
                                                           ▼
                                Off-chain Aggregation Cluster (per region)
                                  • Normalization & validation
                                  • Outlier removal / fusion
                                  • Canonical payload + signature
                                                           ▼
                    ┌───────────────────────────────────────────────────────┐
                    │      MCP Node Operators (≥3 independent parties)      │
                    │  • Fetch canonical payloads                           │
                    │  • Re-sign / attest                                    │
                    │  • Submit on-chain via Decentralized Oracle contract   │
                    └───────────────────────────────────────────────────────┘
                                                           ▼
                        Decentralized Oracle Contract (staking + BFT consensus)
                                                           ▼
                        Inflation Market Protocol (funding calc, UI, analytics)
```

---

## Phased Roadmap

### Phase 0 – Manual Multi-sig (Weeks 0-4)
| Task | Description |
|------|-------------|
| ✅ Establish multi-sig owners | You + 2 trusted partners (2-of-3). |
| ✅ Build CPI fetch script | Pull official CPI from BLS, generate payload. |
| ✅ Manual update runbook | Checklist for monthly CPI release + multi-sig submission. |
| ✅ Instrument analytics | Publish CPI values to dashboard for early trust. |

### Phase 1 – Prototype Decentralized Oracle (Weeks 4-12)
| Task | Description |
|------|-------------|
| 🔄 Implement `DecentralizedCPIOracle` | Staking, BFT consensus, reputation, slashing. |
| 🔄 Stand up 3 MCP nodes | You, partner, DAO member on independent infrastructure. |
| 🔄 Connect funding calculator | Replace manual CPI with contract output. |
| 🔄 Launch transparency dashboard | Show raw reports, consensus value, node reputations. |

### Phase 2 – Multi-Region Expansion (Months 3-6)
| Task | Description |
|------|-------------|
| 📈 Add EU/UK/Japan pipelines | Official sources + market proxies, fallback logic. |
| 📈 Extend on-chain storage | `region`, `metricId` support (headline, core, YoY, etc.). |
| 📈 Increase node diversity | Onboard additional nodes from partners, DAO, institutions. |
| 📈 Launch on Arbitrum testnet | End-to-end rehearsals with full data flow. |

### Phase 3 – Open Participation (6+ Months)
| Task | Description |
|------|-------------|
| 🧭 Permissionless node registry | Allow public operators with staking. |
| 🧭 Token-weighted governance | DAO votes on nodes, parameters, slashing appeals. |
| 🧭 Threshold signatures / MPC | Remove single key reliance, support joint signing. |
| 🧭 External audits & bounty | Contract/code reviews, continuous security incentives. |

---

## Key Components & Deliverables

### 1. Data Pipelines
- Region-specific fetchers (BLS, Eurostat, ONS, FRED, etc.).
- Market fallback: inflation swaps, breakeven yields, treasury spreads.
- Validation checks: schema, timestamp, monotonic moves, outliers.
- Canonical payload format: `{ region, metric, value, timestamp, sources[], rawHash }`.
- Tests & monitoring for data integrity.

### 2. MCP Node Service
- Modular fetch (HTTP/WebSocket/GCP/AWS).
- Signature handling (verify pipeline signature, re-sign output).
- Config-driven (RPC URLs, oracle address, reporting cadence).
- Observability: logs, metrics, alert hooks.
- Deployed via Docker/Kubernetes + IaC.

### 3. Decentralized Oracle Contract
- Node registry with stake + reputation.
- `submitReport(region, metricId, value, dataHash, signature)`.
- Median-based consensus + deviation checks.
- Dynamic reputation updates + stake slashing.
- Per-region/per-epoch storage with confidence scores.
- Events for transparency (reports, consensus, slashing).
- Governance hooks: node onboarding, parameter updates, emergency pause.

### 4. Transparency Dashboard & API
- Live view of all node reports, consensus results.
- Historical charts (CPI vs oracle output, deviations).
- Node reputation, stake, status tables.
- Alerts for stale data, disagreement, slashing events.
- Public REST/GraphQL for external integrators.

### 5. Governance & Security
- Staking levels tied to potential impact.
- Slashing policy (e.g., 1-10% based on deviation).
- Reputation thresholds for eviction / reactivation.
- Insurance fund to accumulate slashed stake.
- Timelocked multi-sig for emergency overrides.
- Annual audits + bug bounty program.

---

## Immediate Next Steps

1. **Create GitHub issues** for each deliverable group (contract, node service, dashboards, governance).  
2. **Draft Phase 0 runbook** (multi-sig monthly updates) and integrate with existing oracle.  
3. **Prototype Decentralized Oracle contract** in a separate branch with unit tests.  
4. **Bootstrap MCP node codebase** (common repo template, CI pipeline).  
5. **Design public dashboard wireframes** for data transparency metrics.  

---

## Resourcing & Milestones

| Milestone | Target Date | Team Required |
|-----------|-------------|---------------|
| Phase 0 go-live | Month 1 | Protocol core team, multi-sig signers |
| Phase 1 dev complete | Month 3 | Smart contract engineer, infra engineer |
| Phase 2 multi-region testnet | Month 6 | Data engineers, oracle operators |
| Phase 3 DAO-controlled network | Month 9+ | Governance, community ops, security auditors |

---

## Appendix: Risk Mitigation

- **Data outages**: multi-source pipelines, fallback to market proxies, manual override path.  
- **Node failure**: require ≥3 active nodes, alerting, quick onboarding process.  
- **Malicious reporting**: staking + slashing, reputation weighting.  
- **Smart contract bugs**: audits, limited control (governance gating), circuit breakers.  
- **Governance capture**: multi-sig thresholds, DAO oversight, transparent voting.  

---

This plan lets us revisit the evolutionary steps—from the current manual oracle to a multi-region, fully decentralized MCP network—once implementation work begins.
