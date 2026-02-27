# frozen_string_literal: true

# == Schema Information
#
# Table name: user_preferred_languages
#
#  id         :bigint           not null, primary key
#  user_id    :bigint           not null
#  language   :string(10)       default("en")
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  enabled    :boolean          default(TRUE), not null
#
# Indexes
#
#  index_user_preferred_languages_on_language              (language)
#  index_user_preferred_languages_on_user_id               (user_id)
#  index_user_preferred_languages_on_user_id_and_language  (user_id,language) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module BabelReunited
  class UserPreferredLanguage < ActiveRecord::Base
    self.table_name = "user_preferred_languages"

    belongs_to :user

    validates :language, length: { maximum: 10 }
    validates :enabled, inclusion: { in: [true, false] }
  end
end
