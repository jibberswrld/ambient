import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { availableMonitors, cursorPosition, getCurrentWindow, primaryMonitor, type Monitor } from '@tauri-apps/api/window';
import type { AmbientHost, AmbientWindowLabel, DisplayInfo, LogicalRect } from './contract';

// The real host: every command is a Tauri `invoke`, every event a Tauri `listen`. The window's own geometry questions
// go to `@tauri-apps/api/window`.

function logicalRectFromPhysical(physicalX: number, physicalY: number, physicalWidth: number, physicalHeight: number, scaleFactor: number): LogicalRect {
  return {
    x: physicalX / scaleFactor,
    y: physicalY / scaleFactor,
    width: physicalWidth / scaleFactor,
    height: physicalHeight / scaleFactor,
  };
}

function displayInfoFromMonitor(monitor: Monitor, primaryMonitorName: string | null): DisplayInfo {
  const scaleFactor = monitor.scaleFactor;
  return {
    identifier: monitor.name ?? `${monitor.position.x},${monitor.position.y}`,
    isPrimary: monitor.name !== null && monitor.name === primaryMonitorName,
    bounds: logicalRectFromPhysical(monitor.position.x, monitor.position.y, monitor.size.width, monitor.size.height, scaleFactor),
    workArea: logicalRectFromPhysical(
      monitor.workArea.position.x,
      monitor.workArea.position.y,
      monitor.workArea.size.width,
      monitor.workArea.size.height,
      scaleFactor,
    ),
    scaleFactor,
  };
}

export function createTauriHost(): AmbientHost {
  const currentWindow = getCurrentWindow();
  return {
    invoke: (commandName, args) => invoke(commandName, args as Record<string, unknown>),
    listen: async (eventName, handler) => {
      const stopListening = await listen(eventName, (event) => handler(event.payload as never));
      return stopListening;
    },
    ownWindow: {
      label: currentWindow.label as AmbientWindowLabel,
      listDisplays: async () => {
        const [monitors, primary] = await Promise.all([availableMonitors(), primaryMonitor()]);
        const displays = monitors.map((monitor) => displayInfoFromMonitor(monitor, primary?.name ?? null));
        if (!displays.some((display) => display.isPrimary) && displays.length > 0) displays[0].isPrimary = true;
        return displays;
      },
      cursorPosition: async () => {
        // The cursor comes back in physical pixels; divide by the scale of the monitor it is on.
        const physicalPosition = await cursorPosition();
        const monitors = await availableMonitors();
        const monitorUnderCursor =
          monitors.find(
            (monitor) =>
              physicalPosition.x >= monitor.position.x &&
              physicalPosition.x < monitor.position.x + monitor.size.width &&
              physicalPosition.y >= monitor.position.y &&
              physicalPosition.y < monitor.position.y + monitor.size.height,
          ) ?? monitors[0];
        const scaleFactor = monitorUnderCursor?.scaleFactor ?? 1;
        return { x: physicalPosition.x / scaleFactor, y: physicalPosition.y / scaleFactor };
      },
      currentFrame: async () => {
        const [physicalPosition, physicalSize, scaleFactor] = await Promise.all([
          currentWindow.outerPosition(),
          currentWindow.outerSize(),
          currentWindow.scaleFactor(),
        ]);
        return logicalRectFromPhysical(physicalPosition.x, physicalPosition.y, physicalSize.width, physicalSize.height, scaleFactor);
      },
      startDragging: () => currentWindow.startDragging(),
    },
  };
}
