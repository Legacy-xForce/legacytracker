interface ClientEntry {
  socket: any;
  // Whether this viewer currently has the live map tab in the foreground —
  // as opposed to merely holding an open connection (e.g. sitting on the
  // Profile tab). Defaults to true so a freshly-connected viewer counts
  // until it tells us otherwise.
  mapActive: boolean;
  // Whether the socket answered the last heartbeat ping.
  alive: boolean;
  // The OP session (`sid`) of the sign-in that opened the socket; null for
  // API tokens and legacy password-login sessions.
  sid: string | null;
}

// One account can be connected from several places at once (the phone and a
// browser tab). The cap keeps a client that reconnects without its old socket
// ever closing from piling up entries — each active one keeps live mode on.
const MAX_SOCKETS_PER_USER = 5;

class ConnectionManager {
  private readonly clients = new Map<string, ClientEntry[]>();

  add(userId: string, socket: any, sid: string | null = null) {
    const entries = this.clients.get(userId) ?? [];
    while (entries.length >= MAX_SOCKETS_PER_USER) {
      try {
        entries.shift()?.socket.close();
      } catch (_) {
        // ignore existing close failures
      }
    }
    entries.push({ socket, mapActive: true, alive: true, sid });
    this.clients.set(userId, entries);
  }

  remove(userId: string, socket: any) {
    this.drop(userId, (entry) => entry.socket === socket);
  }

  setMapActive(userId: string, socket: any, active: boolean) {
    const entry = this.clients
      .get(userId)
      ?.find((candidate) => candidate.socket === socket);
    if (entry) {
      entry.mapActive = active;
    }
  }

  /** The socket answered a heartbeat ping. */
  markAlive(userId: string, socket: any) {
    const entry = this.clients
      .get(userId)
      ?.find((candidate) => candidate.socket === socket);
    if (entry) {
      entry.alive = true;
    }
  }

  /**
   * One heartbeat round: drops every socket that didn't answer the previous
   * ping and pings the rest. Browsers can't ping, and a sleeping laptop or a
   * phone out of signal leaves its socket open here until TCP gives up —
   * minutes in which it would still count as someone looking at the map.
   * Returns how many sockets were dropped.
   */
  sweep(): number {
    let dropped = 0;
    for (const [userId, entries] of [...this.clients.entries()]) {
      for (const entry of [...entries]) {
        if (!entry.alive) {
          try {
            entry.socket.terminate();
          } catch (_) {
            // already gone
          }
          this.drop(userId, (candidate) => candidate === entry);
          dropped += 1;
          continue;
        }
        entry.alive = false;
        try {
          entry.socket.ping();
        } catch (_) {
          // a failed ping is caught by the next round
        }
      }
    }
    return dropped;
  }

  broadcast(message: unknown) {
    this.broadcastEach(() => message);
  }

  /**
   * Sends each connected viewer the message `build` returns for them, or
   * nothing when it returns null. A viewer with several connections gets it
   * on each.
   */
  broadcastEach(build: (viewerId: string) => unknown | null) {
    for (const [userId, entries] of [...this.clients.entries()]) {
      const message = build(userId);
      if (message == null) continue;
      this.deliver(userId, entries, JSON.stringify(message));
    }
  }

  /** Sends one connected viewer a message; false when they aren't connected. */
  sendTo(viewerId: string, message: unknown): boolean {
    const entries = this.clients.get(viewerId);
    if (!entries || entries.length === 0) return false;
    return this.deliver(viewerId, entries, JSON.stringify(message));
  }

  /**
   * Sends `message` to every socket opened by the OP session `sid`, then
   * closes them. Returns how many were closed.
   */
  closeSession(sid: string, message: unknown): number {
    let closed = 0;
    for (const [userId, entries] of [...this.clients.entries()]) {
      closed += this.close(
        userId,
        entries.filter((entry) => entry.sid === sid),
        message,
      );
    }
    return closed;
  }

  /**
   * Same for all of a user's sockets, or with `sessionsOnly` only those
   * opened by an OP session (API-token streams stay up).
   */
  closeUser(
    userId: string,
    message: unknown,
    { sessionsOnly = false }: { sessionsOnly?: boolean } = {},
  ): number {
    const entries = (this.clients.get(userId) ?? []).filter(
      (entry) => !sessionsOnly || entry.sid !== null,
    );
    return this.close(userId, entries, message);
  }

  /** Number of open connections (a user on two devices counts twice). */
  get count(): number {
    let count = 0;
    for (const entries of this.clients.values()) {
      count += entries.length;
    }
    return count;
  }

  /** Number of connections that currently have the map tab in the foreground. */
  get activeMapCount(): number {
    let count = 0;
    for (const entries of this.clients.values()) {
      for (const entry of entries) {
        if (entry.mapActive) {
          count += 1;
        }
      }
    }
    return count;
  }

  /** Users with at least one connection that has the map in the foreground. */
  activeMapUsers(): Set<string> {
    const users = new Set<string>();
    for (const [userId, entries] of this.clients) {
      if (entries.some((entry) => entry.mapActive)) {
        users.add(userId);
      }
    }
    return users;
  }

  private close(userId: string, entries: ClientEntry[], message: unknown): number {
    const text = JSON.stringify(message);
    for (const entry of entries) {
      try {
        entry.socket.send(text);
        entry.socket.close(1000, "Signed out");
      } catch (_) {
        // already gone
      }
    }
    this.drop(userId, (candidate) => entries.includes(candidate));
    return entries.length;
  }

  /** True when at least one of the user's connections took the message. */
  private deliver(userId: string, entries: ClientEntry[], text: string): boolean {
    let delivered = false;
    for (const entry of [...entries]) {
      try {
        entry.socket.send(text);
        delivered = true;
      } catch (_) {
        this.drop(userId, (candidate) => candidate === entry);
      }
    }
    return delivered;
  }

  private drop(userId: string, matches: (entry: ClientEntry) => boolean) {
    const entries = this.clients.get(userId);
    if (!entries) return;
    const remaining = entries.filter((entry) => !matches(entry));
    if (remaining.length === 0) {
      this.clients.delete(userId);
    } else {
      this.clients.set(userId, remaining);
    }
  }
}

export default ConnectionManager;
