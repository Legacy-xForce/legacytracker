import assert from "node:assert/strict";
import { test } from "node:test";

import { clientAddressOf } from "../src/services/client-address";

// The address Traefik reports as its own peer when Cloudflare carried the
// request: one of their edge addresses, not the visitor.
const EDGE = "172.69.224.81";
const VISITOR = "203.0.113.7";

test("a cloudflare edge address is answered with the visitor it names", () => {
  assert.equal(
    clientAddressOf({
      forwardedFor: EDGE,
      connectingIp: VISITOR,
      socketAddress: "172.18.0.2",
    }),
    VISITOR,
  );
  // Same when Traefik is later told to trust Cloudflare and the chain survives.
  assert.equal(
    clientAddressOf({
      forwardedFor: `${VISITOR}, ${EDGE}`,
      connectingIp: VISITOR,
      socketAddress: "172.18.0.2",
    }),
    VISITOR,
  );
  assert.equal(
    clientAddressOf({
      forwardedFor: "::ffff:172.69.224.81",
      connectingIp: "::ffff:203.0.113.7",
      socketAddress: "172.18.0.2",
    }),
    VISITOR,
  );
});

test("without the header there is nothing better than the edge", () => {
  assert.equal(
    clientAddressOf({
      forwardedFor: EDGE,
      connectingIp: undefined,
      socketAddress: "172.18.0.2",
    }),
    EDGE,
  );
  assert.equal(
    clientAddressOf({
      forwardedFor: EDGE,
      connectingIp: "not-an-address",
      socketAddress: "172.18.0.2",
    }),
    EDGE,
  );
});

test("a request that did not cross cloudflare is its own last hop", () => {
  assert.equal(
    clientAddressOf({
      forwardedFor: "198.51.100.4",
      connectingIp: VISITOR,
      socketAddress: "172.18.0.2",
    }),
    "198.51.100.4",
  );
  // Whatever was written further left is the caller's invention, and a
  // CF-Connecting-IP it brought along is ignored: only an edge that really is
  // Cloudflare's makes that header mean anything.
  assert.equal(
    clientAddressOf({
      forwardedFor: `${VISITOR}, 1.1.1.1, 198.51.100.4`,
      connectingIp: VISITOR,
      socketAddress: "172.18.0.2",
    }),
    "198.51.100.4",
  );
});

test("with no proxy in front, the socket peer is the client", () => {
  assert.equal(
    clientAddressOf({
      forwardedFor: undefined,
      connectingIp: undefined,
      socketAddress: "127.0.0.1",
    }),
    "127.0.0.1",
  );
  assert.equal(
    clientAddressOf({
      forwardedFor: "",
      connectingIp: undefined,
      socketAddress: "::ffff:192.168.1.20",
    }),
    "192.168.1.20",
  );
});

test("nothing usable at all resolves to nothing", () => {
  assert.equal(
    clientAddressOf({
      forwardedFor: "unknown",
      connectingIp: undefined,
      socketAddress: undefined,
    }),
    null,
  );
});
