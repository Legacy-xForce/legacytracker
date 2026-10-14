/**
 * Who has hidden their location from whom.
 *
 * Sharing is on by default: a row only exists for an (owner, viewer) pair
 * the owner switched off. The registry is kept in memory because every
 * location broadcast consults it once per connected viewer; writes go through
 * to the database in app.ts.
 */
export class SharingRegistry {
  private readonly hidden = new Map<string, Set<string>>();

  load(rows: Iterable<{ ownerId: string; viewerId: string }>): void {
    this.hidden.clear();
    for (const { ownerId, viewerId } of rows) {
      this.set(ownerId, viewerId, false);
    }
  }

  /** Whether `ownerId` has switched off sharing with `viewerId`. */
  isHidden(ownerId: string, viewerId: string): boolean {
    // Your own position is never hidden from you.
    return ownerId !== viewerId && this.hidden.get(ownerId)?.has(viewerId) === true;
  }

  /** The viewers `ownerId` is not sharing with. */
  hiddenFrom(ownerId: string): string[] {
    return [...(this.hidden.get(ownerId) ?? [])].sort();
  }

  set(ownerId: string, viewerId: string, shared: boolean): void {
    let viewers = this.hidden.get(ownerId);
    if (shared) {
      viewers?.delete(viewerId);
      if (viewers?.size === 0) {
        this.hidden.delete(ownerId);
      }
      return;
    }
    if (!viewers) {
      viewers = new Set();
      this.hidden.set(ownerId, viewers);
    }
    viewers.add(viewerId);
  }
}

/**
 * What a viewer receives about a user who isn't sharing with them: the user
 * stays in the roster, but nothing about where they are or how their phone is
 * doing — battery and last-seen would still reveal activity.
 */
export function redactedEntry(userId: string, username: string) {
  return { user_id: userId, username, sharing: false };
}

/**
 * Picks what each viewer should be sent for an update about `ownerId`:
 * viewers the owner hides from get nothing (they were already told with a
 * redacted entry), everyone else gets `message`.
 */
export function messageFor(
  registry: SharingRegistry,
  ownerId: string,
  message: unknown,
): (viewerId: string) => unknown | null {
  return (viewerId) => (registry.isHidden(ownerId, viewerId) ? null : message);
}
