# name: Segment.io
# about: Import your Discourse data to your Segment.io warehouse
# version: 0.0.1
# authors: Kyle Welsby <kyle@mekyle.com>

gem 'commander', '4.4.0' # , require: false # for analytics-ruby
gem 'analytics-ruby', '2.2.2', require: false # 'segment/analytics'

after_initialize do
  require 'segment/analytics'

  SEGMENT_IO_KEY = ENV['SEGMENT_IO_KEY']
  Analytics = Segment::Analytics.new(
    write_key: SEGMENT_IO_KEY,
    on_error: proc { |_status, msg| print msg }
  )

  require_dependency 'jobs/base'
  module ::Jobs
    class EmitSegmentUserIdentify < Jobs::Base
      def execute(args)
        user = User.find_by_id(args[:user_id])
        user.emit_segment_user_identify if user
      end
    end
  end

  User.find_each do |user|
    Jobs.enqueue(:emit_segment_user_identify, user_id: user.id)
  end

  class ::User
    after_create :emit_segment_user_identify
    after_create :emit_segment_user_created
    def emit_segment_user_identify
      Analytics.identify(
        user_id: id,
        traits: {
          name: name,
          username: username,
          email: email,
          created_at: created_at
        },
        context: {
          ip: ip_address
        }
      )
    end

    def emit_segment_user_created
      Analytics.track(
        user_id: id,
        event: 'Signed Up'
      )
    end
  end

  class ::Post
    after_create :emit_segment_post_created

    def emit_segment_post_created
      Analytics.track(
        user_id: user_id,
        event: 'Post Created',
        properties: {
          slug: topic.slug,
          title: topic.title,
          url: topic.url
        }
      )
    end
  end

  class ::Topic
    after_create :emit_segment_topic_created

    def emit_segment_topic_created
      Analytics.track(
        user_id: user_id,
        event: 'Topic Created',
        properties: {
          slug: slug,
          title: title,
          url: url
        }
      )
    end
  end
end
