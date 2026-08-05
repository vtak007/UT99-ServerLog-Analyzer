# Accessed None warnings in bbPlayer.Died, ST_UT_Eightball.FireRockets, ST_enforcer.PlaySelect (next-netcode @ ef237853)

**Build:** `InstaGibPlus_next-netcode-ef237853` (next-netcode branch, commit `ef237853`, 2026-07-28)
**Engine:** UT99 v469e (dedicated server)
**Server type:** all-weapons Deathmatch (standard weapon spawns; not instagib mode)

Running the current `next-netcode` tip on a live public DM server, a single session's `server.log` shows three recurring `Accessed None` ScriptWarnings originating in IG+ classes. None crash the server and gameplay proceeds, but they're high-volume noise and each points at a missing null-guard on a reference that can legitimately be `None` during pawn death / weapon-state transitions.

Counts and contexts are from one ~20k-line session (log opened 2026-08-04).

---

## 1. `bbPlayer.Died` — Accessed None `'Weapon'` (41×)

```
ScriptWarning: InstaGibPlus_next-netcode-ef237853.bbPlayer.Died Accessed None 'Weapon'
```

- **41 occurrences** in one session — by far the highest-frequency ScriptWarning (≈55% of all script warnings that session).
- Fired on **DM-Peak** (high kill-rate map).
- `Died()` appears to read the pawn's `Weapon` reference without a `None` check. In all-weapons DM the current weapon can be `None` at the moment of death (e.g. between drop/destroy and death processing).

**Suggested guard:** wrap the `Weapon` dereference in `Died()`:
```unrealscript
if (Weapon != None)
{
    // ... existing weapon-dependent logic ...
}
```

---

## 2. `ST_UT_Eightball.FireRockets.BeginState` — Accessed None `'G'` + assign-through-None (7×)

```
ScriptWarning: ...ST_UT_Eightball.FireRockets.BeginState Accessed None 'G'                (4×)
ScriptWarning: ...ST_UT_Eightball.FireRockets.BeginState Attempt to assign variable through None  (3×)
```

- **7 occurrences**, on **DM-CyberSpace**. New this session.
- In `state FireRockets`, `BeginState()` dereferences (and writes through) a variable `'G'` (looks like a GRI/GameReplicationInfo-type reference) that is `None` at state-entry.
- Likely race: the owning pawn is destroyed / changes state between the state transition being queued and `BeginState()` executing.
- Note: the pinned commit `ef237853` itself is an Eightball change ("Eightball: no lock-on while loading, no seeker without the icon"), so `ST_UT_Eightball` is in active flux — flagging in case this regressed there.

**Suggested guard:** null-check `G` at the top of `BeginState()` before the dereference/assignment.

---

## 3. `ST_enforcer.PlaySelect` — Accessed None `'Owner'` (weapon-swap-at-death chain, 6×)

```
ScriptWarning: Engine.Pawn.ChangedWeapon Accessed None 'Inventory'                 (2×)
ScriptWarning: ...ST_enforcer.PlaySelect Accessed None 'Owner'                       (2×)
ScriptWarning: Engine.Weapon.BringUp Accessed None 'Owner'                           (2×)
```

- **6 occurrences**, on **DM-Revenge**. New this session.
- A weapon-swap sequence (`Pawn.ChangedWeapon` → `Weapon.BringUp` → `ST_enforcer.PlaySelect`) all fire with `Owner`/`Inventory` == `None` — consistent with a player being killed at the exact moment they switch to the Enforcer, so the pawn is partially destroyed while the weapon-select animation code runs.
- The engine `ChangedWeapon`/`BringUp` warnings are downstream; the IG+-side lever is `ST_enforcer.PlaySelect`.

**Suggested guard:** at the top of `ST_enforcer.PlaySelect` (and related state functions):
```unrealscript
if (Owner == None)
    return;
```

---

## Notes

- All three are cosmetic (no crash, no observed gameplay break) but #1 alone is ~55% of ScriptWarning volume, so guarding it would substantially quiet server logs and make real regressions easier to spot.
- Happy to provide the raw log excerpts or a per-signature digest if useful.
