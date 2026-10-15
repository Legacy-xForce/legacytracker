export interface ViewerPresenceOptions {
  /** A new viewer is shown once their map has stayed open this long. */
  joinSettleMs: number;
  /** A viewer whose map closes stays shown this long, in case it comes back. */
  leaveGraceMs: number;
  /** Called with the shown viewers whenever they change. */
  onChange: (viewerIds: string[]) => void;
}

/**
 * Who everyone sees as currently looking at the map.
 *
 * Follows the users with a map in the foreground, smoothed a little both
 * ways: a socket counts as an open map until it says otherwise, so a tab
 * opened in the background would otherwise flash in, and reconnects (the web
 * client reconnects whenever its tab comes back, the app on every resume)
 * would make faces blink out and back.
 */
export class ViewerPresence {
  // Insertion-ordered, so newcomers join the end of the row.
  private readonly shown = new Set<string>();
  // At most one pending change per user: a join while they aren't shown,
  // a leave while they are.
  private readonly pending = new Map<string, NodeJS.Timeout>();

  constructor(private readonly options: ViewerPresenceOptions) {}

  get viewerIds(): string[] {
    return [...this.shown];
  }

  update(activeUserIds: ReadonlySet<string>): void {
    for (const userId of activeUserIds) {
      if (this.shown.has(userId)) {
        this.cancel(userId);
      } else if (!this.pending.has(userId)) {
        this.schedule(userId, this.options.joinSettleMs, () =>
          this.shown.add(userId),
        );
      }
    }
    for (const userId of [...this.pending.keys()]) {
      if (!this.shown.has(userId) && !activeUserIds.has(userId)) {
        this.cancel(userId);
      }
    }
    for (const userId of this.shown) {
      if (!activeUserIds.has(userId) && !this.pending.has(userId)) {
        this.schedule(userId, this.options.leaveGraceMs, () =>
          this.shown.delete(userId),
        );
      }
    }
  }

  private schedule(userId: string, delayMs: number, apply: () => void): void {
    const timer = setTimeout(() => {
      this.pending.delete(userId);
      apply();
      this.options.onChange(this.viewerIds);
    }, delayMs);
    timer.unref?.();
    this.pending.set(userId, timer);
  }

  private cancel(userId: string): void {
    const timer = this.pending.get(userId);
    if (timer) {
      clearTimeout(timer);
      this.pending.delete(userId);
    }
  }
}
