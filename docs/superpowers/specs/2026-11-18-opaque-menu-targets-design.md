# Opaque targets in extension menus

Unchanged uBlock Origin 1.76.4 creates its subscription-link menu using both
`abp:*` and `https://subscribe.adblockplus.org/*`. Current native menu validation
rejects the opaque target and therefore the whole mixed-pattern item. Restore
this extension behavior through native parsing and real native menu filtering.

The user authorized autonomous browser completion and opted out of additional
implementation questions. The implementation choice here is the agent's.

## Approach

Add menu-specific validation and matching alongside the existing native match
pattern class. Retain existing structured target patterns and a separate set of
validated opaque targets in each native menu item. Match either category for a
link or media URL; clearing/updating the targets replaces both categories.

Registering custom schemes in general permission patterns risks changing access
authority and does not solve opaque syntax. A JavaScript shim would bypass native
menu filtering. Neither alternative fits the requested original extension support.

Accept a valid explicit URI scheme plus a nonempty resource pattern with `*`
wildcards. Use Chromium's nonstandard-scheme match-pattern syntax: its delimiter
search rejects `://` anywhere in that form, including a literal nested URL, while
a single-slash resource such as `abp:/folder/*` is valid. This is match-pattern
syntax, not WHATWG opaque-path grammar. Special URL schemes and registered
extension schemes remain ineligible for this fallback. Match canonical scheme and
the URL's serialized resource plus query, excluding fragments, using WebCore's existing literal/asterisk matcher.
Keep question marks literal. Structured/native URL matching remains unchanged.
Do not use this fallback for document patterns, content scripts or host grants.

For a linked image declaring both link and media contexts, either applicable
target must be sufficient. Correct the existing AND behavior for both structured
and opaque targets, preserving the underlying structured URL parser/matcher.

The requested full-browser and arbitrary-extension scope remains active. This
increment does not establish full Chrome URL-pattern equivalence or full uBO
compatibility: native startup and actual network/cosmetic proof still apply.

## Evidence required

A real owned extension must show the pre-fix rejection with normal HTTP targets
as controls. The changed engine must accept the exact mixed uBO patterns, show
and invoke the item on an actual matching link, hide it on unrelated targets,
replace/remove opaque targets on update, and preserve current permission grants.
Malformed targets and opaque document patterns remain rejected. A native menu
probe must verify the actual framework location. Full engine checks remain a gate.
