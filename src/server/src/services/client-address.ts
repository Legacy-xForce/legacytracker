import { ipMatchesAllowlist, normalizeIp } from "./api-tokens";

/**
 * Cloudflare's published edge ranges, which is how production traffic reaches
 * us. https://api.cloudflare.com/client/v4/ips (checked 2026-10-27); a new
 * range only ever widens what counts as "this request came through
 * Cloudflare", so falling behind is visible rather than silent.
 */
export const CLOUDFLARE_CIDRS = [
  "173.245.48.0/20",
  "103.21.244.0/22",
  "103.22.200.0/22",
  "103.31.4.0/22",
  "141.101.64.0/18",
  "108.162.192.0/18",
  "190.93.240.0/20",
  "188.114.96.0/20",
  "197.234.240.0/22",
  "198.41.128.0/17",
  "162.158.0.0/15",
  "104.16.0.0/13",
  "104.24.0.0/14",
  "172.64.0.0/13",
  "131.0.72.0/22",
  "2400:cb00::/32",
  "2606:4700::/32",
  "2803:f800::/32",
  "2405:b500::/32",
  "2405:8100::/32",
  "2a06:98c0::/29",
  "2c0f:f248::/32",
];

export interface ForwardedAddress {
  /** The raw `X-Forwarded-For` header, as it arrived. */
  forwardedFor: string | undefined;
  /** `CF-Connecting-IP`, or the newer `CF-Client-IP`. */
  connectingIp: string | undefined;
  /** The address this process accepted the connection from. */
  socketAddress: string | undefined;
}

/**
 * The address a request should be judged against.
 *
 * The edge is the hop our own proxy reported: the rightmost entry of
 * `X-Forwarded-For`, which is what Traefik saw when it accepted the
 * connection, or the socket peer when no proxy is in front. Everything to its
 * left was written by whoever sent the request, so it is never the answer.
 *
 * Behind Cloudflare that edge is one of its own addresses, not the visitor:
 * Traefik strips `X-Forwarded-*` from peers it was never told to trust, which
 * discards the client Cloudflare put there. A Cloudflare edge address is proof
 * the request really did cross their network — a caller cannot make Traefik see
 * a peer it does not own — and Cloudflare names that visitor in
 * `CF-Connecting-IP`, which Traefik forwards untouched. So when the edge is
 * Cloudflare's, that header is the client; when it is not, the edge is.
 *
 * This also holds if Traefik is later told to trust Cloudflare's ranges, which
 * restores the full chain: the edge stays a Cloudflare address and the header
 * still carries the same client.
 */
export function clientAddressOf({
  forwardedFor,
  connectingIp,
  socketAddress,
}: ForwardedAddress): string | null {
  const hops = (forwardedFor ?? "")
    .split(",")
    .map((hop) => hop.trim())
    .filter((hop) => hop.length > 0);
  const edge = normalizeIp(hops.at(-1) ?? socketAddress ?? "");
  if (!edge) {
    return null;
  }
  if (ipMatchesAllowlist(edge, CLOUDFLARE_CIDRS)) {
    return normalizeIp(connectingIp ?? "") ?? edge;
  }
  return edge;
}
