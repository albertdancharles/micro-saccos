// Group settings, fetched once and shared (same provider+hook shape as useLanguage).
// The rules change rarely — a 2-of-N vote — so there is no reason for every card to
// re-query them. `refresh` is exposed for the admin panel to call after a vote lands.
import { createContext, useCallback, useContext, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { getSettings, SETTING_DEFAULTS } from '../lib/settings'

const GroupSettingsContext = createContext(null)

export function GroupSettingsProvider({ children }) {
  const [values, setValues] = useState(SETTING_DEFAULTS)
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    try {
      const { values: v, rows: r } = await getSettings(supabase)
      setValues(v)
      setRows(r)
    } catch {
      // Settings are advisory for the UI — the DB re-checks every rule server-side.
      // If the table isn't reachable (or 020 isn't applied yet) we keep the seeded
      // defaults rather than blocking the dashboard behind an error.
      setValues(SETTING_DEFAULTS)
      setRows([])
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    // load() sets state only after an await (no synchronous cascade) — false positive.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load()
  }, [load])

  return (
    <GroupSettingsContext.Provider value={{ settings: values, rows, loading, refresh: load }}>
      {children}
    </GroupSettingsContext.Provider>
  )
}

// Provider + hook live together (same pattern as useAuth/useLanguage). The hook
// export trips react-refresh's components-only rule, which is harmless here.
// eslint-disable-next-line react-refresh/only-export-components
export function useGroupSettings() {
  return useContext(GroupSettingsContext) ?? { settings: SETTING_DEFAULTS, rows: [], loading: false, refresh: () => {} }
}
