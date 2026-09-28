// Choose your own PIN. Where ProtectedRoute holds a member who signed in on a PIN
// an admin issued.
//
// It is a stop, not a suggestion: while an admin-issued PIN stands, two people can
// sign in as this member, so their dashboard, their PII and the phone number their
// login rests on are not theirs alone. If the member is an admin it is worse — the
// second signature 008 requires stops being a second person. There is no "skip";
// signing out is the only other way off this screen, which is honest, since the
// account is not fully theirs until they have done this.
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../hooks/useAuth'
import { useLanguage } from '../hooks/useLanguage'
import { signOut } from '../lib/auth'
import PinForm from '../components/ui/PinForm'

export default function SetPin() {
  const { profile, pinStatus, refreshProfile } = useAuth()
  const { t } = useLanguage()
  const navigate = useNavigate()

  // Reached voluntarily from Profile rather than by the gate: the member already
  // chose this PIN, so changing it asks for the current one.
  const forced = pinStatus?.mustChange === true

  async function handleSaved() {
    // Refresh first, or the gate still sees must_change and bounces them back here.
    await refreshProfile()
    navigate('/', { replace: true })
  }

  return (
    <div className="relative min-h-dvh overflow-hidden bg-slate-50">
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 -top-40 h-[420px] bg-gradient-to-b from-emerald-100/60 via-emerald-50/40 to-transparent"
      />
      <div className="relative flex min-h-dvh flex-col justify-center px-6 py-12">
        <div className="mx-auto w-full max-w-sm">
          <div className="mb-6 text-center">
            <h1 className="text-[22px] font-semibold tracking-tight text-slate-900">
              {forced ? t('Choose your own PIN') : t('Change your PIN')}
            </h1>
            <p className="mt-2 text-sm text-slate-500">
              {forced
                ? t('Your admin set the PIN you just used, so they know it too. Pick one only you know.')
                : t('Pick a new PIN. You will use it with your first name and phone number to sign in.')}
            </p>
          </div>

          <div className="rounded-2xl bg-white p-6 shadow-auth ring-1 ring-slate-200/70">
            <PinForm
              requireCurrent={!forced && pinStatus?.hasPin === true}
              submitLabel={t('Save PIN')}
              onSaved={handleSaved}
            />
          </div>

          {profile?.full_name && (
            <p className="mt-6 text-center text-xs text-slate-400">
              {t('Signed in as {name}').replace('{name}', profile.full_name)}
            </p>
          )}

          <div className="mt-2 text-center">
            <button
              type="button"
              onClick={async () => {
                await signOut()
                navigate('/login', { replace: true })
              }}
              className="text-xs font-medium text-slate-500 hover:text-slate-700"
            >
              {t('Sign out')}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
