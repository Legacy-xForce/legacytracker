export type TrackingCommand = "live" | "idle";

export interface LiveControllerOptions {
  /** How long a device stays in live mode without hearing a renewal. */
  ttlSeconds: number;
  /** Re-send `live` this often while viewers remain (must be < ttl). */
  renewIntervalMs: number;
  /** Zero viewers for this long before devices are told to go idle. */
  offDebounceMs: number;
  send: (command: TrackingCommand, ttlSeconds: number) => Promise<void>;
  onError?: (error: unknown) => void;
}

/**
 * Decides when tracked devices should stream in realtime.
 *
 * Devices batch their uploads by default; only while at least one viewer has
 * the live map open do they switch to realtime. `live` carries a TTL and is
 * renewed while viewers remain, so a lost `idle` push can never strand a
 * device in the expensive mode. Going idle is debounced so tab switches don't
 * storm every device with pushes.
 */
export class LiveController {
  private active = false;
  private offTimer: NodeJS.Timeout | null = null;
  private renewTimer: NodeJS.Timeout | null = null;

  constructor(private readonly options: LiveControllerOptions) {}

  get isActive(): boolean {
    return this.active;
  }

  /** Live TTL a device should apply right now (0 when idle). */
  get ttlSeconds(): number {
    return this.active ? this.options.ttlSeconds : 0;
  }

  update(viewerCount: number): void {
    if (viewerCount > 0) {
      this.cancelOffTimer();
      if (!this.active) {
        this.active = true;
        this.dispatch("live");
        this.renewTimer = setInterval(
          () => this.dispatch("live"),
          this.options.renewIntervalMs,
        );
        this.renewTimer.unref?.();
      }
      return;
    }

    if (!this.active || this.offTimer) {
      return;
    }
    this.offTimer = setTimeout(() => {
      this.offTimer = null;
      this.active = false;
      if (this.renewTimer) {
        clearInterval(this.renewTimer);
        this.renewTimer = null;
      }
      this.dispatch("idle");
    }, this.options.offDebounceMs);
    this.offTimer.unref?.();
  }

  private cancelOffTimer(): void {
    if (this.offTimer) {
      clearTimeout(this.offTimer);
      this.offTimer = null;
    }
  }

  private dispatch(command: TrackingCommand): void {
    const ttl = command === "live" ? this.options.ttlSeconds : 0;
    this.options.send(command, ttl).catch((error) => {
      this.options.onError?.(error);
    });
  }
}
