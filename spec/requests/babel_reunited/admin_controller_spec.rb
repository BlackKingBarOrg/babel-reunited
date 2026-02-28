# frozen_string_literal: true

RSpec.describe BabelReunited::AdminController do
  fab!(:user)
  fab!(:admin)
  fab!(:topic) { Fabricate(:topic, user: admin) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: admin) }

  before { enable_current_plugin }

  describe "authentication and authorization" do
    it "denies access to anonymous users" do
      get "/babel-reunited/admin/stats.json"
      expect(response.status).to eq(403)
    end

    it "denies access to regular users" do
      sign_in(user)
      get "/babel-reunited/admin/stats.json"
      expect(response.status).to eq(403)
    end

    it "allows admin users to access stats" do
      sign_in(admin)
      get "/babel-reunited/admin/stats.json"
      expect(response.status).to eq(200)
    end
  end

  describe "GET /babel-reunited/admin/stats" do
    before { sign_in(admin) }

    it "returns correct JSON structure" do
      get "/babel-reunited/admin/stats.json"
      expect(response.status).to eq(200)

      json = response.parsed_body
      expect(json).to have_key("total_translations")
      expect(json).to have_key("unique_languages")
      expect(json).to have_key("language_distribution")
      expect(json).to have_key("recent_translations")
    end

    it "counts translations correctly" do
      Fabricate(:post_translation, post: post_record, language: "es")
      Fabricate(:post_translation, post: post_record, language: "fr")

      get "/babel-reunited/admin/stats.json"
      json = response.parsed_body

      expect(json["total_translations"]).to eq(2)
      expect(json["unique_languages"]).to eq(2)
    end

    it "groups language distribution by language" do
      post2 = Fabricate(:post, topic: topic, user: admin)
      Fabricate(:post_translation, post: post_record, language: "es")
      Fabricate(:post_translation, post: post2, language: "es")
      Fabricate(:post_translation, post: post_record, language: "fr")

      get "/babel-reunited/admin/stats.json"
      json = response.parsed_body

      expect(json["language_distribution"]["es"]).to eq(2)
      expect(json["language_distribution"]["fr"]).to eq(1)
    end

    it "returns recent translations with expected fields" do
      Fabricate(:post_translation, post: post_record, language: "es")

      get "/babel-reunited/admin/stats.json"
      json = response.parsed_body

      recent = json["recent_translations"]
      expect(recent.length).to eq(1)

      entry = recent.first
      expect(entry).to have_key("id")
      expect(entry["post_id"]).to eq(post_record.id)
      expect(entry["language"]).to eq("es")
      expect(entry).to have_key("provider")
      expect(entry).to have_key("created_at")
    end

    it "returns empty stats when no translations exist" do
      get "/babel-reunited/admin/stats.json"
      json = response.parsed_body

      expect(json["total_translations"]).to eq(0)
      expect(json["unique_languages"]).to eq(0)
      expect(json["language_distribution"]).to eq({})
      expect(json["recent_translations"]).to eq([])
    end
  end
end
