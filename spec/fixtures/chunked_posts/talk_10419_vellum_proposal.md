# \[DIS\] Vellum: Reputation Extension on did:ckb

Link to vote: https://dao.ckb.community/thread/vot-vellum-reputation-extension-on-did-ckb-74299

## Summary

**One-Paragraph Overview**

This proposal requests a grant of $7,000 to strengthen Vellum, the reference dashboard and SDK for `did:ckb`, and extend it from identity into reputation, building and rigorously testing the work on testnet with a real integration into CKBoost.

Deliverables:

* Open, on-chain claim Cell format and SDK additions to `@ckb-ccc/did-ckb`.

* Scoring engine that issues verified social signals against a builder’s DID.

* Public builder reputation dashboard with per-category score breakdown.

* CKBoost integration where quest-completion points feed reputation scoring.

* Governance gating reference plus a mini interactive demo that consumes the primitive to resist Sybil-style manipulation of voting.

* Issuance UI for future ecosystem partners (builders who are actively working on [POAP](https://github.com/RobaireTH/ckb-PoP), [crowdfunding](https://github.com/alesfer001/decentralized-kickstarter), and [gated sub-communities](https://github.com/Victor-Okenwa/mint-gate)).

* Vellum webpage improvements and acquisition of its own domain.

All deliverables ship on testnet.

**Grant Amount Requested:** $7,000 USD equivalent, paid in CKB at the USD value at the time of each disbursement

**ETA to Completion:** 12 weeks from disbursement of initial funding

**CKB Wallet or Funding Address:** `ckb1qyqvhfqtwyjhgeha6qnmcxp4veljkn5ty64qzt7v3l`

---

## Project Introduction

**What problem are we solving.** Reputation is the natural extension of the `did:ckb` identity primitive and a necessary foundation for a wide range of applications, especially governance. CKB’s emerging governance designs need a Sybil-resistant signal to gate eligibility or weight participation, and there is no portable on-chain reputation primitive for them to consult today. The gap is also concrete at the platform layer: CKBoost runs the task and quest infrastructure builders interact with today but has an under-developed identity stack of its own, and the quest-completion points it tracks live in its own database with no portable representation. Builder activity is scattered across CKBoost, hackathons, bounties, and event organizer notes, and none of it is queryable by a governance contract that wants to check whether a participant has genuinely contributed before granting them weight. The result is that any governance program trying to weight by participation has to either build its own private reputation pipeline or fall back to pure token weighting, which is the manipulation surface the whole design is trying to avoid.

**What this addresses.** The Vellum reputation extension attaches a queryable, portable record of ecosystem participation to a builder’s `did:ckb`. CKBoost is the immediate plugin integration target: its quest-completion points become signed claim Cells against the participating builder’s DID, giving CKBoost a richer identity layer and giving Vellum a real source of legitimate participation signals to score against. Verified social handles, on-chain history, event attendance (issued by platforms like [CKB-PoP](https://github.com/Nervos-Community-Catalyst/CKBuilder-projects/issues/1)), and peer recognitions become additional claim Cells signed by their respective issuers and locked to the holder’s DID. Any CKB app can read the full record with one SDK call. Governance is the load-bearing long-term consumer: upcoming CKBuilders programs around [POAP-style eligibility](https://github.com/RobaireTH/ckb-PoP), [crowdfunding](https://github.com/alesfer001/decentralized-kickstarter), and [gated sub-communities](https://github.com/Victor-Okenwa/mint-gate) (all tracked at [Nervos-Community-Catalyst/CKBuilder-projects](https://github.com/Nervos-Community-Catalyst/CKBuilder-projects/issues)) can consume the record to gate access, weight participation, or distribute funds based on demonstrated contribution rather than token balance alone. Other platforms that already track participation (CKB-PoP, future grant DAOs) can become issuers without changing their core products.

### Why now

Three things just lined up:

* The basic `did:ckb` infrastructure is shipping. Vellum v1 is live on testnet and mainnet (claim, edit, rotate, deactivate, resolve, did:plc migrate). The advanced SDK PR (`@ckb-ccc/did-ckb`, PR #376) has been merged by @Hanssen and ships in the next release. The DID stack is at the point where it needs real integration testing to mature, and a reputation extension is the natural next layer.

* CKBoost runs the task and quest infrastructure builders interact with today but has an under-developed identity stack of its own. CKBoost is also on testnet, where Vellum can iterate safely against it. Integrating Vellum as a plugin enhances CKBoost’s identity layer while giving Vellum a real source of participation signals to score against.

* Governance designs are actively being explored in the ecosystem, including upcoming CKBuilders programs that focus on POAP-style eligibility, crowdfunding, and gated sub-communities. These all need a manipulation-resistant input that is not another token balance, and none exists today. Reputation is a prerequisite for any governance design that wants to weight by participation rather than token holdings, and the audit-before-implementation bar makes a testnet-first reputation primitive the responsible path.

---

## Team & Roles

* **Name / Handle:** @truthixify

* **Role:** Solo developer covering smart contracts, SDK, frontend, and design.

* **Experience / Relevant background:** Built Vellum v1 from spec to mainnet. Upstreamed the advanced `did:ckb` operations to `@ckb-ccc/did-ckb` (PR #376, merged by @Hanssen with the note “It’s enjoyable to read your code.”). Previously built Haven, a social identity prototype with a privacy / ZK layer. The transparency-first reputation design in this proposal is informed by what worked and what did not in that prior attempt: stamps and signals are public; privacy is provided through the holder’s right to destroy any record.

* **Why CKB:** The Cell model is uniquely suited to this work. Subject-owned claim Cells with capacity-recovery on destruction give holders sovereignty that EVM-based attestation systems cannot match cleanly. Capacity-as-storage-rent makes the economics of issuer-pays attestations natural rather than a tax. Type-id-derived identifiers give `did:ckb` self-authenticating IDs as a chain primitive, matching the property `did:plc` achieves via SHA-256-of-genesis-op but with the directory replaced by the chain itself.

**Links:**

* GitHub: https://github.com/truthixify

* Vellum repository: https://github.com/truthixify/vellum

* Haven repository (prior work): https://github.com/truthixify/haven

---

## Current Status

* **Vellum v1: live on testnet and mainnet.** Full identity surface is shipping: claim, edit, rotate, deactivate, resolve, and `did:plc` migration. The `services.profile` convention (displayName, avatar, bio inline under a service entry) implemented in both the dashboard and the SDK.

* **SDK upstreamed.** Advanced operations PR https://github.com/ckb-devrel/ccc/pull/376 to `ckb-devrel/ccc` reviewed and merged by @Hanssen. The PR adds resolver, history walk, `did:plc` migration via WIP-02 witness, and full transaction builders, on top of the basic DID operations the CCC team already shipped. Shipping in the next `@ckb-ccc/did-ckb` release.

* **Forum context.** Original Vellum thread: https://talk.nervos.org/t/vellum-a-reference-dashboard-and-sdk-for-did-ckb/10274 . Reputation extension follow-up where this work is laid out in detail: https://talk.nervos.org/t/vellum-extended-from-identity-to-reputation-on-did-ckb/10406 .

* **Live URL:** https://vellum-lyart.vercel.app/

---

## Application Design

This section explains how the system actually functions.

### 6.1 Functional Overview

A builder’s flow through the system:

1. **Claim a `did:ckb`.** Through Vellum’s existing identity flow, the user mints a did:ckb Cell on testnet.

2. **Link social accounts.** GitHub, Discord, Telegram, Bluesky. Each link is verified via an OAuth proof or a post-with-DID proof, then written as a signed claim Cell against the builder’s DID.

3. **Accumulate recognitions.** Platforms that already track participation (CKBoost via successful quests, CKB-PoP via event attendance, future grant DAOs via grant completions) sign claim Cells attesting to what they observed. Each claim is a small on-chain record signed by the issuer’s key.

4. **Be queried.** Any CKB app calls `readClaims(client, { subject: did })` and gets back the full structured record. Governance programs (gated sub-communities, POAP-style eligibility checks, grant programs) consume it to gate access or weight participation against demonstrated activity rather than token holdings alone. Wallets render verified socials. Grant programs check it for Sybil resistance.

5. **Stay in control.** Every claim Cell is locked to the subject. The holder can destroy any Cell they do not want public, recovering the capacity. No claim is unrevocable from the holder’s side.

On-chain vs off-chain: the DID and the claim Cells are on chain. Social-platform OAuth verification, scoring computation, and dashboard rendering are off chain. There is no Vellum database for reputation data; all data lives in Cells.

### 6.2 Architecture & Design

**New on-chain components:**

* **Claim Cell Type Script.** Validates the shape of a claim (issuer DID, subject DID, schema string, DAG-CBOR payload, issuer signature). Subject’s lock script controls destruction.

**New off-chain components:**

* **Scoring engine.** Stateless service that pulls signals from connected social platforms via OAuth and writes signed claim Cells. No database.

* **Public builder profile page (the reputation dashboard).** New Vellum surface at `/profile/<did>` that renders identity, verified socials, on-chain history, issued recognitions, and a reputation score with a per-category breakdown (technical, community, contribution, tenure, recency, etc.) derived from the claim history for any DID.

* **Governance gating reference implementation.** A small reference contract (or off-chain checker, depending on the consuming program’s design) that reads `readClaims` to determine eligibility, derive participation weight from claim history, or both. Ships with documented integration patterns so other governance programs (gated sub-communities, POAP-style eligibility checks, grant programs) can adapt it. Testnet only in this proposal, pending audit.

* **CKBoost plugin integration (testnet).** A working bidirectional integration with CKBoost: Vellum DID becomes the identity layer CKBoost can plug into, and CKBoost-signed quest-completion claims feed the Vellum scoring engine. Co-designed with @Alive24 against CKBoost’s existing testnet deployment.

* **Issuance UI for ecosystem partners.** A simple form-based interface for issuers (CKB-PoP organizers, future grant DAOs, anyone with a credible attestation to make) to issue a claim without integrating the SDK directly. Picks the subject DID, the schema, and the payload; signs and submits.

* **Vellum webpage improvements and own domain.** Polish of the existing Vellum dashboard surface (consolidation of identity and reputation views, navigation, copy) and acquisition of a dedicated domain to replace the current `vellum-lyart.vercel.app` URL.

**SDK additions (planned for `@ckb-ccc/did-ckb`):**

```ts
import { readClaims, writeClaim } from "@ckb-ccc/did-ckb";

const claims = await readClaims(client, { subject: builderDid });

await writeClaim(signer, {

subject: builderDid,

schema: "vellum.task.v1",

payload: { task_id: 42, rating: 5, link: "..." },
});
```

**Key CKB features used:** Cell model (subject-owned claim Cells, capacity-as-storage-rent), Type Script validation, `did:ckb` identifier algorithm (BLAKE2b type-id pattern), Molecule encoding for Cell data, DAG-CBOR for schema payloads, witness-attached `did:plc` migration (already shipping in PR #376).

**External dependencies:** `@ckb-ccc/core`, `@ckb-ccc/did-ckb` (the SDK we are extending), `@ipld/dag-cbor`, `@noble/curves` (already in use), OAuth providers for the social platforms above.

**Open source commitment:** all Type Scripts, SDK additions, scoring engine, and frontend code published under MIT license.

### 6.3 Design Rationale

**On-chain claim Cells, not a Vellum database.** Portability is the point. If Vellum disappears, the data lives, and any other reader can build a new viewer or scorer. Other CKB apps integrate without coordinating with Vellum, by reading claims directly via the SDK.

**Subject-owned Cells.** Self-sovereign reputation. The holder controls every record about them and can destroy any record they no longer wish to retain. Privacy through consent to retain, not consent to view. The Cell model makes this natural; EVM-based attestation systems cannot do this cleanly without off-chain workarounds.

**Schemas as conventions, not contract-enforced types.** New schemas (`ckboost.task.v1`, `ckboost.hackathon.v1`, `ckbpop.attendance.v1`, future ones) do not require a Type Script upgrade. Issuers iterate at the speed of their products. The same convention powers CKBoost integrating tomorrow without forking the spec.

**Issuer-pays storage rent.** Issuers commit capacity for the claims they make, which acts as a natural Sybil deterrent (spam claims cost the issuer real CKB) and aligns with CKB’s design philosophy. Subjects recover capacity when they destroy a Cell.

**Tradeoffs considered.** A simpler design would have Vellum hold all the reputation data in its own database and expose it via API. That is faster to ship but creates the same lock-in problem that the community has flagged with CKBoost. Putting the data on chain costs slightly more in implementation effort but is the only way the “portable” claim is actually true.

**Security:** Type Scripts are small and single-purpose. Initial testing combines internal vetting with public review during the testnet phase. A formal audit is out of scope for this proposal.

**Alignment with CKB’s long-term philosophy:** storage rent (issuers pay for their claims), permissionless innovation (anyone issues, anyone reads), self-sovereignty (holder owns everything about themselves on chain).

### 6.4 Fee model and sustainability

The product does not charge fees. Sustainability comes from three sources:

1. **No per-protocol fee, no token.** The reputation primitive is open infrastructure. Users pay the standard CKB cell creation cost for their DID (refundable on deactivation). Vellum does not capture value from claim issuance or reading.

2. **Issuer-pays storage rent for claims.** Vellum is not on the hook for claim Cell capacity. Issuers (CKBoost, CKB-PoP, future grant DAOs, individual reviewers, others) pay for the claims they make.

3. **Optional premium tiers in future.** Custom profile-page domains, advanced analytics for issuers, branded issuer surfaces. None of these are required, and none are proposed in this grant. The core remains free.

There is no protocol fee, no token, and no capture of value from claim issuance or reading.

---

## Key Benefits for CKB

* **Sybil-resistant governance for emerging CKB community programs.** The reputation primitive gives upcoming governance designs (gated sub-communities, POAP-style eligibility, crowdfunding, grant programs) a portable, queryable signal of genuine ecosystem participation, mitigating wallet-splitting and token-acquisition attacks that pure token-weighted governance is structurally vulnerable to.

* **An open reputation primitive any CKB app can use.** Governance programs read it for eligibility gates and participation weighting. Grant programs read it for Sybil resistance. Wallets render verified socials from it. Platforms write to it to attach signed claims to a builder’s record.

* **Portable identity and reputation that survives any single app.** A builder’s record is theirs, not a platform’s. If CKBoost (or any future platform) goes offline, the builder’s track record persists on chain.

* **Concrete day-one integration with CKBoost.** This grant ships a working testnet integration where CKBoost gains a richer identity layer via `did:ckb` and quest-completion claims feed reputation scoring. The pattern generalises: CKB-PoP can sign attendance for events, future grant DAOs can sign grant-completion claims, all without coordination with Vellum beyond the published schemas.

* **Matures the `did:ckb` stack through real integration testing.** The basic DID operations are shipping; what they need next is exposure to real consumer integration so the rough edges surface. CKBoost integration plus the governance gating reference give the stack two distinct integration patterns to test against on testnet.

* **Developer tooling.** Two new SDK functions (`readClaims`, `writeClaim`) land in `@ckb-ccc/did-ckb`. Any CKB app integrates in roughly 20 lines of code.

---

## Detailed Deliverables & Milestones

### Initial Funding

* **ETA:** Week 0

* **Budget:** $700 USD (10%)

* **Deliverables:**

* Proposal accepted.

* Public roadmap and GitHub project board live.

### Milestone 1: Claim Cell + SDK + Scoring engine

* **ETA:** Q3 2026 (weeks 1-4)

* **Budget:** $2,100 USD (30%)

* **Deliverables:**

* Claim Cell Type Script deployed on CKB testnet at a published address.

* `readClaims` and `writeClaim` PR’d into `@ckb-ccc/did-ckb`.

* Scoring engine issues verified-social claims (GitHub, Discord, Telegram, Bluesky) via OAuth.

* Schema specs documented and published.

### Milestone 2: Builder profile pages + CKBoost integration + webpage polish

* **ETA:** Q3 2026 (weeks 5-8)

* **Budget:** $2,100 USD (30%)

* **Deliverables:**

* Public builder profile page at `/profile/<did>` showing identity, verified socials, ecosystem activity, and a reputation score with per-category breakdown (technical, community, contribution, tenure, recency) derived from the claim history.

* CKBoost integration on testnet: CKBoost-signed quest-completion claims feed the scoring engine and surface in both the score breakdown and the activity feed.

* Vellum webpage improvements (consolidated identity and reputation views, navigation, copy).

### Milestone 3: Governance gating reference + mini demo + issuance UI + own domain

* **ETA:** Q4 2026 (weeks 9-12)

* **Budget:** $2,100 USD (30%)

* **Deliverables:**

* Governance gating reference: a small example contract (or off-chain checker, depending on the consuming program’s design) that reads `readClaims` to determine eligibility, plus documented integration patterns aimed at upcoming CKBuilders programs (gated sub-communities, POAP-style eligibility, crowdfunding).

* Mini interactive demo at `/demo/governance` that wires the reference into a sample vote (paste a DID, see eligibility plus derived participation weight from the claim history, cast a sample vote against a dummy proposal).

* Issuance UI for ecosystem partners (form-based claim issuance for CKB-PoP, future grant DAOs, anyone with a credible attestation to make).

* Acquisition and configuration of a dedicated Vellum domain to replace the current Vercel subdomain.

* Testnet validation pass across all M1-M3 deliverables.

**Acceptance criteria (per milestone):** Each milestone closes only when (a) the named on-chain artifact is deployed at a published address on testnet, (b) the corresponding GitHub PR is merged to the Vellum repository, and (c) a designated reviewer posts an approval comment on the proposal thread. Reviewer designations will be confirmed during the discussion phase.

The scope is deliberately concentrated. Cross-chain export, formal audits, and ZK proof-of-personhood integrations are flagged in section 10 as out of scope to keep this proposal focused and credible.

---

## Budget Breakdown

The $7,000 USD equivalent funds 12 weeks of solo developer work focused on shipping a testnet reputation primitive with CKBoost integration, plus polish of the Vellum webpage and acquisition of its own domain. The categories below mirror the CFDAO template structure.

**Development costs: $6,000**

* Smart contracts / Type Scripts (Claim Cell Type Script): \~$2,000.

* SDK additions to `@ckb-ccc/did-ckb` (`readClaims`, `writeClaim`, helpers, tests): \~$1,000.

* Off-chain scoring engine (OAuth integrations for GitHub, Discord, Telegram, Bluesky; signal pullers, schema writers, tests): \~$1,500.

* Frontend (Vellum reputation dashboard, builder profile pages, governance gating reference and mini demo, issuance UI for ecosystem partners, Vellum webpage improvements): \~$1,500.

**Security audit: $0**

* No formal third-party audit in this proposal. Type Scripts are small and single-purpose; initial deployment uses internal testing plus public community review during the testnet phase.

**Infrastructure / hosting: $500**

* OAuth proxy hosting, Vellum dashboard and public profile-page hosting, dedicated domain acquisition and DNS for Vellum’s own URL.

* On-chain Cell capacity for new claims is paid by issuers per claim and is negligible per update.

**Project management:** absorbed in development.

* Solo developer; PM overhead minimal and absorbed into development time.

**Documentation & community engagement: $500**

* Schema spec publishing, integration guides, forum engagement during the build period.

**Total: $7,000**

**Out-of-budget items** (full list in section 10): formal security audit, paid marketing or BD outreach, long-term maintenance beyond 6 months post-M3, and specialized infrastructure beyond standard hosting. If the Nervos Community Catalyst offers to cover webhosting, domain, or IPFS storage as it did for CKBoost, that is welcomed but not assumed in this ask.

---

## Out-of-Scope / Future Funding Needs

The following are deliberately out of scope for this grant:

* **Formal security audit and mainnet promotion of the new Type Scripts.** The reputation primitive (Claim Cell Type Script) ships on testnet only in this proposal.

* **Long-term maintenance beyond 6 months** post-disbursement of M3 (see section 11 for the maintenance commitment in this grant).

* **Vellum DID as a sign-in identity provider for CKBoost (full Level-3 integration).** This proposal commits to integration where CKBoost signs quest-completion claims and Vellum profile pages render CKBoost activity. Full sign-in replacement, where users authenticate to CKBoost with `did:ckb` instead of CKBoost’s native identity, is out of scope.

* **Cross-chain reputation export** to Ethereum, Polygon, or other chains. The claim format is open, so this remains technically possible, but it is out of scope for this proposal.

* **ZK proof-of-personhood integration** (wrapping Human Passport, World ID, or building a CKB-native equivalent).

* **Paid marketing or BD outreach.** Other CKB platforms can integrate via documented schema conventions; no paid outreach is budgeted.

---

## Risk & Mitigation

* **Technical complexity of the Claim Cell Type Script.** The Type Script is small, single-purpose, and follows patterns already shipping in `@ckb-ccc/did-ckb`. The main implementation risks are getting the CKBoost integration reliable end-to-end and getting the off-chain scoring engine stable across multiple OAuth providers; mitigated by close design review at the milestone boundaries.

* **Adoption risk: will governance programs and other CKB apps integrate?** The governance gating reference implementation ships with the grant and demonstrates the consumer pattern end-to-end. CKBoost and CKB-PoP are flagged issuer paths whose stated open questions the extension addresses. Adoption beyond the deliverables in this proposal is upside, not a requirement for delivery.

* **Solo developer execution risk.** Track record exists: Vellum v1 already shipped on mainnet and testnet, and PR #376 was reviewed and merged by a CCC maintainer. The 12-week scope is conservative given an existing codebase as foundation.

* **Sybil farming of social claims.** OAuth-verified social signals require real platform accounts; combining signals across multiple platforms raises the cost of farming. Reputation is informational input to human reviewers, not financially load-bearing, so adversarial pressure is bounded. Hardening (proof-of-personhood, decay weights) is out of scope for this proposal.

* **CKB price volatility affecting the budget.** Grant amount is requested as a USD equivalent. The CKB amount for each disbursement is calculated at pay time using the then-current price, so CKB price movement between proposal posting and any milestone disbursement does not affect the USD value the project receives.

* **Community adoption depends on reviewer engagement.** Reviewer designations will be confirmed during the discussion phase before voting begins. Public reviewer acknowledgement has held in prior approved proposals.

**Maintenance commitment in this grant:** Vellum’s existing identity dashboard on mainnet continues to be maintained as it has been. The reputation extension built in this grant will be maintained on testnet for at least 6 months following M3 disbursement, with best-effort upkeep beyond that period. SDK additions to `@ckb-ccc/did-ckb` will be kept current with major upstream `@ckb-ccc/core` releases on a best-effort basis.

---

## Closing / Call to Action

Vellum’s identity layer is shipping on mainnet. This proposal funds the next chapter on testnet: making `did:ckb` genuinely useful by attaching portable, self-sovereign reputation to it, with CKBoost as the day-one plugin integration partner, governance as the load-bearing reference consumer, and an open standard any other CKB app can plug into as either an issuer or a reader.

We appreciate your consideration. Feedback, questions, and integration interest from other CKB platforms are welcome in the discussion below.

---

## Supporting Links

* **Vellum repository:** https://github.com/truthixify/vellum

* **Vellum live (testnet and mainnet):** https://vellum-lyart.vercel.app/

* **Original Vellum forum thread:** https://talk.nervos.org/t/vellum-a-reference-dashboard-and-sdk-for-did-ckb/10274

* **Reputation extension forum post:** https://talk.nervos.org/t/vellum-extended-from-identity-to-reputation-on-did-ckb/10406

* **SDK PR** #376 **(merged by @Hanssen, ships in next release):** https://github.com/ckb-devrel/ccc/pull/376

* **Haven repository (prior social identity work, referenced as background):** https://github.com/truthixify/haven

* **CKB-PoP (POAP, integration partner):** https://github.com/RobaireTH/ckb-PoP

* **CKB Kickstarter (crowdfunding):** https://github.com/alesfer001/decentralized-kickstarter

* **Mint Gate (gated sub-communities):** https://github.com/Victor-Okenwa/mint-gate

* **Upcoming CKBuilders programs (full tracker):** https://github.com/Nervos-Community-Catalyst/CKBuilder-projects/issues

* **CKBoost proposal (precedent comparable):** https://talk.nervos.org/t/dis-ckboost-gamified-community-engagement-platform-proposal/8832

* **CFDAO rules and process:** https://talk.nervos.org/t/ckb-community-fund-dao-rules-and-process/6874