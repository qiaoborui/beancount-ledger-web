const iosAuthenticationHapticsKey = "ledger_ios_authentication_haptics";
const iosVibratorIdentifierKey = "pro-max-vibrator-uuid";

function isIOSDevice() {
  if (typeof navigator === "undefined") return false;
  return /iPad|iPhone|iPod/.test(navigator.userAgent)
    || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
}

function vibrate(pattern: VibratePattern) {
  if (typeof navigator === "undefined" || !navigator.vibrate) return;
  navigator.vibrate(pattern);
}

export function readIOSAuthenticationHapticsEnabled() {
  if (typeof window === "undefined") return false;
  try {
    return window.localStorage.getItem(iosAuthenticationHapticsKey) === "1";
  } catch {
    return false;
  }
}

export function writeIOSAuthenticationHapticsEnabled(enabled: boolean) {
  if (typeof window === "undefined") return;
  try {
    if (enabled) window.localStorage.setItem(iosAuthenticationHapticsKey, "1");
    else {
      window.localStorage.removeItem(iosAuthenticationHapticsKey);
      // The polyfill creates this same-origin identifier during module load,
      // even though background vibrations are not enabled by this app.
      window.localStorage.removeItem(iosVibratorIdentifierKey);
    }
  } catch {
    // Ignore unavailable browser storage.
  }
}

export async function loadIOSAuthenticationHaptics() {
  if (!isIOSDevice() || !readIOSAuthenticationHapticsEnabled()) return false;
  await import("ios-vibrator-pro-max");
  return true;
}

export function haptic(pattern: VibratePattern = 8) {
  // The iOS polyfill mutates document.body globally. Keep existing app feedback
  // disabled there so the opt-in remains limited to authentication controls.
  if (isIOSDevice()) return;
  vibrate(pattern);
}

export function authenticationHaptic(pattern: VibratePattern = 8) {
  if (isIOSDevice() && !readIOSAuthenticationHapticsEnabled()) return;
  vibrate(pattern);
}
