# Architecture

Apps, services, and integrations depend on shared infrastructure modules, which depend on the platform-independent `AgentDomain`. The macOS helper is the local authority. This document will grow only as ordered phases add verified behavior.

`AgentPersistence` depends on `AgentDomain` and `AgentProtocol`. Its
`DatabaseActor` owns the SQLite connection and transaction boundaries, so app
and helper callers must cross an actor boundary for every disk operation. The
database stores append-only normalized envelopes and transactionally updated
session snapshots. Read models return small `Sendable` values rather than raw
SQLite handles or rows.
