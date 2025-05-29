# name: Segment.io
# about: Import your Discourse data to your Segment.io warehouse
# version: 1.0.1
# authors: Kyle Welsby (Original), updated by Donnie W

gem 'commander', '4.4.3'
gem 'analytics-ruby', '2.2.2', require: false

enabled_site_setting :segment_io_enabled

after_initialize do
  require 'segment/analytics'
  # Using OpenSSL::Digest as per your preference in the last module snippet.
  # No explicit 'require "openssl"' needed as it's typically part of stdlib loaded by Rails/Discourse.

  module DiscourseSegmentIdStrategy
    # Thread-safe fallback ID for guests with no session
    def self.fallback_guest_id
      Thread.current[:segment_fallback_guest_id] ||= "g#{SecureRandom.alphanumeric(35).downcase}"
    end

    # Generates a 36-char anonymous ID using user.id and hash
    def self.generate_user_custom_anonymous_id(user)
      return nil unless user&.id

      prefix = "#{user.id}-dc-" # fixed prefix with user.id
      input = "discourse_custom_anon_v1:#{user.id}:#{Rails.application.secret_key_base}" # salt input with app secret
      
      # OpenSSL::Digest is preloaded in Discourse/Rails environments, no extra 'require' needed
      full_hash = OpenSSL::Digest::SHA256.hexdigest(input) # hashed string stays stable per user

      remaining_len = 36 - prefix.length
      # Trim hash so final ID = 36 chars
      hash_segment = remaining_len > 0 ? full_hash[0...remaining_len] : ""
      
      "#{prefix}#{hash_segment}"
    end

    # Returns the appropriate identifier (user_id or anonymous_id)
    def self.get_segment_identifiers(user, session = nil)
      unless user
        if session
          # For guests with session: generate once, reuse
          session[:segment_guest_id] ||= "g#{SecureRandom.alphanumeric(35).downcase}"
          return { anonymous_id: session[:segment_guest_id] }
        else
          # No user or session: fallback to thread-safe shared guest ID
          return { anonymous_id: fallback_guest_id }
        end
      end

      # Use the configured strategy for identifying logged-in users
      setting = SiteSetting.segment_io_user_id_source

      case setting
      when 'email'
        # Use email as user_id if present
        if user.email.present?
          return { user_id: user.email }
        else
          Rails.logger.warn "[Segment.io Plugin] 'email' selected but missing for user #{user.id}"
        end
      when 'sso_external_id'
        # Use SSO external ID if available
        sso = user.single_sign_on_record&.external_id || user.external_id
        if sso.present?
          return { user_id: sso }
        else
          Rails.logger.warn "[Segment.io Plugin] 'sso_external_id' selected but missing for user #{user.id}"
        end
      when 'use_anon'
        # Force anonymous_id for all users
        anon_id = generate_user_custom_anonymous_id(user)
        return { anonymous_id: anon_id } if anon_id # Should always return an ID if user is present
      when 'discourse_id'
        # Use Discourse user.id as string
        return { user_id: user.id.to_s }
      else
        # Unknown config value
        Rails.logger.warn "[Segment.io Plugin] Unknown user_id_source: '#{setting}' for user #{user.id}"
      end

      # Fallback: try to generate anon ID, else return safe random
      # This is reached if the chosen strategy for an authenticated user didn't return an ID (e.g., email missing).
      fallback = generate_user_custom_anonymous_id(user) || begin
        Rails.logger.error "[Segment.io Plugin] Failed to generate custom anonymous_id for user #{user&.id}, using emergency fallback."
        "err_ua_#{SecureRandom.alphanumeric(29).downcase}" # Ensures a 36-char ID
      end
      { anonymous_id: fallback }
    end

    # Trait hash sent with identify() call
    def self.get_user_traits(user)
      return {} unless user
      {
        name: user.name,
        username: user.username,
        email: user.email,
        created_at: user.created_at.iso8601,
        internal: user.internal_user? # flag used to segment internal team users
      }.compact
    end
  end

  class Analytics
    @client_mutex = Mutex.new

    # Singleton Segment client (thread-safe)
    def self.client
      return nil unless SiteSetting.segment_io_enabled? && SiteSetting.segment_io_write_key.present?
      @client_mutex.synchronize do
        @client ||= Segment::Analytics.new(
          write_key: SiteSetting.segment_io_write_key,
          on_error: proc { |status, msg| Rails.logger.error "[Segment.io Plugin] Segment error #{status}: #{msg}" }
        )
      end
    end

    # Delegate tracking methods to the Segment client
    def self.method_missing(method, *args, &block)
      if segment_client = client # Assign and check if client is available
        if segment_client.respond_to?(method)
          return segment_client.send(method, *args, &block)
        else
          Rails.logger.warn "[Segment.io Plugin] Analytics client does not respond to unknown method: #{method}"
          # To maintain standard Ruby behavior for unhandled methods, call super.
          # If you intend to swallow these errors and return nil, this is a conscious choice.
          # For now, returning nil as per your last version's implicit behavior for this path.
        end
      end
      nil # Return nil if client is not available or if method is unknown and not re-raised
    end

    def self.respond_to_missing?(method, include_private = false)
      client&.respond_to?(method, include_private) || super
    end
  end

  module ::Jobs
    class EmitSegmentUserIdentify < ::Jobs::Base
      # Job enqueued after user signup to trigger identify
      def execute(args)
        return unless SiteSetting.segment_io_enabled?
        user = User.find_by_id(args[:user_id])
        user&.perform_segment_user_identify
      end
    end
  end

  class ::User
    # Fire both identify and signup events in order
    after_create do
      enqueue_segment_identify_job
      emit_segment_user_created
    end

    def enqueue_segment_identify_job
      Jobs.enqueue(:emit_segment_user_identify, user_id: self.id)
    end

    def perform_segment_user_identify # Method called by the background job
      return unless SiteSetting.segment_io_enabled?
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(self)
      return if identifiers.empty?

      # Compose payload with traits and optional IP
      payload = identifiers.merge(traits: ::DiscourseSegmentIdStrategy.get_user_traits(self))
      payload[:context] = { ip: ip_address } if respond_to?(:ip_address) && ip_address.present?

      Analytics.identify(payload)
    end

    def emit_segment_user_created
      return unless SiteSetting.segment_io_enabled?
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(self)
      return if identifiers.empty?

      Analytics.track(identifiers.merge(event: 'Signed Up'))
    end

    def internal_user?
      # Used for marking internal users by email domain
      return false if SiteSetting.segment_io_internal_domain.blank?
      email.present? && email.ends_with?(SiteSetting.segment_io_internal_domain)
    end
  end

  class ::ApplicationController
    before_action :emit_segment_user_tracker

    SEGMENT_IO_EXCLUDES = {
      'stylesheets' => :all,
      'user_avatars' => :all,
      'about' => ['live_post_counts'],
      'topics' => ['timings']
    }.freeze

    def emit_segment_user_tracker
      return unless SiteSetting.segment_io_enabled?
      return if segment_common_controller_actions?

      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(current_user, session)
      return if identifiers.empty?

      # Track full-page view for guests and users
      payload = identifiers.merge(
        name: "#{controller_name}##{action_name}",
        properties: {
          url: request.original_url,
          path: request.path,
          referrer: request.referrer,
          title: view_context.try(:page_title) || "#{controller_name}##{action_name}"
        },
        context: {
          ip: request.ip,
          userAgent: request.user_agent
        }
      )
      Analytics.page(payload)
    end

    private

    # Ignore noisy or useless page routes
    def segment_common_controller_actions?
      SEGMENT_IO_EXCLUDES[controller_name] == :all ||
        SEGMENT_IO_EXCLUDES[controller_name]&.include?(action_name)
    end
  end

  class ::Post
    after_create :emit_segment_post_created

    def emit_segment_post_created
      return unless SiteSetting.segment_io_enabled?
      author = user
      return unless author

      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(author)
      return if identifiers.empty?

      Analytics.track(identifiers.merge(
        event: 'Post Created',
        properties: {
          topic_id: topic_id,
          post_id: id,
          post_number: post_number,
          created_at: created_at.iso8601,
          since_topic_created: topic ? (created_at - topic.created_at).to_i : nil,
          reply_to_post_number: reply_to_post_number,
          internal: author.internal_user?
        }.compact
      ))
    end
  end

  class ::Topic
    after_create :emit_segment_topic_created

    def emit_segment_topic_created
      return unless SiteSetting.segment_io_enabled?
      author = user
      return unless author

      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(author)
      return if identifiers.empty?

      Analytics.track(identifiers.merge(
        event: 'Topic Created',
        properties: {
          topic_id: id,
          slug: slug,
          title: title,
          url: url,
          category_id: category_id,
          created_at: created_at.iso8601,
          internal: author.internal_user?
        }.compact
      ))
    end
  end

  class ::TopicTag
    after_create :emit_segment_topic_tagged

    def emit_segment_topic_tagged
      return unless SiteSetting.segment_io_enabled?
      # Uses fallback guest_id since no user context
      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(nil)
      return if identifiers.empty?

      Analytics.track(identifiers.merge(
        event: 'Topic Tag Created',
        properties: {
          topic_id: topic_id,
          tag_name: tag&.name
        }.compact
      ))
    end
  end

  class ::UserAction
    after_create :emit_segment_post_liked, if: -> { action_type == UserAction::LIKE }

    def emit_segment_post_liked
      return unless SiteSetting.segment_io_enabled?
      actor = user
      return unless actor

      identifiers = ::DiscourseSegmentIdStrategy.get_segment_identifiers(actor)
      return if identifiers.empty?

      Analytics.track(identifiers.merge(
        event: 'Post Liked',
        properties: {
          post_id: target_post_id,
          topic_id: target_topic_id,
          like_count_on_topic: target_topic&.like_count,
          internal: actor.internal_user?
        }.compact
      ))
    end
  end
end