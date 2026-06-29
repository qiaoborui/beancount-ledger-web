export function shouldShowServiceWorkerUpdate(
  waiting: ServiceWorker | null | undefined,
  controller: ServiceWorker | null | undefined,
  dismissedWaiting: ServiceWorker | null | undefined,
) {
  return Boolean(waiting && controller && waiting !== dismissedWaiting);
}
