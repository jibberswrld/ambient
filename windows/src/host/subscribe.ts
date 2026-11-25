import type { AmbientEventName, AmbientEvents, AmbientHost } from './contract';

export type HostEventHandlers = { [EventName in AmbientEventName]?: (payload: AmbientEvents[EventName]) => void };

/**
 * Listens to several host events at once and returns one function that stops all of them, including listeners that
 * were still being registered when it was called (so a React effect can clean up synchronously).
 */
export function subscribeToHostEvents(host: AmbientHost, handlers: HostEventHandlers): () => void {
  let isStopped = false;
  const stopFunctions: (() => void)[] = [];
  for (const eventName of Object.keys(handlers) as AmbientEventName[]) {
    const handler = handlers[eventName] as (payload: AmbientEvents[typeof eventName]) => void;
    void host.listen(eventName, handler).then((stopListening) => {
      if (isStopped) stopListening();
      else stopFunctions.push(stopListening);
    });
  }
  return () => {
    isStopped = true;
    stopFunctions.forEach((stopListening) => stopListening());
  };
}
