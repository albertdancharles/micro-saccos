// Current member's profile + role (build plan §3). Reads the shared auth context
// so there's no duplicate fetch.
import { useAuth } from './useAuth'

export function useProfile() {
  const { profile, loadingProfile } = useAuth()
  return { profile, loading: loadingProfile }
}
