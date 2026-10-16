/**
 * Phone settings that stop (or delay) location updates. A device reports the
 * ones that currently apply with each upload; viewers get them back so the
 * user's detail pane can say why a person has gone quiet.
 *
 * Codes are a closed set so a client can map each to wording and fix steps.
 * Unknown codes from newer builds are dropped rather than stored.
 */
export const TRACKING_ISSUES = [
  /** Location is switched off for the whole phone. */
  "location_services_off",
  /** The app has no location permission at all. */
  "location_permission",
  /** Location is not "Allow all the time", so nothing is recorded in the background. */
  "background_location",
  /** Only approximate location is allowed; routes can't be recorded. */
  "precise_location",
  /** Android battery optimization may stop background wake-ups. */
  "battery_optimization",
] as const;

export type TrackingIssue = (typeof TRACKING_ISSUES)[number];

const KNOWN = new Set<string>(TRACKING_ISSUES);

/**
 * Reads the `tracking_issues` field of an upload. `null` means the device
 * didn't say (older builds): keep what the server already has. An empty list
 * is a positive report that nothing is wrong.
 */
export function parseTrackingIssues(value: unknown): TrackingIssue[] | null {
  if (!Array.isArray(value)) return null;
  const issues = new Set<TrackingIssue>();
  for (const item of value) {
    if (typeof item === "string" && KNOWN.has(item)) {
      issues.add(item as TrackingIssue);
    }
  }
  // Stable order, so equal reports compare equal.
  return TRACKING_ISSUES.filter((issue) => issues.has(issue));
}
