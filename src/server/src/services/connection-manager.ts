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
