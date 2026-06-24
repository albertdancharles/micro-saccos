// The member KYC inputs shared by SignUp and CompleteProfile. Controlled via a
// flat `values` object + `onChange(name, value)`. `secondary_phone`, `national_id`
// and the next-of-kin fields are optional; the rest are required before a member
// can use the app (see REQUIRED_PROFILE_FIELDS in lib/auth).
import { useLanguage } from '../../hooks/useLanguage'

// Module-level so the input identity is stable across renders (a component defined
// inside the parent would remount each keystroke and drop focus).
function Field({ id, label, value, onChange, ...props }) {
  return (
    <div>
      <label htmlFor={id} className="block text-sm font-medium text-slate-700 mb-1">
        {label}
      </label>
      <input id={id} className="input-field" value={value} onChange={onChange} {...props} />
    </div>
  )
}

export default function ProfileFields({ values, onChange, idPrefix = 'pf' }) {
  const { t } = useLanguage()
  const f = (name, label, props = {}) => (
    <Field
      id={`${idPrefix}-${name}`}
      label={label}
      value={values[name] || ''}
      onChange={(e) => onChange(name, e.target.value)}
      {...props}
    />
  )

  return (
    <>
      {f('full_name', t('Full name'), { autoComplete: 'name', placeholder: 'e.g. Jane Mushi' })}
      {f('phone_number', t('Phone number'), { inputMode: 'tel', placeholder: '+255…' })}
      {f('secondary_phone', t('Additional phone (optional)'), { inputMode: 'tel', placeholder: '+255…' })}
      {f('residence', t('Residence'), { placeholder: t('e.g. Mbezi Beach, Dar es Salaam') })}
      {f('national_id', t('National ID (NIDA) (optional)'))}
      {f('next_of_kin_name', t('Next of kin — name (optional)'))}
      {f('next_of_kin_phone', t('Next of kin — phone (optional)'), { inputMode: 'tel', placeholder: '+255…' })}
    </>
  )
}
