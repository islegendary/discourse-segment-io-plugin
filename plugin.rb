# name: Segment.io
# about: Import your Discourse data to your Segment.io warehouse
# version: 0.0.1
# authors: Kyle Welsby <kyle@mekyle.com>

gem 'commander', '4.4.3' # , require: false # for analytics-ruby
gem 'analytics-ruby', '2.2.2', require: false # 'segment/analytics'

enabled_site_setting :segment_io_enabled

after_initialize do
  require 'segment/analytics'
 
module DiscourseSegmentIdStrategy # New feature to allow for email <default> or sso is as userId with fallback to anonymous_id.  
  # Method to generate your custom "DECIMAL-HEX" anonymousId
  def self.generate_user_custom_anonymous_id(user) # Renamed for clarity within the module
    return nil unless user && user.id
    b = user.id.to_s # Original Discourse User ID as string
    s = b.each_char.with_index.sum { |c, i| c.ord * (i + 1) }
    h = b.length.to_s(36) + s.to_s(36) + b.reverse.chars.map { |c| (c.ord % 36).to_s(36) }.join
    need = 36 - b.length - 4
    if need <= 0
      return "#{b}-dc-ERROR_UID_TOO_LONG" if need < 0 # Basic error handling
      return "#{b}-dc-" if need == 0 # No derived part if need is 0
    end
    pad = (need == 1) ? '0' : ('06' * ((need + 1) / 2))
    derived_part = (pad + h).slice(-need, need)
    "#{b}-dc-#{derived_part}"
  end
  def self.get_segment_identifiers(user)
    return { anonymous_id: "sys_anon_#{Time.now.to_f.to_s.delete('.')}_#{rand(1_000_000)}" } unless user
    
    identifiers = {}
    case SiteSetting.segment_io_user_id_source # This site setting needs to be defined in config/settings.yml
    when 'email'
      identifiers[:user_id] = user.email if user.email.present?
    when 'sso_external_id'
      sso_id = user.single_sign_on_record&.external_id || user.external_id
      identifiers[:user_id] = sso_id if sso_id.present?
    when 'use_anon' # We'll confirm this name with you
      identifiers[:anonymous_id] = generate_user_custom_anonymous_id(user)
    when 'discourse_id' # Original behavior
      identifiers[:user_id] = user.id.to_s
    else # Default or unknown - might send original ID or nothing for user specific
      identifiers[:user_id] = user.id.to_s # Fallback to original
      Rails.logger.warn "[Segment.io Plugin] Unknown segment_io_user_id_source: '#{SiteSetting.segment_io_user_id_source}'. Defaulting to Discourse ID for user #{user.id}."
    end
    identifiers.compact # Remove nil values
  end
  # Helper to get common user traits
  def self.get_user_traits(user)
    return {} unless user
    {
      name: user.name,
      username: user.username,
      email: user.email, # Always good to send email as a trait
      created_at: user.created_at,
      # Add other traits from original plugin:
      internal: user.respond_to?(:internal_user?) ? user.internal_user? : nil
      # You can add more traits here if needed
    }.compact
  end
end

  class Analytics
    def self.method_missing(method, *args)
      return unless SiteSetting.segment_io_enabled
      analytics = Segment::Analytics.new(
        write_key: SiteSetting.segment_io_write_key
      )
      super(method, *args) unless analytics.respond_to?(method)
      analytics.send(method, *args)
      analytics.flush
    end
  end

  require_dependency 'jobs/base'
  module ::Jobs
    class EmitSegmentUserIdentify < Jobs::Base
      def execute(args)
        return unless SiteSetting.segment_io_enabled?
        user = User.find_by_id(args[:user_id])
        user.emit_segment_user_identify if user
      end
    end
  end

  require_dependency 'user'
  class ::User
    after_create :emit_segment_user_identify
    after_create :emit_segment_user_created

    def emit_segment_user_identify
      # Get the appropriate user_id or anonymous_id based on site settings
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(self)
      payload = identifiers.merge( # Start with user_id/anonymous_id
        traits: ::DiscourseSegmentIdStrategy.get_user_traits(self) # Add traits
      )
      if self.respond_to?(:ip_address) && self.ip_address.present?
        payload[:context] = { ip: self.ip_address }
      end
    
      Analytics.identify(payload)
    end

    def emit_segment_user_created
      # Get the appropriate user_id or anonymous_id based on site settings
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(self)
      # Prepare the payload for Analytics.track
      payload = identifiers.merge( # Start with user_id/anonymous_id
        event: 'Signed Up'
      )
    
      Analytics.track(payload)
    end

    def internal_user?
      return false if SiteSetting.segment_io_internal_domain.blank?
      email.ends_with?(SiteSetting.segment_io_internal_domain)
    end
  end

  require_dependency 'application_controller'
  class ::ApplicationController
    before_action :emit_segment_user_tracker

    SEGMENT_IO_EXCLUDES = {
      'stylesheets' => :all,
      'user_avatars' => :all,
      'about' => ['live_post_counts'],
      'topics' => ['timings']
    }.freeze
    def emit_segment_user_tracker
      if current_user && !segment_common_controller_actions?
        identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(current_user)
        # Prepare the payload for Analytics.page
        payload = identifiers.merge( # Start with user_id/anonymous_id
          name: "#{controller_name}##{action_name}", # Page name
          properties: { # Page properties
            url: request.original_url
            # title: view_context.try(:page_title) # Optional: if you want to send page title
          },
          context: { # Contextual information
            ip: request.ip,
            userAgent: request.user_agent # Segment often expects camelCase userAgent
          }
        )
    
        Analytics.page(payload)
      end
    end

    def segment_common_controller_actions?
      SEGMENT_IO_EXCLUDES.keys.include?(controller_name) &&
      (SEGMENT_IO_EXCLUDES[controller_name] == :all ||
       SEGMENT_IO_EXCLUDES[controller_name].include?(action_name) )
    end
  end

  require_dependency 'post'
  class ::Post
    after_create :emit_segment_post_created

    def emit_segment_post_created
      post_author = self.user 
    
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(post_author)
      payload = identifiers.merge(
        event: 'Post Created',
        properties: {
          topic_id: self.topic_id,
          post_number: self.post_number,
          created_at: self.created_at,
          # Ensure topic is available for since_topic_created
          since_topic_created: self.topic ? (self.created_at - self.topic.created_at).to_i : nil,
          reply_to_post_number: self.reply_to_post_number,
          # Ensure internal_user? method is called on the post_author (User object)
          internal: post_author.respond_to?(:internal_user?) ? post_author.internal_user? : nil
        }.compact # Remove any nil properties
      )
      Analytics.track(payload)
    end
  end

  require_dependency 'topic'
  class ::Topic
    after_create :emit_segment_topic_created

    def emit_segment_topic_created
      topic_author = self.user
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(topic_author)
      payload = identifiers.merge(
        event: 'Topic Created',
        properties: {
          slug: self.slug,
          title: self.title,
          url: self.url, # Assuming 'url' is a method on Topic model
          internal: topic_author.respond_to?(:internal_user?) ? topic_author.internal_user? : nil
        }.compact # Remove any nil properties
      )
      Analytics.track(payload)
    end
  end

  require_dependency 'topic_tag'
  class ::TopicTag
    after_create :emit_segment_topic_tagged

    def emit_segment_topic_tagged
      # Passing 'nil' to get_segment_identifiers will trigger our fallback anonymous ID.
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(nil)

      payload = identifiers.merge( # This will contain the generated anonymous_id
        event: 'Topic Tag Created',
        properties: {
          topic_id: self.topic_id,
          tag_name: self.tag.name # Assuming 'tag' association and 'name' attribute exist
        }.compact # Remove any nil properties
      )
      Analytics.track(payload)
    end
  end

  require_dependency 'user_action'
  class ::UserAction
    after_create :emit_segment_post_liked, if: -> { self.action_type == UserAction::LIKE }

    def emit_segment_post_liked
      action_user = self.user
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(action_user)
      payload = identifiers.merge(
        event: 'Post Liked',
        properties: {
          post_id: self.target_post_id,
          topic_id: self.target_topic_id,
          internal: action_user.respond_to?(:internal_user?) ? action_user.internal_user? : nil,
          # Ensure target_topic is available for like_count
          like_count: self.target_topic ? self.target_topic.like_count : nil
        }.compact # Remove any nil properties
      )
      Analytics.track(payload)
    end
  end
end
