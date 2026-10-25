import { vi } from 'vitest';

// The real library needs WebGL. Every test gets the DOM-safe stand-in instead.
vi.mock('mapbox-gl', () => import('./mapbox-mock'));
