---
paths:
  - ".on-demand-only/never-match"
---
<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->

# Architecture Principles

Principles for designing mechanisms and how they fit together; the general principles live in core-principles.md.

## ARP-EXBG Exit Before Gate

Give every guard and gate an exit the user can take by explicit approval, in the same change that arms it; never remove that exit to rely on an automated check alone.

## ARP-SLEFT Shift Left

Run each check at the earliest point that can decide it, so a defect surfaces before rework piles up; keep the late gate as the backstop.
