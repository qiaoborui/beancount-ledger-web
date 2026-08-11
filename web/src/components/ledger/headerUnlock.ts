export function shouldOfferHeaderSensitiveUnlock({
  online,
  unlocked,
}: {
  online: boolean;
  unlocked: boolean;
}) {
  if (unlocked) return false;
  return online;
}
