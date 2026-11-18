# Extension privacy lifecycle integration

Extensions need stable installation priority across disable, update, and relaunch.
Save the installation date in the encrypted account catalog when first installed,
including disabled installs, preserve it on updates and permission changes, and
pass it to the experimental engine before context load when that SPI exists.
Legacy records receive deterministic ordered dates older than dated installs.
Invalid dates recover without granting additional permissions. Duplicate copies
of one revision cannot increase its installation priority.

Ordinary successful native unload must preserve saved extension settings. Native
unload already destroys the privileged message identity and removes injected code;
retain a real extension page in a test and prove it cannot continue native storage
operations. App delegate authorization must reject unloaded contexts. If native
unload throws, clear grants to fail closed and keep the context for retry.

Public engine compatibility gates remain until changed-engine tests and unchanged
full uBlock Origin network and cosmetic behavior are proven. No new release or
claim of general Chrome compatibility is part of this integration branch.
