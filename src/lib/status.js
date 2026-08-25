// The one list of status wording, shared by every presentation of a status:
// the Badge pill, the member grid's dot + label, and anything added later.
// Callers pass the result through t() themselves so this file stays free of
// React and the translation context.
const LABELS = {
  paid: 'Paid',
  approved: 'Approved',
  pending: 'Pending',
  // Something has been paid but a balance remains and it is not yet past due.
  // Once it IS past due the views report 'overdue' instead — being late is the
  // signal that matters, and amount_paid still tells the UI it was part-settled.
  partial: 'Part paid',
  overdue: 'Overdue',
  rejected: 'Rejected',
  upcoming: 'Not due',
  cancelled: 'Cancelled',
  na: 'N/A',
  // A settled payment reversed by a 2-of-N correction (037). The row is kept, not
  // deleted — a void is a correction, not an erasure — so members and admins both
  // see it in history and it needs wording of its own.
  voided: 'Voided',
  // Outbound messaging (026/032). "Queued" and "Sent" are deliberately distinct:
  // the reminder sweep only ever queues, and treating that as success is what let
  // a broken delivery pipeline look healthy on the audit page for weeks.
  queued: 'Queued',
  sent: 'Sent',
}

export function statusKey(status) {
  return String(status || 'na').toLowerCase()
}

// The English label for a status, or null if it isn't one we know — in which
// case callers show the raw value rather than inventing wording for it.
export function statusLabel(status) {
  return LABELS[statusKey(status)] || null
}
