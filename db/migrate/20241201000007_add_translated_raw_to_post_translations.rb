# frozen_string_literal: true

class AddTranslatedRawToPostTranslations < ActiveRecord::Migration[7.0]
  def change
    add_column :post_translations, :translated_raw, :text
    add_column :post_translations, :source_sha, :string, limit: 64
  end
end
