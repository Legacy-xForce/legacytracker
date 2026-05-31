class ConnectionManager {
  private readonly clients = new Map<string, any>();

  add(userId: string, socket: any) {
    if (this.clients.has(userId)) {
      const existing = this.clients.get(userId);
      try {
        existing?.close();
      } catch (_) {
        // ignore existing close failures
      }
    }

    this.clients.set(userId, socket);
  }

  remove(userId: string) {
    this.clients.delete(userId);
  }

  broadcast(message: unknown) {
    const text = JSON.stringify(message);
    for (const [userId, socket] of [...this.clients.entries()]) {
      try {
        socket.send(text);
      } catch (_) {
        this.clients.delete(userId);
      }
    }
  }

  get count(): number {
    return this.clients.size;
  }
}

export default ConnectionManager;
