```markdown
# Architectural Implementation Specification: Legacy Tracker

This document serves as the absolute technical blueprint for developing the **Legacy Tracker** platform. It outlines a high-level, production-grade architecture optimized for zero-bloat, extreme battery efficiency, and real-time spatiotemporal capabilities. 

---

## 1. Project Topology & Structure

Development occurs entirely within a unified monorepo. Dependencies must be kept strictly minimal, relying on native runtime features rather than heavyweight framework abstractions.

```text
.
└── src
    ├── client                  # Flutter Multiplatform Application
    │   ├── lib
    │   │   ├── main.dart       # App lifecycle orchestrator
    │   │   ├── models/         # Immutable data structures
    │   │   ├── providers/      # Light view-state & socket controllers
    │   │   ├── screens/        # Render-isolated map canvas
    │   │   └── services/       # Native background wrapper & HTTP engine
    │   └── pubspec.yaml
    └── server                  # Node.js + Fastify Backend
        ├── src
        │   ├── app.js          # Fastify initialization & routing
        │   ├── config/         # Database pooling & environment states
        │   ├── plugins/        # Native socket handlers & DB attachments
        │   └── services/       # Aggregation & push messaging drivers
        └── package.json

```

---

## 2. Database Layer (PostgreSQL + PostGIS)

The database utilizes standard relational tables supercharged with the **PostGIS** spatial extension. It isolates highly volatile current states from heavy, append-only historical data sets.

### 2.1 Storage Scheme & Structural Models

* **Users Collection:** Contains base identification tokens, secure cryptographic authentication hashes, and system registration indexes.
* **System State Registry:** An atomic, transactional table tracking the exact number of active foreground viewers globally across the entire friend network.
* **Position History Ledger:** An append-only partition-ready ledger. Geographic coordinates are recorded using the native `GEOGRAPHY(Point, 4326)` data type, which preserves true physical distance metrics (WGS 84 ellipsoid) without requiring complex spatial projections.

### 2.2 Indexing & Performance Constraints

* **Spatial Optimization:** A Generalized Search Tree (**GIST**) index must be mounted directly over the geographic coordinate geometry column. This ensures that spatial operations (bounding boxes, radius fences) complete in millisecond intervals.
* **Temporal Sorting:** A composite B-Tree index must link user identifiers with descending chronological timestamps (`user_id, recorded_at DESC`) to ensure history retrieval queries scale cleanly over years of data.

---

## 3. Ingestion Mechanics & Battery Optimization (The Pacing Engine)

To strictly enforce the zero-drain target, the client application relies on the operating system’s underlying native tracking services (iOS CoreLocation and Android FusedLocationProvider). The tracking loops adapt dynamically using a two-stage filtering matrix and a dual-channel wake-up strategy.

### 3.1 The Client-Side Filters

```
[Native Location Signal] ──> [Accuracy Gate: <= 30m?] ──Yes──> [Velocity Gate: Speed > 0?] ──Yes──> [Transmit POST]
                                    │                                    │
                                   No                                   No
                                    │                                    │
                             [Drop Payload]                      [Sleep GPS Engine]

```

* **The Accuracy Gate:** The application inspects the horizontal accuracy radius (in meters) of every hardware coordinate before processing. If the accuracy variance exceeds 30 meters, the coordinate is dropped instantly to prevent data noise.
* **The Velocity Gate:** The app checks the device's native hardware speed reading. If the velocity is strictly `0.0 m/s`, the application ignores generic distance triggers and places the GPS chip into a deep sleep state. The cellular modem remains asleep until the physical onboard accelerometer or gyroscope registers a confirmed change in the user's motion state (e.g., transitioning from stationary to walking/driving).

### 3.2 Dynamic Dual-Pacing Strategy

* **Passive State (No Active Viewers):** When no user has the application open, the background workers switch to passive mode. Updates are throttled to a loose window of every 60 to 120 seconds, prioritizing raw chronological history preservation over real-time synchronization.
* **The Foreground Trigger Event:** When any user opens the map interface, the system transitions to an active state. The server sets its global state registry to active and fires a **High-Priority Downstream Push Message** via Firebase Cloud Messaging (FCM) to all other devices in the group.
* **The Synchronous Wake-Up:** Upon intercepting this high-priority data packet, the background workers on sleeping devices wake up instantly, poll their current coordinate, and switch their native tracking cycle to an aggressive 5-second frequency.
* **The Pacing Header Loop:** Every incoming HTTP response from the backend carries a custom tracking token header (`X-Pacing-Mode: AGGRESSIVE` or `PASSIVE`). The native background handler reads this header during its standard POST loop to maintain or downgrade its polling frequency automatically.

---

## 4. Server Architecture (Node.js + Fastify)

The backend layer uses **Fastify** running on **Node.js** for maximum performance with a minimal memory footprint. It separates high-frequency REST collection endpoints from stateful data distribution.

```text
[Client Ingestion Task] ──(HTTP POST Batch/Single)──> [Fastify REST Layer] ──> [PostgreSQL / PostGIS]
                                                                                      │
[Client UI Mapping]     <───── (WebSocket Broadcast) ───── [Fastify WS Pool] <────────┘

```

### 4.1 Ticket-Based WebSocket Authentication Handshake

To prevent unauthenticated connection spikes and maintain a zero-bloat security profile over WebSockets, the server handles stateful validation through a dual-step exchange:

1. **The Ticket Issuance:** The client executes a standard, token-authenticated HTTP `POST /api/v1/streams/ticket`. The server generates a short-lived (60-second), single-use cryptographic token mapped to that specific user ID in memory, returning it to the client.
2. **The Connection Upgrade:** The client connects to the WebSocket gateway, appending the ticket string as a URL query parameter. Fastify intercepts the upgrade, validates and deletes the ticket from memory, maps the stateful socket to the authenticated user profile, and registers the connection in the active foreground viewer index.

### 4.2 Spatial Aggregation Engine

To maintain a lightweight network load, the backend avoids streaming raw database rows for historical route paths. When a user queries location history, the server processes the coordinate string through a spatial clustering filter (e.g., `ST_Simplify` or centroid clustering). Points recorded while a user was stationary are flattened into a single "Stop Event" object containing an entry time, exit time, and center coordinate.

---

## 5. Network Data Contracts (JSON Schemas)

Data shapes are strictly flat arrays or objects to eliminate serialization overhead and reduce data usage. All timestamp declarations conform strictly to ISO 8601 UTC standards.

### 5.1 HTTP Location Ingestion Endpoint (`POST /api/v1/location`)

The payload seamlessly handles either a single real-time ping or an array of batched points uploaded automatically after a user re-establishes a cellular connection from an offline zone.

```json
[
  {
    "coords": {
      "latitude": 43.7696,
      "longitude": 11.2558,
      "speed": 13.88,
      "heading": 185.5
    },
    "timestamp": "2026-05-31T13:00:00.000Z"
  }
]

```

### 5.2 WebSocket Live Broadcast Stream (`WS /api/v1/stream`)

This flat object structure is broadcast to all active connections when a location change is written to the database.

```json
{
  "user_id": "8f3b2024-bc6d-473d-9d7a-1123456789ab",
  "latitude": 43.7712,
  "longitude": 11.2594,
  "speed": 0.0,
  "heading": 42.1,
  "recorded_at": "2026-05-31T13:02:15.000Z"
}

```

---

## 6. Client UI & Render Optimizations (Flutter)

The mobile application interface is built for performance, ensuring the map remains highly responsive even when rendering live location shifts across older hardware.

* **Isolating Redraws via Repaint Boundaries:** Moving markers across the map layer must not trigger a global redraw of the underlying map canvas or map tiles. Every user marker widget must be wrapped inside its own independent `RepaintBoundary` node.
* **Heading Modifications via Low-Level Transforms:** Directional orientation changes (heading shifts) must be applied directly using a 2D `Transform.rotate` matrix wrapped strictly around the marker's visual arrow asset. This ensures heading updates consume minimal CPU and GPU cycles.
* **Lifecycle State Toggling:** The application relies on native system events to monitor lifecycle shifts. The moment the user minimizes the app interface or locks their screen, the WebSocket engine drops its connection immediately to preserve battery. The app then relies entirely on the native background HTTP task manager to handle location updates.

---

## 7. CI/CD & Deployment Isolation Framework

Continuous Integration pipelines automate build workflows via GitHub Actions, isolating container images from mobile application binary builds.

### 7.1 Server Container Design

The server uses a clean, multi-stage Docker build process based on a lightweight Alpine Linux image. The runtime stage includes only production node modules and strips out all development tools and testing files to minimize the security footprint and image size.

### 7.2 Automated Compilation Requirements

* **Android Packaging:** The CI/CD engine executes an optimized release compilation (`flutter build apk --release`), stripping out native symbols and debugging hooks.
* **iOS Packaging:** The pipeline processes code verification and packages the archive into an independent `.ipa` file using release optimization settings.
* **Binary Quality Rule:** The build configuration must guarantee that all development console logging statements, runtime performance metrics, and inspector ports are completely stripped from the final production application binary.

```

```