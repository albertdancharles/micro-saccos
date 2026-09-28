// An exited member is not a pending applicant.
//
// `profiles.is_active = false` means both "a sign-up awaiting approval" (018) and
// "a member who was settled and left" (025), and the admin dashboard fed the whole
// set to the applicant queue. That put a former member under the heading "Pending
// registrations" next to a Reject button wired to reject_pending_member — a DELETE
// on auth.users that cascades to profiles and destroys exactly the history exit
// exists to preserve.
//
// Migration 040 refuses it in the database, which is the protection that counts.
// This pins the client's copy of the same rule so the queue never renders the
// button in the first place.
import { describe, expect, it } from 'vitest'
import { splitInactiveProfiles } from './admin'

const APPLICANT = { id: 'new-1', full_name: 'Hopeful Applicant', role: 'member' }
const LEAVER = { id: 'gone-1', full_name: 'Departed Member', role: 'member' }

describe('splitInactiveProfiles', () => {
  it('treats a profile with nothing recorded against it as an applicant', () => {
    const { pendingMembers, formerMembers } = splitInactiveProfiles([APPLICANT])

    expect(pendingMembers).toEqual([APPLICANT])
    expect(formerMembers).toEqual([])
  })

  // Each of these on its own is enough to prove someone was a member. The exit
  // settlement is the last one: it is booked as an approved savings_adjustment,
  // which is what catches a member who left having never paid a fee.
  it.each([
    ['a payment submission', { subs: [{ member_id: LEAVER.id }] }],
    ['a monthly fee', { fees: [{ member_id: LEAVER.id }] }],
    ['a loan', { loans: [{ member_id: LEAVER.id }] }],
    ['an exit settlement', { adjustments: [{ target_member_id: LEAVER.id }] }],
  ])('treats a profile with %s as a former member', (_label, history) => {
    const { pendingMembers, formerMembers } = splitInactiveProfiles([LEAVER], history)

    expect(pendingMembers).toEqual([])
    expect(formerMembers).toHaveLength(1)
    expect(formerMembers[0]).toMatchObject({ id: LEAVER.id, full_name: LEAVER.full_name })
  })

  it('separates the two when both are inactive at once', () => {
    const { pendingMembers, formerMembers } = splitInactiveProfiles([APPLICANT, LEAVER], {
      fees: [{ member_id: LEAVER.id }],
    })

    expect(pendingMembers.map((p) => p.id)).toEqual([APPLICANT.id])
    expect(formerMembers.map((p) => p.id)).toEqual([LEAVER.id])
  })

  // The panel that renders these carries no contact details, and it should stay
  // that way: a former member's KYC has no reason to be on the dashboard.
  it('carries only identity through to the former-member list', () => {
    const { formerMembers } = splitInactiveProfiles(
      [{ ...LEAVER, national_id: '19900101-12345', phone_number: '+255700000000' }],
      { loans: [{ member_id: LEAVER.id }] },
    )

    expect(formerMembers[0]).toEqual({
      id: LEAVER.id,
      full_name: LEAVER.full_name,
      role: 'member',
    })
  })

  it('survives a database where none of these tables returned rows', () => {
    expect(splitInactiveProfiles([])).toEqual({ pendingMembers: [], formerMembers: [] })
    expect(splitInactiveProfiles(null)).toEqual({ pendingMembers: [], formerMembers: [] })
  })
})
