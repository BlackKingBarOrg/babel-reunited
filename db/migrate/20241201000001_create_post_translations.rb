# frozen_string_literal: true

class CreatePostTranslations < ActiveRecord::Migration[7.0]
  def change
    create_table :post_translations do |t|
      t.bigint :post_id, null: false
      t.string :language, null: false, limit: 10
      t.text :translated_content, null: false
      t.string :source_language, limit: 10
      t.string :translation_provider, limit: 50
      t.json :metadata, default: {}
      t.timestamps
    end

    add_index :post_translations, :post_id
    add_index :post_translations, %i[post_id language], unique: true
    add_index :post_translations, :language
    add_index :post_translations, :created_at
    add_foreign_key :post_translations, :posts
  end
end
