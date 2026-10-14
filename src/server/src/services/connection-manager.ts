interface ClientEntry {
  socket: any;
  // Whether this viewer currently has the live map tab in the foreground —
  // as opposed to merely holding an open connection (e.g. sitting on the
  // Profile tab). Defaults to true so a freshly-connected viewer counts
  // until it tells us otherwise.
  mapActive: boolean;
}

class ConnectionManager {
  private readonly clients = new Map<string, ClientEntry>();

  add(userId: string, socket: any) {
    if (this.clients.has(userId)) {
      const existing = this.clients.get(userId);
      try {
        existing?.socket.close();
      } catch (_) {
        // ignore existing close failures
      }
    }

    this.clients.set(userId, { socket, mapActive: true });
  }

  remove(userId: string) {
    this.clients.delete(userId);
  }

  setMapActive(userId: string, active: boolean) {
    const entry = this.clients.get(userId);
    if (entry) {
      entry.mapActive = active;
    }
  }

  broadcast(message: unknown) {
    const text = JSON.stringify(message);
    for (const [userId, entry] of [...this.clients.entries()]) {
      try {
        entry.socket.send(text);
      } catch (_) {
        this.clients.delete(userId);
      }
    }
  }

  /**
   * Sends each connected viewer the message `build` returns for them, or
   * nothing when it returns null.
   */
  broadcastEach(build: (viewerId: string) => unknown | null) {
    for (const [userId, entry] of [...this.clients.entries()]) {
      const message = build(userId);
      if (message == null) continue;
      try {
        entry.socket.send(JSON.stringify(message));
      } catch (_) {
        this.clients.delete(userId);
      }
    }
  }

  /** Sends one connected viewer a message; false when they aren't connected. */
  sendTo(viewerId: string, message: unknown): boolean {
    const entry = this.clients.get(viewerId);
    if (!entry) return false;
    try {
      entry.socket.send(JSON.stringify(message));
      return true;
    } catch (_) {
      this.clients.delete(viewerId);
      return false;
    }
  }

  get count(): number {
    return this.clients.size;
  }

  /** Number of connected viewers that currently have the map tab in the foreground. */
  get activeMapCount(): number {
    let count = 0;
    for (const entry of this.clients.values()) {
      if (entry.mapActive) {
        count += 1;
      }
    }
    return count;
  }
}

export default ConnectionManager;
