import type { PermissionStatus, PermissionStatuses } from '../host/contract';

// The permissions step on Windows. Windows has no Accessibility or Screen Recording permission and transcription is
// not on-device, so the microphone is the one permission there is, and it is required.

export type PermissionKind = keyof PermissionStatuses;

export const allPermissionKinds: PermissionKind[] = ['microphone'];

export function isPermissionRequired(_permissionKind: PermissionKind): boolean {
  return true;
}

/** An unreported status reads as not yet asked. */
export function permissionStatus(statuses: PermissionStatuses | null, permissionKind: PermissionKind): PermissionStatus {
  return statuses?.[permissionKind] ?? 'notYetAsked';
}

/** Every permission Ambient cannot work without. */
export function areRequiredPermissionsGranted(statuses: PermissionStatuses | null): boolean {
  return allPermissionKinds.filter(isPermissionRequired).every((permissionKind) => permissionStatus(statuses, permissionKind) === 'granted');
}

/** The row whose button is the one ember action: the first required permission still missing. */
export function firstMissingPermission(statuses: PermissionStatuses | null): PermissionKind | null {
  return allPermissionKinds.find((permissionKind) => isPermissionRequired(permissionKind) && permissionStatus(statuses, permissionKind) !== 'granted') ?? null;
}

export const permissionTitles: Record<PermissionKind, string> = { microphone: 'Microphone' };

/** Why Ambient needs it, in one plain line. */
export const permissionReasons: Record<PermissionKind, string> = { microphone: 'To hear you while you hold the keys. Never otherwise.' };

/** The reason line once the switch is off in Windows Settings: only the person can turn it back on there. */
export const permissionDeniedReasons: Record<PermissionKind, string> = { microphone: 'Turned off for Ambient in Windows Settings.' };
