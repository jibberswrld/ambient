import { describe, expect, it } from 'vitest';
import type { GateScreen } from '../host/contract';
import { allPermissionKinds, areRequiredPermissionsGranted, firstMissingPermission, permissionStatus } from './permissions';

describe('permissions step', () => {
  it('reports the first missing permission and when all are granted', () => {
    expect(permissionStatus(null, 'microphone')).toBe('notYetAsked');
    expect(firstMissingPermission({ microphone: 'deniedInSystemSettings' })).toBe('microphone');
    expect(areRequiredPermissionsGranted({ microphone: 'waiting' })).toBe(false);
    expect(areRequiredPermissionsGranted({ microphone: 'granted' })).toBe(true);
    expect(firstMissingPermission({ microphone: 'granted' })).toBeNull();
  });

  it('asks Windows only for the microphone', () => {
    expect(allPermissionKinds).toEqual(['microphone']);
  });

  it('keeps gate buttons in the order the host sent them', () => {
    const gateScreen: GateScreen = {
      id: 'sign-in',
      title: 'Sign in to start',
      body: 'Ambient runs on your publik account.',
      note: null,
      isWaiting: false,
      buttons: [
        { action: 'create', label: 'Create an account', prominence: 'quiet' },
        { action: 'sign-in', label: 'Sign in', prominence: 'primary' },
      ],
    };
    expect(gateScreen.buttons.map((button) => button.action)).toEqual(['create', 'sign-in']);
  });
});
