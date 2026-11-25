import type { PushToTalkShortcut } from '../host/contract';

export const allPushToTalkShortcuts: PushToTalkShortcut[] = ['controlAlt', 'controlWindows', 'controlShift'];

/** The keycap labels for a shortcut, in the order they are pressed. */
export function keycapLabels(shortcut: PushToTalkShortcut): string[] {
  switch (shortcut) {
    case 'controlAlt':
      return ['Ctrl', 'Alt'];
    case 'controlWindows':
      return ['Ctrl', 'Win'];
    case 'controlShift':
      return ['Ctrl', 'Shift'];
  }
}

/** "Ctrl + Alt", for tooltips and screen readers. */
export function spokenShortcutName(shortcut: PushToTalkShortcut): string {
  return keycapLabels(shortcut).join(' + ');
}
