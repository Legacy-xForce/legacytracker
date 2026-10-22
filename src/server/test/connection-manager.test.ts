import assert from "node:assert/strict";
import { test } from "node:test";

import ConnectionManager from "../src/services/connection-manager";

function fakeSocket() {
  const sent: string[] = [];
  let closed = false;
  let terminated = false;
  let pings = 0;
  return {
    sent,
    get closed() {
      return closed;
    },
    get terminated() {
      return terminated;
    },
    get pings() {
      return pings;
    },
    send: (text: string) => void sent.push(text),
    close: () => void (closed = true),
    terminate: () => void (terminated = true),
    ping: () => void (pings += 1),
  };
}

test("a second connection for the same user does not replace the first", () => {
  const manager = new ConnectionManager();
  const phone = fakeSocket();
  const browser = fakeSocket();
  manager.add("a", phone);
  manager.add("a", browser);

  assert.equal(phone.closed, false);
  assert.equal(manager.count, 2);
  manager.sendTo("a", { x: 1 });
  assert.deepEqual(phone.sent, ['{"x":1}']);
  assert.deepEqual(browser.sent, ['{"x":1}']);
});

test("broadcastEach reaches every connection of a viewer", () => {
  const manager = new ConnectionManager();
  const one = fakeSocket();
  const two = fakeSocket();
  const other = fakeSocket();
  manager.add("a", one);
  manager.add("a", two);
  manager.add("b", other);

  manager.broadcastEach((viewerId) => (viewerId === "a" ? { for: "a" } : null));

  assert.equal(one.sent.length, 1);
  assert.equal(two.sent.length, 1);
  assert.equal(other.sent.length, 0);
});

test("closing one connection leaves the user's other connection in place", () => {
  const manager = new ConnectionManager();
  const phone = fakeSocket();
  const browser = fakeSocket();
  manager.add("a", phone);
  manager.add("a", browser);

  manager.remove("a", phone);

  assert.equal(manager.count, 1);
  assert.equal(manager.sendTo("a", { x: 1 }), true);
  assert.equal(phone.sent.length, 0);
  assert.equal(browser.sent.length, 1);
  manager.remove("a", browser);
  assert.equal(manager.sendTo("a", { x: 1 }), false);
});

test("map-active is tracked per connection", () => {
  const manager = new ConnectionManager();
  const phone = fakeSocket();
  const browser = fakeSocket();
  manager.add("a", phone);
  manager.add("a", browser);
  assert.equal(manager.activeMapCount, 2);

  manager.setMapActive("a", browser, false);
  assert.equal(manager.activeMapCount, 1);
  manager.setMapActive("a", phone, false);
  assert.equal(manager.activeMapCount, 0);
  manager.setMapActive("a", phone, true);
  assert.equal(manager.activeMapCount, 1);
});

test("a connection whose send throws is dropped, the others still get the message", () => {
  const manager = new ConnectionManager();
  const broken = {
    send: () => {
      throw new Error("closed");
    },
    close() {},
  };
  const healthy = fakeSocket();
  manager.add("a", broken);
  manager.add("a", healthy);

  assert.equal(manager.sendTo("a", { x: 1 }), true);
  assert.equal(healthy.sent.length, 1);
  assert.equal(manager.count, 1);
});

test("the oldest connection is closed once a user has too many", () => {
  const manager = new ConnectionManager();
  const sockets = Array.from({ length: 6 }, fakeSocket);
  for (const socket of sockets) manager.add("a", socket);

  assert.equal(sockets[0].closed, true);
  assert.equal(sockets[1].closed, false);
  assert.equal(manager.count, 5);
});

test("active map users count a user once, however many maps they have open", () => {
  const manager = new ConnectionManager();
  const phone = fakeSocket();
  const browser = fakeSocket();
  const other = fakeSocket();
  manager.add("a", phone);
  manager.add("a", browser);
  manager.add("b", other);
  assert.deepEqual([...manager.activeMapUsers()], ["a", "b"]);

  manager.setMapActive("a", phone, false);
  assert.deepEqual([...manager.activeMapUsers()], ["a", "b"]);
  manager.setMapActive("a", browser, false);
  manager.setMapActive("b", other, false);
  assert.deepEqual([...manager.activeMapUsers()], []);
});

test("the heartbeat pings every socket and drops one that never answered", () => {
  const manager = new ConnectionManager();
  const answering = fakeSocket();
  const silent = fakeSocket();
  manager.add("a", answering);
  manager.add("b", silent);

  assert.equal(manager.sweep(), 0);
  assert.equal(answering.pings, 1);
  assert.equal(silent.pings, 1);

  manager.markAlive("a", answering);
  assert.equal(manager.sweep(), 1);
  assert.equal(silent.terminated, true);
  assert.equal(answering.terminated, false);
  assert.equal(answering.pings, 2);
  assert.equal(manager.count, 1);
  assert.deepEqual([...manager.activeMapUsers()], ["a"]);
});

test("a back-channel logout closes only the sockets of that session", () => {
  const manager = new ConnectionManager();
  const browser = fakeSocket();
  const phone = fakeSocket();
  const script = fakeSocket();
  manager.add("a", browser, "sid-web");
  manager.add("a", phone, "sid-app");
  manager.add("a", script, null);

  assert.equal(manager.closeSession("sid-web", { type: "signed_out" }), 1);
  assert.deepEqual(browser.sent, ['{"type":"signed_out"}']);
  assert.equal(browser.closed, true);
  assert.equal(phone.closed, false);
  assert.equal(manager.count, 2);
});

test("a user-wide logout spares API-token streams unless access was lost", () => {
  const manager = new ConnectionManager();
  const browser = fakeSocket();
  const script = fakeSocket();
  manager.add("a", browser, "sid-web");
  manager.add("a", script, null);

  assert.equal(manager.closeUser("a", { type: "signed_out" }, { sessionsOnly: true }), 1);
  assert.equal(browser.closed, true);
  assert.equal(script.closed, false);

  assert.equal(manager.closeUser("a", { type: "signed_out" }), 1);
  assert.equal(script.closed, true);
  assert.equal(manager.count, 0);
});
