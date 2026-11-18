# Installation priority recovery at date boundaries

The lifecycle review identified that arithmetic on valid dates immediately inside
Foundation's distantPast/distantFuture can generate an invalid priority. A new
install can then be repaired as an older legacy entry. Missing legacy dates can
also drift on every repair.

Preserve relative installation priority, including equal-date ties, and all
approvals. Normalize the dated cohort to safe dates only when a boundary would
leave insufficient room for legacy migration or the next installation. Missing,
wrong-type and invalid dates remain older legacy entries in catalog order.
Ordinary dates and original installation dates must remain unchanged.

Allocation of a new installation date may normalize the current catalog first.
The final commit persists that normalized catalog and the new date together.
Out-of-range or nonfinite supplied clocks must not create invalid metadata.

Approaches: saturating one date loses strict precedence, and adding another rank
field expands the schema unnecessarily. Order-preserving cohort normalization
uses the existing optional encrypted field and keeps native priority coherent.
This is the implementation choice under the standing autonomous build request.
