# Discourse Segment.io Plugin

Emits Discourse user and activity events to Segment.io using the official `analytics-ruby` SDK.

### Currently Supported Events

- `identify` — with flexible user ID strategy
- `track("Signed Up")` — on account creation
- `track("Post Created")`
- `track("Post Liked")`
- `track("Topic Created")`
- `track("Topic Tag Created")`
- `page` — on controller/page-level requests

### Identity Strategy (New)

You can now choose how Segment identifies users via the new `segment_io_user_id_source` site setting:

| Option             | Description                                                         |
|--------------------|---------------------------------------------------------------------|
| `email`            | Uses user email as the `userId`                                     |
| `sso_external_id`  | Uses the user’s external ID from SSO if present                     |
| `use_anon`         | Uses a custom, deterministic, 36-character `anonymousId`            |
| `discourse_id'     | Uses the internal Discourse user ID (e.g. `123`)                    |

The `anonymousId` format is:  
```
<discourse_id>-dc-<derived_string>
```

This is stable, unique per user, and does not require identifying information like email.

### 🧪 Debug Logging

Enable `segment_io_debug_enabled` in site settings to log payloads to the Rails log. This is useful for inspecting or verifying the format of data being sent to Segment.

### 🔁 Backfilling Existing Users

If you'd like to retroactively send `identify` calls for all users using the new strategy:

```ruby
User.pluck(:id).each do |uid|
  Jobs.enqueue(:emit_segment_user_identify, user_id: uid)
end
```

**Note:**  
If your site previously used `discourse_id`, and you are switching to `use_anon`, Segment will treat these as **new distinct profiles** unless you use Unify rules to merge.


### Installation

Watch Tutorial Video: https://youtu.be/AKR3ki9Kj38  
In Segment, create a `Ruby` source and use your write key to configure this plugin in Discourse.

### Contributing

Please see [CONTRIBUTING.md](/CONTRIBUTING.md).

### License

This plugin is © 2016 Kyle Welsby. It is free software, licensed under the terms specified in the [LICENSE](./license) file.
