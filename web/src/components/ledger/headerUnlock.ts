export function shouldOfferHeaderSensitiveUnlock({
  hasPasskey,
  passkeyStatusLoaded,
  quickUnlockEnabled,
  offlineSensitiveUnlockAvailable,
  online,
  unlocked,
}: {
  hasPasskey: boolean;
  passkeyStatusLoaded: boolean;
  quickUnlockEnabled: boolean;
  offlineSensitiveUnlockAvailable: boolean;
  online: boolean;
  unlocked: boolean;
}) {
  if (unlocked) return false;
  if (hasPasskey || quickUnlockEnabled || offlineSensitiveUnlockAvailable) return true;
  return online && !passkeyStatusLoaded;
}
