export function shouldOfferHeaderSensitiveUnlock({
  offlineSensitiveUnlockAvailable,
  online,
  unlocked,
}: {
  offlineSensitiveUnlockAvailable: boolean;
  online: boolean;
  unlocked: boolean;
}) {
  if (unlocked) return false;
  return online || offlineSensitiveUnlockAvailable;
}
