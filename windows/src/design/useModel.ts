import { useCallback, useEffect, useState, useSyncExternalStore } from 'react';

/** Anything with the subscribe/version pair the models expose. */
interface ObservableModel {
  subscribe: (listener: () => void) => () => void;
  version: number;
}

/** Re-renders whenever the model reports a change. Returns the model's change counter. */
export function useModelVersion(model: ObservableModel): number {
  const subscribeToModel = useCallback((listener: () => void) => model.subscribe(listener), [model]);
  return useSyncExternalStore(subscribeToModel, () => model.version);
}

function matchesMediaQuery(query: string): boolean {
  return typeof window !== 'undefined' && window.matchMedia(query).matches;
}

/** Follows a CSS media query live (system dark mode, reduced motion, contrast). */
export function useMediaQuery(query: string): boolean {
  const [isMatching, setIsMatching] = useState(() => matchesMediaQuery(query));
  useEffect(() => {
    const mediaQueryList = window.matchMedia(query);
    const handleChange = () => setIsMatching(mediaQueryList.matches);
    handleChange();
    mediaQueryList.addEventListener('change', handleChange);
    return () => mediaQueryList.removeEventListener('change', handleChange);
  }, [query]);
  return isMatching;
}

export function usePrefersReducedMotion(): boolean {
  return useMediaQuery('(prefers-reduced-motion: reduce)');
}

/** The class names a window root needs for the system appearance and contrast. */
export function useSystemAppearanceClassName(): string {
  const prefersDark = useMediaQuery('(prefers-color-scheme: dark)');
  const prefersMoreContrast = useMediaQuery('(prefers-contrast: more)');
  return `${prefersDark ? 'appearance-dark' : 'appearance-light'}${prefersMoreContrast ? ' contrast-more' : ''}`;
}
