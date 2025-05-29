# Changelog

All notable changes to this plugin will be documented in this file.

---

## [Unreleased]

### Added
- `segment_io_user_id_source` setting for flexible identity logic (`email`, `sso_external_id`, `discourse_id`, `use_anon`)
- Deterministic 36-character `anonymousId` generator with fallback handling
- `segment_io_debug_enabled` setting for payload logging
- Full support for:
  - User identify events
  - Custom anonymousId for non-email tracking
  - Page views, post and topic lifecycle events
- Safer error handling in background jobs
- Memoized Segment client for performance

### Changed
- Refactored payload generation into `DiscourseSegmentIdStrategy`
- Modularized `Analytics` client to allow dynamic method handling

### Deprecated
- Use of `alias` method discouraged per Segment’s latest Unify guidance

