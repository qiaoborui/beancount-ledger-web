export function haptic(pattern: VibratePattern = 8) {
  if (typeof navigator === "undefined" || !navigator.vibrate) return;
  navigator.vibrate(pattern);
}
