# SessionRouter day-lock covers only the final UTC day — early close of a multi-day session releases already-drawn stake for same-day reuse

**Severity: High** — measurable over-issuance of MOR stipends from the Compute
pool. Not Critical: no user funds are taken, nothing is locked up, and the
extraction is bounded by design at ~1% of the compute balance per day
(~30,162 MOR/day at the time of writing) against a finite funding account
(~84,907 MOR). The per-cycle amounts are small, but the mechanism repeats
every cycle with zero net new capital, letting one stake capture a share of
the daily budget ahead of honest consumers.

**Affected:** SessionRouter facet, reached through the Inference Diamond on
Base (`0x6aBE1d282f72B474E54527D93b979A4f64d3030a`). Function
`_rewardUserAfterClose`, `contracts/diamond/facets/SessionRouter.sol:306`
(Morpheus-Lumerin-Node). No privileged role is needed: the whole flow is a
single ordinary user self-dealing as consumer and provider on its own bid.

## Root cause

The July 2026 stipend-recycle fix (PR #830) holds back used stake in
`userStakesOnHold` until the next UTC day — but it measures the hold from the
wrong anchor. At close it computes

```
sessionEnd_ = min(closedAt, endsAt)
startOfEndDay_ = startOfTheDay(sessionEnd_)
userDuration_ = sessionEnd_ - max(openedAt, startOfEndDay_)
```

so the hold only covers consumption inside the UTC day in which the session
stopped. Consumption on every earlier UTC day was already paid out as
provider reward, yet the stake that backed it is handed back in the same
`closeSession` transaction. The invariant that breaks: *stake whose stipend
was already drawn must stay locked until the next UTC boundary*. The fix
enforces it for one day only — the last one. This holds for any close
spanning more than one UTC day, not only for a close late on the final day.

## Attack (early close)

1. Register as provider and model, post a bid, open a session with stake S
   (direct payment off, so the provider is paid from the funding account).
2. Let the session run across several UTC days, then close it **early**,
   mid-session, with a valid provider receipt. The provider is paid for the
   elapsed time at close.
3. `closeSession` refunds almost all of S immediately; only the final-day
   slice is held. Open a second full session the same UTC day with the refund.
4. After the second session ends, `claimForProvider` draws its full stipend
   from the funding account. Repeat every cycle.

## Measured impact (Foundry fork, Base block 58461106, live bytecode)

Session 1: 5,000 MOR stake, planned 5 days at 3e13 wei/sec, closed ~2.5 days
in across 3 UTC days. Provider paid **6.48 MOR** at close from the funding
account. Only **535.88 MOR (10.7%)** was held; **4,464.12 MOR (89.3%)** was
refunded in the close transaction — independently re-derived from the public
`stipendToStake`/`startOfTheDay` views, confirming the hold equals the
final-day slice alone. The refund funded session 2 the same UTC day, which
drew a further **13.04 MOR**. Total drawn from the funding account across
both sessions: **19.52 MOR (~$14 at $0.72/MOR) on zero net new capital**,
and after both sessions **0 MOR** remained locked (the first hold becomes
withdrawable the next UTC day). The cycle repeats indefinitely; the ceiling
is the daily compute budget, not the attacker's capital.

## Suggested fix

Hold back the stake-equivalent of the **whole elapsed consumption**, not just
the final-day slice: compute the lock from `sessionEnd_ - openedAt` instead
of `sessionEnd_ - max(openedAt, startOfEndDay_)`, keeping the same
`releaseAt` (start of the next UTC day). Equivalently, track consumption per
UTC day and hold each day's slice until its own epoch closes. The unused
portion of the stake (backing time never consumed) should still refund
immediately — only drawn stipend's backing stays held.

## Proof of concept

Foundry fork test (interfaces only, no target-repo compilation), pinned
block 58461106: `forge test --match-contract SessionDayLockForkTest -vv`
with `BASE_RPC_URL=https://mainnet.base.org`. Single test
`test_earlyCloseReleasesPriorDaysStake`, PASS; all figures above are its
logged output. PoC repo/gist to be attached on submission.

## Appendix A — addresses (Base)

- Inference Diamond: `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- MOR (MOROFT): `0x7431aDa8a591C955a994a21710752EF9b882b8e3`
- Funding account: `0x5160c0311a95e0a1072fa85df23712a7ba1cd4b1`
- SessionRouter facet: `0x3a3952f0E57b343F00b31F7dA039eF16389B7260`
