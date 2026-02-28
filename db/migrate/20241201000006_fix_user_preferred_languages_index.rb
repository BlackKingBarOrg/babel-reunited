# frozen_string_literal: true

class FixUserPreferredLanguagesIndex < ActiveRecord::Migration[7.0]
  def up
    # Remove duplicates, keep most recent per user
    execute <<~SQL
      DELETE FROM user_preferred_languages
      WHERE id NOT IN (
        SELECT MAX(id) FROM user_preferred_languages GROUP BY user_id
      )
    SQL

    remove_index :user_preferred_languages, %i[user_id language], if_exists: true
    add_index :user_preferred_languages, :user_id, unique: true
  end

  def down
    remove_index :user_preferred_languages, :user_id
    add_index :user_preferred_languages, %i[user_id language], unique: true
  end
end
