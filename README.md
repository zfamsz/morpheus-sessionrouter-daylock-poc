# Independent reproduction — SessionRouter day-lock (Morpheus, Base)

Foundry fork test proving, from the Morpheus-Lumerin-Node source alone, that the
`#830` day-lock in `SessionRouter._rewardUserAfterClose` only holds back the
consumption of the **final UTC day** of a session. Stake that already backed
stipend drawn on earlier UTC days is refunded in the same `closeSession`
transaction and can immediately fund a second full session in the same UTC day,
which draws a fresh stipend from the funding account. Net new capital across
both sessions is zero.

## Shape under test (the gap)

An **early close** of a multi-day session: the session is closed about 2.5 days
into a planned ~5-day session — not late on its final day. This shows the flaw
sits in the lock's anchor itself
(`sessionEnd_ - session.openedAt.max(startOfEndDay_)`, `SessionRouter.sol:306`)
and applies to *any* close spanning more than one UTC day, not only to a
late close on the final day.

## Run

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract SessionDayLockForkTest -vv
```

- Fork: Base mainnet, pinned block `58461106` (post-`#830` live bytecode).
- Read-only against mainnet: a local fork only. No mainnet/testnet transaction,
  no wallet, no exploit.
- Needs `forge` (Foundry) and network access to a Base RPC (the public
  `https://mainnet.base.org` works).

## What the test does

1. One self-dealing actor (consumer **and** provider on its own bid —
   permissionless, no privilege, no admin role) registers a provider
   (10,000 MOR stake), a model (250 MOR stake) and a bid at 3e13 wei/sec.
2. Opens session 1 with **5,000 MOR** (planned length ~5 days, direct
   payment off, so the provider is paid from the funding account).
3. Warps ~2.5 days in and closes the session **early** with a valid
   self-signed receipt. The provider is paid for the elapsed time at close.
4. Measures the hold: only the final-day slice is locked. The lock is
   re-derived independently from the public `stipendToStake` /
   `startOfTheDay` views and matches the on-hold amount (within 0.0003%;
   the residual is the provider payment at close raising
   `providersTotalClaimed` between the two reads).
5. Opens session 2 the **same UTC day** with the refunded stake, warps past
   its end, and claims its stipend from the funding account.

## Measured results (deterministic across runs)

| Quantity | Value |
|---|---|
| Session 1 stake | 5,000 MOR |
| Planned session length | 5 days |
| Closed after | ~2.5 days (early), across 3 UTC days |
| Provider paid at close (funding account) | 6.48 MOR |
| Stake locked on hold after close | 535.88 MOR (10.7%) |
| Stake refunded in the close tx | 4,464.12 MOR (**89.3%**) |
| Second session stipend drawn (funding account) | 13.04 MOR |
| Total drawn from funding account, both sessions | **19.52 MOR on zero net new capital** |
| Total stake still locked after both sessions | 0 MOR (first hold becomes withdrawable the next UTC day) |

Live context (read-only, 19 Nov 2026): funding account
`0x5160c0311a95e0a1072fa85df23712a7ba1cd4b1` holds ~84,907 MOR; daily
compute budget (`getTodaysBudget`) ~30,162 MOR/day. The per-cycle draw is
small; the mechanism repeats every cycle and is bounded by that daily budget.

## Files

- `src/DayLockEarlyCloseForkTest.t.sol` — the reproduction (written from source).
- `src/Interfaces.sol` — minimal diamond interfaces, derived from the
  Morpheus-Lumerin-Node source interfaces.
- `report-draft.md` — one-page report draft in the author's own words.
- `foundry.toml`, `lib/forge-std` (v1.17.0, standard Foundry library).

## Honesty notes

- The same one-line root cause was first published by another researcher
  (Dexanode, 17 Nov 2026) with a different PoC (late close on the final day
  of a 7-day session). This reproduction was written independently from the
  contract source, uses different parameters (5,000 MOR stake, 3e13 wei/sec,
  early close at ~2.5 days) and different assertions, and targets the shape
  that PoC did not cover (early close). Duplicate risk on submission is real
  and acknowledged; the decision to submit anyway is the reporter's, recorded
  separately.
- Severity is argued as **High**, not Critical: measurable over-issuance of
  rewards from the compute pool, bounded by the ~1% daily draw — see
  `report-draft.md`.
