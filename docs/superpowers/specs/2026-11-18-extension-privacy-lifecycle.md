# Extension privacy lifecycle integration

Extensions need stable installation priority across disable, update, and relaunch.
Save the installation date in the encrypted account catalog when first installed,
including disabled installs, preserve it on updates and permission changes, and
pass it to the experimental engine before context load when that SPI exists.
Legacy records receive deterministic ordered dates older than dated installs.
Missing, wrong-type, and out-of-range dates recover without granting additional permissions. Duplicate copies
of one revision cannot increase its installation priority.

Ordinary successful native unload must preserve saved extension settings. Native
unload already destroys the privileged message identity and removes injected code;
retain a real extension page in a test and prove it cannot continue native storage
operations. App delegate authorization must reject unloaded contexts. If native
unload fails with a still-loaded or still-registered context, clear grants to fail
closed and keep the context for retry. An already-unloaded context absent from
the controller represents completed teardown. Preparation must inspect actual
native loaded state and controller ownership, even when the saved catalog matches.
Explicit saved-approval removal must still revoke the old native permission before
unload. Production unload paths intersect native grants with validated current
catalog approvals; this also ends temporary-only rights during shutdown.

Public engine compatibility gates remain until changed-engine tests and unchanged
full uBlock Origin network and cosmetic behavior are proven. No new release or
claim of general Chrome compatibility is part of this integration branch.

Known followup: dates immediately adjacent to distantPast/distantFuture still need
priority-arithmetic normalization. Normal dates, clock rollback, malformed types,
and large out-of-range numbers are covered here.
