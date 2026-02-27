# frozen_string_literal: true

class CreateUserPreferredLanguages < ActiveRecord::Migration[7.0]
  def change
    create_table :user_preferred_languages do |t|
      t.bigint :user_id, null: false
      t.string :language, null: false, limit: 10
      t.timestamps
    end

    add_index :user_preferred_languages, :user_id
    add_index :user_preferred_languages, %i[user_id language], unique: true
    add_index :user_preferred_languages, :language
    add_foreign_key :user_preferred_languages, :users
  end
end
