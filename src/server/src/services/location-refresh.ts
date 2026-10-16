export type RefreshOutcome = "updated" | "timeout";

export interface LocationRefreshOptions {
  /** How long to wait for the device to report in before giving up. */
  timeoutMs: number;
  /** Pushes the "refresh now" command to the user's devices. */
  send: (userId: string) => Promise<void>;
  onError?: (error: unknown) => void;
}

/**
 * Turns "ask a phone for a fresh position" into a request that finishes when
 * the phone has answered.
 *
 * The phone replies through its normal upload, not to the request, so callers
 * register here first and `noteUpload` resolves them when that user's next
 * batch lands. Requests for the same user share one push and one wait, so
 * mashing the button can't storm a phone that is already on its way.
 */
export class LocationRefreshCoordinator {
  private readonly pending = new Map<string, Promise<RefreshOutcome>>();
  private readonly resolvers = new Map<string, () => void>();

  constructor(private readonly options: LocationRefreshOptions) {}

  request(userId: string): Promise<RefreshOutcome> {
    const existing = this.pending.get(userId);
    if (existing) {
      return existing;
    }

    const outcome = new Promise<RefreshOutcome>((resolve) => {
      const timer = setTimeout(() => finish("timeout"), this.options.timeoutMs);
      const finish = (result: RefreshOutcome) => {
        clearTimeout(timer);
        this.pending.delete(userId);
        this.resolvers.delete(userId);
        resolve(result);
      };
      this.resolvers.set(userId, () => finish("updated"));
    });
    this.pending.set(userId, outcome);

    // Registered before sending, so an instant reply can't slip past.
    this.options.send(userId).catch((error) => this.options.onError?.(error));
    return outcome;
  }

  /** Call after every ingested batch: the device is awake and reporting. */
  noteUpload(userId: string): void {
    this.resolvers.get(userId)?.();
  }
}
