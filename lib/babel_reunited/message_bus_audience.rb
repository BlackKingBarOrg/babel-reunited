# frozen_string_literal: true

module BabelReunited
  module MessageBusAudience
    def self.options_for(post)
      topic = post.topic
      return {} unless topic

      if topic.private_message?
        user_ids = topic.allowed_users.pluck(:id)
        user_ids |= topic.allowed_group_users.pluck(:id)
        { user_ids: user_ids }
      elsif topic.category&.read_restricted?
        { group_ids: topic.category.secure_group_ids }
      else
        {}
      end
    end
  end
end
